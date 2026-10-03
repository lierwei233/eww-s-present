import Combine
import Foundation

/// Rotates one public, editorially selected article between several sources.
/// It uses public feeds and home pages only; no browser cookies or account data are read.
@MainActor
final class SspaiTopOneStore: ObservableObject {
    @Published private(set) var article: SspaiArticle?
    private let seenURLsKey = "Cike.shownContentURLs"
    private let sourceCursorKey = "Cike.contentSourceCursor"
    private let sourceRotationVersionKey = "Cike.contentSourceRotationVersion"
    private var isLoading = false

    func loadNext() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let sources = ContentSource.allCases
        let start: Int
        if UserDefaults.standard.integer(forKey: sourceRotationVersionKey) < 2 {
            // Begin this expanded rotation with the newly added lighter sources.
            start = ContentSource.guokr.index
            UserDefaults.standard.set(2, forKey: sourceRotationVersionKey)
        } else {
            start = UserDefaults.standard.integer(forKey: sourceCursorKey) % sources.count
        }
        let ordered = (0..<sources.count).map { sources[(start + $0) % sources.count] }
        var fallback: (ContentSource, SspaiArticle)?
        var chosen: (ContentSource, SspaiArticle)?
        let seen = Set(UserDefaults.standard.stringArray(forKey: seenURLsKey) ?? [])
        for source in ordered {
            let articles = await source.loadArticles()
            guard let first = articles.first else { continue }
            fallback = fallback ?? (source, first)
            if let article = articles.first(where: { !seen.contains($0.url.absoluteString) }) {
                chosen = (source, article)
                break
            }
        }
        var seenURLs = UserDefaults.standard.stringArray(forKey: seenURLsKey) ?? []
        if chosen == nil, let fallback {
            seenURLs.removeAll()
            chosen = fallback
        }
        guard let (source, next) = chosen else { return }

        seenURLs.append(next.url.absoluteString)
        UserDefaults.standard.set(Array(seenURLs.suffix(80)), forKey: seenURLsKey)
        UserDefaults.standard.set((source.index + 1) % sources.count, forKey: sourceCursorKey)
        var displayArticle = next
        if source.needsChineseTitle, let translatedTitle = await ContentSource.translateTitle(next.title) {
            displayArticle = next.with(title: translatedTitle)
        }
        article = displayArticle

        if source == .sspai {
            let details = await articleDetails(at: next.url)
            guard article?.url == next.url else { return }
            article = displayArticle.with(details: details)
        }
    }

    private func articleDetails(at url: URL) async -> SspaiArticle.Details {
        guard let html = await ContentSource.loadHTML(from: url) else { return .empty }
        return SspaiArticle.Details.parse(from: html)
    }
}

private enum ContentSource: CaseIterable {
    case sspai, quanta, guokr, gcores, atlasObscura, mcSweeneys

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var needsChineseTitle: Bool { self == .quanta || self == .atlasObscura || self == .mcSweeneys }

