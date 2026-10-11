import Combine
import Foundation

enum ContentLoadResult: Equatable {
    case loaded, exhausted, unavailable
}

/// Rotates the newest unseen public article from each editorial source.
/// It uses public feeds and home pages only; no browser cookies or account data are read.
@MainActor
final class SspaiTopOneStore: ObservableObject {
    @Published private(set) var article: SspaiArticle?
    @Published private(set) var isCheckingCover = false
    @Published private(set) var lastLoadResult: ContentLoadResult?
    private let sourcesInRoundKey = "Cike.contentSourcesInRound"
    private let cacheTTL: TimeInterval = 20 * 60
    private let retryInterval: TimeInterval = 90
    private var isLoading = false
    private var presentationGeneration = 0
    private var history = ContentHistoryStore()
    private var cachedFeeds: [ContentSource: CachedFeed] = [:]
    private var lastAttemptAt: [ContentSource: Date] = [:]
    private var feedTasks: [ContentSource: Task<[SspaiArticle], Never>] = [:]

    init() {
        Task { await warmContentPool() }
    }

    func loadNext() async -> ContentLoadResult {
        guard !isLoading else { return .unavailable }
        isLoading = true
        let generation = presentationGeneration
        defer { if presentationGeneration == generation { isLoading = false } }
        article = nil
        isCheckingCover = false
        lastLoadResult = nil

        let sources = ContentSource.allCases
        var foundContent = false
        let tasks = sources.map { source in
            Task { (source, await self.articles(for: source)) }
        }
        var candidates: [(source: ContentSource, article: SspaiArticle)] = []
        for task in tasks {
            let (source, articles) = await task.value
            guard !articles.isEmpty else { continue }
            foundContent = true
            if let article = articles.enumerated()
                .filter({ !history.hasShown($0.element.url) })
                .max(by: { left, right in
                    let leftDate = PublishedDate.parse(left.element.date) ?? .distantPast
                    let rightDate = PublishedDate.parse(right.element.date) ?? .distantPast
                    return leftDate == rightDate ? left.offset > right.offset : leftDate < rightDate
                })?.element {
                candidates.append((source, article))
            }
        }
        guard presentationGeneration == generation else { return .unavailable }
        guard !candidates.isEmpty else {
            let result: ContentLoadResult = foundContent ? .exhausted : .unavailable
            lastLoadResult = result
            return result
        }

        let completedSources = Set(UserDefaults.standard.stringArray(forKey: sourcesInRoundKey) ?? [])
        let remaining = candidates.filter { !completedSources.contains($0.source.rawValue) }
        let pool = remaining.isEmpty ? candidates : remaining
        guard let next = pool.max(by: { left, right in
            let leftDate = PublishedDate.parse(left.article.date) ?? .distantPast
            let rightDate = PublishedDate.parse(right.article.date) ?? .distantPast
            return leftDate == rightDate ? left.source.index > right.source.index : leftDate < rightDate
        }) else {
            lastLoadResult = .unavailable
            return .unavailable
        }

        history.record(next.article.url, source: next.source.rawValue)
        let round = remaining.isEmpty ? [] : Array(completedSources)
        UserDefaults.standard.set(round + [next.source.rawValue], forKey: sourcesInRoundKey)
        isCheckingCover = next.source != .githubTrending
        article = next.article
        lastLoadResult = .loaded
        if next.source == .githubTrending {
            Task { [weak self] in
                await self?.enrichGitHubDescriptions(next.article)
            }
        } else {
            Task { [weak self] in
                await self?.enrich(next.article, from: next.source)
            }
        }
        Task { [weak self] in
            await self?.warmContentPool()
        }
        return .loaded
    }

    func clearPresentation() {
        presentationGeneration += 1
        isLoading = false
        article = nil
        isCheckingCover = false
        lastLoadResult = nil
    }