    func loadArticles() async -> [SspaiArticle] {
        switch self {
        case .sspai:
            guard let html = await Self.loadHTML(from: URL(string: "https://sspai.com/")!) else { return [] }
            return SspaiArticle.parseAll(from: html)
        case .quanta:
            return await Self.loadRSS(url: "https://www.quantamagazine.org/feed/", source: "Quanta Magazine")
        case .guokr:
            guard let html = await Self.loadHTML(from: URL(string: "https://www.guokr.com/")!) else { return [] }
            return Self.parseLinkedText(html, source: "果壳", host: "https://www.guokr.com", requiredPath: "/article/")
        case .gcores:
            guard let html = await Self.loadHTML(from: URL(string: "https://www.gcores.com/articles?page=1")!) else { return [] }
            return Self.parseLinkedHeadings(html, source: "机核", host: "https://www.gcores.com", requiredPath: "/articles/")
        case .atlasObscura:
            return await Self.loadRSS(url: "https://www.atlasobscura.com/feeds/latest", source: "Atlas Obscura")
        case .mcSweeneys:
            return await Self.loadRSS(url: "https://feeds.feedburner.com/mcsweeneys", source: "McSweeney’s")
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

    static func loadRSS(url: String, source: String) async -> [SspaiArticle] {
        guard let url = URL(string: url), let xml = await loadHTML(from: url) else { return [] }
        return RSSParser.parse(xml).compactMap { item in
            guard let title = item.title, let link = item.link, let articleURL = URL(string: link), !title.isEmpty else { return nil }
            return SspaiArticle(title: title, url: articleURL, source: source, coverURL: item.imageURL, date: item.date)
        }
    }

    static func parseLinkedText(_ html: String, source: String, host: String, requiredPath: String) -> [SspaiArticle] {
        let cardPattern = #"<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>([\s\S]{0,2400}?)</a>"#
        var output: [SspaiArticle] = []
        var used = Set<String>()
        for match in SspaiArticle.allMatches(cardPattern, in: html) where match.count == 3 {
            guard let url = URL(string: match[1], relativeTo: URL(string: host))?.absoluteURL,
                  url.host == URL(string: host)?.host,
                  url.path.contains(requiredPath) else { continue }
            let title = SspaiArticle.htmlText(match[2])
            guard title.count >= 6, title.count <= 180, used.insert(url.absoluteString).inserted else { continue }
            output.append(SspaiArticle(title: title, url: url, source: source, coverURL: nil))
            if output.count == 8 { break }
        }
        return output
    }

    static func parseLinkedHeadings(_ html: String, source: String, host: String, requiredPath: String) -> [SspaiArticle] {
        let cardPattern = #"<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(?:(?!</a>)[\s\S])*?<h[1-4]\b[^>]*>([\s\S]*?)</h[1-4]>"#
        let matches = SspaiArticle.allMatches(cardPattern, in: html)
        var output: [SspaiArticle] = []
        var used = Set<String>()
        for match in matches where match.count == 3 {
            guard let url = URL(string: match[1], relativeTo: URL(string: host))?.absoluteURL,
                  url.host == URL(string: host)?.host,
                  url.path.contains(requiredPath) else { continue }
            let title = SspaiArticle.htmlText(match[2])
            guard title.count >= 6, title.count <= 180, used.insert(url.absoluteString).inserted else { continue }
            output.append(SspaiArticle(title: title, url: url, source: source, coverURL: nil))
            if output.count == 8 { break }
        }
        return output
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

struct SspaiArticle {
    let title: String
    let url: URL
    let source: String
    let coverURL: URL?
    let date: String?
    let author: String?
    let readingTime: String?

    init(title: String, url: URL, source: String, coverURL: URL?, date: String? = nil, author: String? = nil, readingTime: String? = nil) {
        self.title = title
        self.url = url
        self.source = source
        self.coverURL = coverURL
        self.date = date
        self.author = author
        self.readingTime = readingTime
    }

    var metadataText: String { [source, date, author, readingTime].compactMap { $0 }.joined(separator: " · ") }

    func with(details: Details) -> SspaiArticle {
        SspaiArticle(title: title, url: url, source: source, coverURL: coverURL, date: details.date, author: details.author, readingTime: details.readingTime)
    }

    func with(title: String) -> SspaiArticle {
        SspaiArticle(title: title, url: url, source: source, coverURL: coverURL, date: date, author: author, readingTime: readingTime)
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
        return SspaiArticle(title: title, url: url, source: "少数派", coverURL: nil)
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
    struct Item { var title: String?; var link: String?; var date: String?; var imageURL: URL? }
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
        if (element == "media:content" || element == "enclosure"), let value = attributeDict["url"], item?.imageURL == nil {
            item?.imageURL = URL(string: value)
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
        case "item", "entry":
            if current.title != nil, current.link != nil { items.append(current) }
            item = nil
            return
        default: break
        }
        item = current
    }
}