    private func articles(for source: ContentSource) async -> [SspaiArticle] {
        let now = Date.now
        if let cached = cachedFeeds[source], now.timeIntervalSince(cached.refreshedAt) < cacheTTL {
            return cached.articles
        }
        if let task = feedTasks[source] { return await task.value }
        if let attempt = lastAttemptAt[source], now.timeIntervalSince(attempt) < retryInterval {
            return cachedFeeds[source]?.articles ?? []
        }
        lastAttemptAt[source] = now
        let task = Task { await source.loadArticles() }
        feedTasks[source] = task
        let fetched = await task.value
        feedTasks[source] = nil
        if !fetched.isEmpty {
            cachedFeeds[source] = CachedFeed(articles: fetched, refreshedAt: now)
            return fetched
        }
        return cachedFeeds[source]?.articles ?? []
    }

    private func warmContentPool() async {
        let tasks = ContentSource.allCases.map { source in
            Task { await self.articles(for: source) }
        }
        for task in tasks {
            _ = await task.value
        }
    }

    private func enrich(_ article: SspaiArticle, from source: ContentSource) async {
        var enriched = article
        if source == .sspai || enriched.coverURL == nil,
           let html = await ContentSource.loadHTML(from: article.url) {
            if source == .sspai {
                enriched = enriched.with(details: SspaiArticle.Details.parse(from: html))
            }
            if enriched.coverURL == nil {
                let cover = source == .itsNiceThat
                    ? ContentSource.itsNiceThatCoverURL(in: html)
                    : ContentSource.coverURL(in: html, relativeTo: article.url)
                enriched = enriched.with(coverURL: cover)
            }
        }
        guard self.article?.url == article.url else { return }
        self.article = enriched
        isCheckingCover = false
        if source.needsChineseTitle, let translatedTitle = await ContentSource.translateTitle(article.title) {
            guard self.article?.url == article.url else { return }
            self.article = enriched.with(title: translatedTitle)
        }
    }

    private func enrichGitHubDescriptions(_ article: SspaiArticle) async {
        guard let projects = article.githubProjects else { return }
        let tasks = projects.map { project in
            Task {
                guard project.summary != "项目暂未提供简介" else { return Optional<String>.none }
                return await ContentSource.translateTitle(project.summary)
            }
        }
        var localized: [GitHubTrendingProject] = []
        for (project, task) in zip(projects, tasks) {
            localized.append(project.with(summary: await task.value ?? project.summary))
        }
        guard self.article?.url == article.url else { return }
        self.article = article.with(githubProjects: localized)
    }

    private struct CachedFeed {
        let articles: [SspaiArticle]
        let refreshedAt: Date
    }
}

private enum PublishedDate {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z",
                       "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

private enum ContentSource: String, CaseIterable {
    case sspai, quanta, nasa, smithsonian, publicDomainReview, itsNiceThat
    case colossal, pudding, jstorDaily, youtube, kidShouldSeeThis, githubTrending

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var needsChineseTitle: Bool { self != .sspai }

    func loadArticles() async -> [SspaiArticle] {
        switch self {
        case .sspai:
            guard let html = await Self.loadHTML(from: URL(string: "https://sspai.com/")!) else { return [] }
            return SspaiArticle.parseAll(from: html)
        case .quanta:
            return await Self.loadRSS(url: "https://www.quantamagazine.org/feed/", source: "Quanta Magazine")
        case .nasa:
            return await Self.loadNASA()
        case .smithsonian:
            return await Self.loadRSS(url: "https://www.smithsonianmag.com/rss/science-nature/", source: "Smithsonian Magazine")
        case .publicDomainReview:
            return await Self.loadRSS(url: "https://publicdomainreview.org/rss.xml", source: "The Public Domain Review")
        case .itsNiceThat:
            return await Self.loadRSS(url: "https://www.itsnicethat.com/articles.atom", source: "It’s Nice That")
        case .colossal:
            return await Self.loadRSS(url: "https://www.thisiscolossal.com/feed/", source: "Colossal")
        case .pudding:
            return await Self.loadRSS(url: "https://pudding.cool/rss.xml", source: "The Pudding")
        case .jstorDaily:
            return await Self.loadRSS(url: "https://daily.jstor.org/feed/", source: "JSTOR Daily") { item in
                !Set(item.categories.map { $0.lowercased() }).isDisjoint(with: [
                    "arts & culture", "plants & animals", "natural science", "science & technology", "social history"
                ])
            }
        case .youtube:
            return await Self.loadYouTube()
        case .kidShouldSeeThis:
            return await Self.loadRSS(url: "https://thekidshouldseethis.com/feed", source: "The Kid Should See This")
                .filter { $0.videoURL != nil && $0.coverURL != nil }
        case .githubTrending:
            return await Self.loadGitHubTrending()
        }
    }

    static func loadGitHubTrending() async -> [SspaiArticle] {
        guard let url = URL(string: "https://github.com/trending?since=weekly"),
              let html = await loadHTML(from: url) else { return [] }
        let projects = GitHubTrendingProject.parseTopThree(from: html)
        guard projects.count == 3 else { return [] }

        // The rolling weekly ranking can change each day; show each day's snapshot once.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: .now)
        var snapshot = URLComponents(url: url, resolvingAgainstBaseURL: false)
        snapshot?.fragment = today
        guard let snapshotURL = snapshot?.url else { return [] }
        return [SspaiArticle(title: "GitHub 本周热门项目", url: snapshotURL,
                             source: "GitHub Trending", coverURL: nil,
                             date: today, githubProjects: projects)]
    }

    static func loadYouTube() async -> [SspaiArticle] {
        async let tedEd = loadYouTubeChannel("UCsooa4yRKGN_zEE8iknghZA", name: "TED-Ed")
        async let markRober = loadYouTubeChannel("UCY1kMZp36IQSyNx_9h4mpCg", name: "Mark Rober")
        let channels = await [tedEd, markRober]
        // Alternate channels so a frequent uploader does not occupy every recommendation.
        return (0..<8).flatMap { index in
            channels.compactMap { articles in articles.indices.contains(index) ? articles[index] : nil }
        }
    }

    static func loadYouTubeChannel(_ id: String, name: String) async -> [SspaiArticle] {
        var components = URLComponents(string: "https://www.youtube.com/feeds/videos.xml")
        components?.queryItems = [URLQueryItem(name: "channel_id", value: id)]
        guard let url = components?.url, let xml = await loadHTML(from: url) else { return [] }
        return RSSParser.parse(xml).compactMap { item in
            guard let videoID = item.videoID,
                  videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil,
                  let link = item.link, let articleURL = URL(string: link),
                  articleURL.host == "www.youtube.com", articleURL.path == "/watch",
                  let videoURL = URL(string: "https://www.youtube.com/embed/\(videoID)"),
                  let coverURL = item.imageURL ?? URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"),
                  let title = item.title else { return nil }
            return SspaiArticle(title: SspaiArticle.htmlText(title), url: articleURL,
                                source: "YouTube · \(name)", coverURL: coverURL,
                                date: item.date, videoURL: videoURL)
        }
    }

    static func loadNASA() async -> [SspaiArticle] {
        guard let url = URL(string: "https://science.nasa.gov/wp-json/wp/v2/apod-basic?api_key=DEMO_KEY") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let entries = try? JSONDecoder().decode([NASAEntry].self, from: data) else { return [] }
            return entries.filter { $0.mediaType == "image" }.compactMap { entry in
                guard let articleURL = URL(string: entry.permalink),
                      articleURL.scheme == "https",
                      let coverURL = entry.hdurl.flatMap(URL.init(string:)),
                      coverURL.scheme == "https" else { return nil }
                return SspaiArticle(title: entry.title, url: articleURL, source: "NASA 每日天文图片", coverURL: coverURL, date: entry.date)
            }
        } catch {
            return []
        }
    }

    private struct NASAEntry: Decodable {
        let date: String
        let title: String
        let permalink: String
        let mediaType: String
        let hdurl: String?

        enum CodingKeys: String, CodingKey {
            case date, title, permalink, hdurl
            case mediaType = "media_type"
        }
    }

    static func loadHTML(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    static func loadRSS(url: String, source: String, include: (RSSParser.Item) -> Bool = { _ in true }) async -> [SspaiArticle] {
        guard let url = URL(string: url), let xml = await loadHTML(from: url) else { return [] }
        return RSSParser.parse(xml).filter(include).compactMap { item in
            guard let rawTitle = item.title, let link = item.link, let articleURL = URL(string: link),
                  articleURL.scheme == "https" else { return nil }
            let title = SspaiArticle.htmlText(rawTitle)
            guard !title.isEmpty else { return nil }
            let imageURL = item.imageURL ?? coverURL(in: item.description ?? "", relativeTo: articleURL)
            let duration = item.videoDuration.map { "\(max(1, Int(ceil(Double($0) / 60)))) 分钟视频" }
            return SspaiArticle(title: title, url: articleURL, source: source, coverURL: imageURL,
                                date: item.date, readingTime: duration, videoURL: item.videoURL)
        }
    }

    static func coverURL(in html: String, relativeTo baseURL: URL) -> URL? {
        let patterns = [
            #"<meta\b[^>]*(?:property|name)=[\"'](?:og:image|twitter:image)[\"'][^>]*content=[\"']([^\"']+)[\"']"#,
            #"<meta\b[^>]*content=[\"']([^\"']+)[\"'][^>]*(?:property|name)=[\"'](?:og:image|twitter:image)[\"']"#,
            #"<img\b[^>]*(?:data-src|src)=[\"']([^\"']+)[\"']"#
        ]
        for pattern in patterns {
            guard let match = SspaiArticle.firstMatch(pattern, in: html), match.count > 1 else { continue }
            let raw = match[1].replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL, url.scheme == "https" {
                return url
            }
        }
        return nil
    }

    static func itsNiceThatCoverURL(in html: String) -> URL? {
        let pattern = #"<img\b[^>]*\bsrc=["'](https://(?:m|admin)\.itsnicethat\.com/[^"']+)["']"#
        guard let match = SspaiArticle.firstMatch(pattern, in: html), match.count > 1 else { return nil }
        return URL(string: match[1].replacingOccurrences(of: "&amp;", with: "&"))
    }

    static func translateTitle(_ title: String) async -> String? {
        let cacheKey = "Cike.translatedTitle." + title.lowercased()
        if let cached = UserDefaults.standard.string(forKey: cacheKey), !cached.isEmpty { return cached }
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")
        components?.queryItems = [
            URLQueryItem(name: "q", value: title),
            URLQueryItem(name: "langpair", value: "en|zh-CN")
        ]
        guard let url = components?.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let result = try JSONDecoder().decode(TranslationResponse.self, from: data)
            let translated = result.responseData.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { return nil }
            UserDefaults.standard.set(translated, forKey: cacheKey)
            return translated
        } catch {
            return nil
        }
    }

    private struct TranslationResponse: Decodable {
        struct ResponseData: Decodable { let translatedText: String }
        let responseData: ResponseData
    }
}

struct GitHubTrendingProject {
    let name: String
    let url: URL
    let summary: String
    let language: String?
    let weeklyStars: String?

    func with(summary: String) -> GitHubTrendingProject {
        GitHubTrendingProject(name: name, url: url, summary: summary,
                              language: language, weeklyStars: weeklyStars)
    }

    static func parseTopThree(from html: String) -> [GitHubTrendingProject] {
        let cards = SspaiArticle.allMatches(#"<article\b(?=[^>]*\bclass=["'][^"']*Box-row[^"']*["'])[^>]*>([\s\S]*?)</article>"#, in: html)
        return cards.prefix(3).compactMap { card in
            guard card.count > 1,
                  let heading = SspaiArticle.firstMatch(#"<h2\b[^>]*>([\s\S]*?)</h2>"#, in: card[1]),
                  heading.count > 1,
                  let link = SspaiArticle.firstMatch(#"\bhref=["'](/[^/"'\s<>]+/[^/"'\s<>]+)["']"#, in: heading[1]),
                  link.count > 1,
                  let url = URL(string: "https://github.com\(link[1])") else { return nil }
            let name = String(link[1].dropFirst())
            let summary = SspaiArticle.firstMatch(#"<p\b[^>]*class=["'][^"']*col-9[^"']*["'][^>]*>([\s\S]*?)</p>"#, in: card[1])
                .flatMap { $0.count > 1 ? SspaiArticle.htmlText($0[1]) : nil }
                .flatMap { $0.isEmpty ? nil : $0 } ?? "项目暂未提供简介"
            let language = SspaiArticle.firstMatch(#"<span\b[^>]*itemprop=["']programmingLanguage["'][^>]*>([^<]+)</span>"#, in: card[1])
                .flatMap { $0.count > 1 ? SspaiArticle.htmlText($0[1]) : nil }
            let weeklyStars = SspaiArticle.firstMatch(#"([\d,]+)\s+stars this week"#, in: card[1])
                .flatMap { $0.count > 1 ? $0[1] : nil }
            return GitHubTrendingProject(name: name, url: url, summary: summary,
                                         language: language, weeklyStars: weeklyStars)
        }
    }
}

struct SspaiArticle {
    let title: String
    let url: URL
    let source: String
    let coverURL: URL?
    let date: String?
    let author: String?
    let readingTime: String?
    let videoURL: URL?
    let githubProjects: [GitHubTrendingProject]?

    init(title: String, url: URL, source: String, coverURL: URL?, date: String? = nil, author: String? = nil, readingTime: String? = nil, videoURL: URL? = nil, githubProjects: [GitHubTrendingProject]? = nil) {
        self.title = title
        self.url = url
        self.source = source
        self.coverURL = coverURL
        self.date = date
        self.author = author
        self.readingTime = readingTime
        self.videoURL = videoURL
        self.githubProjects = githubProjects
    }

    var metadataText: String { [source, date, author, readingTime].compactMap { $0 }.joined(separator: " · ") }

    func with(details: Details) -> SspaiArticle {
        SspaiArticle(title: title, url: url, source: source, coverURL: coverURL, date: details.date, author: details.author, readingTime: details.readingTime, videoURL: videoURL, githubProjects: githubProjects)
    }

    func with(title: String) -> SspaiArticle {
        SspaiArticle(title: title, url: url, source: source, coverURL: coverURL, date: date, author: author, readingTime: readingTime, videoURL: videoURL, githubProjects: githubProjects)
    }

    func with(coverURL: URL?) -> SspaiArticle {
        SspaiArticle(title: title, url: url, source: source, coverURL: coverURL, date: date, author: author, readingTime: readingTime, videoURL: videoURL, githubProjects: githubProjects)
    }

    func with(videoURL: URL?) -> SspaiArticle {
        SspaiArticle(title: title, url: url, source: source, coverURL: coverURL, date: date, author: author, readingTime: readingTime, videoURL: videoURL, githubProjects: githubProjects)
    }

    func with(githubProjects: [GitHubTrendingProject]) -> SspaiArticle {
        SspaiArticle(title: title, url: url, source: source, coverURL: coverURL, date: date, author: author, readingTime: readingTime, videoURL: videoURL, githubProjects: githubProjects)
    }

    static func parseAll(from html: String) -> [SspaiArticle] {
        let cardPattern = #"<article\b(?=[^>]*\bclass=[\"'][^\"']*article__card[^\"']*[\"'])[^>]*>([\s\S]*?)</article>"#
        return allMatches(cardPattern, in: html).compactMap { card in
            guard card.count == 2 else { return nil }
            return parseCard(card[1])
        }
    }

    private static func parseCard(_ body: String) -> SspaiArticle? {
        let hrefPattern = #"<a\b(?=[^>]*\bclass=[\"'][^\"']*article__card__link[^\"']*[\"'])(?=[^>]*\bhref=[\"']([^\"']+)[\"'])[^>]*>"#
        guard let hrefMatch = firstMatch(hrefPattern, in: body), hrefMatch.count == 2 else { return nil }
        let titlePattern = #"<p\b[^>]*\bclass=[\"'][^\"']*article__card__title[^\"']*[\"'][^>]*>([\s\S]*?)</p>"#
        guard let titleMatch = firstMatch(titlePattern, in: body), titleMatch.count == 2 else { return nil }
        let title = htmlText(titleMatch[1])
        guard !title.isEmpty, let url = URL(string: hrefMatch[1], relativeTo: URL(string: "https://sspai.com"))?.absoluteURL else { return nil }
        let coverPattern = #"<div\b(?=[^>]*\bclass=[\"'][^\"']*article__card__cover[^\"']*[\"'])[^>]*>[\s\S]*?<img\b[^>]*(?:data-src|src)=[\"']([^\"']+)[\"']"#
        let cover = firstMatch(coverPattern, in: body).flatMap { match in
            match.count > 1 ? URL(string: match[1], relativeTo: URL(string: "https://sspai.com"))?.absoluteURL : nil
        }
        return SspaiArticle(title: title, url: url, source: "少数派", coverURL: cover)
    }

    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

    static func allMatches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
        }
    }

    static func htmlText(_ value: String) -> String {
        let withoutTags = value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Details {
        let date: String?
        let author: String?
        let readingTime: String?
        static let empty = Details(date: nil, author: nil, readingTime: nil)

        static func parse(from html: String) -> Details {
            let date = firstText(#"<span\b[^>]*\bclass=[\"'][^\"']*article__header__date[^\"']*[\"'][^>]*>([\s\S]*?)</span>"#, in: html)
            let readingTime = firstText(#"<span\b[^>]*\bclass=[\"'][^\"']*article__header__reading-time[^\"']*[\"'][^>]*>([\s\S]*?)</span>"#, in: html)
            let authorPattern = #"\"author\"\s*:\s*\{[^}]*\"name\"\s*:\s*\"([^\"]+)\""#
            let author = firstMatch(authorPattern, in: html).flatMap { $0.count > 1 ? $0[1] : nil }
            return Details(date: date, author: author, readingTime: readingTime)
        }

        private static func firstText(_ pattern: String, in html: String) -> String? {
            guard let match = firstMatch(pattern, in: html), match.count > 1 else { return nil }
            let text = htmlText(match[1]); return text.isEmpty ? nil : text
        }
    }
}

private final class RSSParser: NSObject, XMLParserDelegate {
    struct Item {
        var title: String?
        var link: String?
        var date: String?
        var imageURL: URL?
        var description: String?
        var videoURL: URL?
        var videoID: String?
        var videoDuration: Int?
        var categories: [String] = []
    }
    private var items: [Item] = []
    private var item: Item?
    private var element = ""
    private var text = ""

    static func parse(_ xml: String) -> [Item] {
        let parser = XMLParser(data: Data(xml.utf8))
        let delegate = RSSParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        element = elementName.lowercased()
        text = ""
        if element == "item" || element == "entry" { item = Item() }
        if element == "link", let href = attributeDict["href"],
           attributeDict["rel"] == nil || attributeDict["rel"] == "alternate" {
            item?.link = href
        }
        if let raw = attributeDict["url"], let url = URL(string: raw), url.scheme == "https" {
            if element == "media:thumbnail" || element == "enclosure" && attributeDict["type"]?.hasPrefix("image/") == true {
                if item?.imageURL == nil { item?.imageURL = url }
            } else if element == "media:player" || element == "media:content" && raw.contains("/embed/") {
                if item?.videoURL == nil { item?.videoURL = url }
            } else if element == "media:content" && attributeDict["type"]?.hasPrefix("image/") == true {
                if item?.imageURL == nil { item?.imageURL = url }
            }
        }
        if element == "media:content", let duration = attributeDict["duration"] {
            item?.videoDuration = Int(duration)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard var current = item else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "title": if current.title == nil { current.title = value }
        case "link": if current.link == nil { current.link = value }
        case "guid": if current.link == nil { current.link = value }
        case "pubdate", "published", "updated": if current.date == nil { current.date = value }
        case "description", "content:encoded", "content", "summary": if current.description == nil { current.description = value }
        case "yt:videoid": if current.videoID == nil { current.videoID = value }
        case "category": if !value.isEmpty { current.categories.append(value) }
        case "item", "entry":
            if current.title != nil, current.link != nil { items.append(current) }
            item = nil
            return
        default: break
        }
        item = current
    }
}
