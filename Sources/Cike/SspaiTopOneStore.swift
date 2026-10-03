import Combine
import Foundation

/// Reads one article from the public recommendation list on sspai.com.
/// It deliberately does not access browser cookies or account-specific data.
@MainActor
final class SspaiTopOneStore: ObservableObject {
    @Published private(set) var article: SspaiArticle?
    private var isLoading = false
    private let seenURLsKey = "Cike.shownContentURLs"

    func loadNext() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await loadSspai()
    }

    private func loadSspai() async {
        var request = URLRequest(url: URL(string: "https://sspai.com/")!)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return }
            let candidates = SspaiArticle.parseAll(from: html)
            guard !candidates.isEmpty else { return }

            var seenURLs = UserDefaults.standard.stringArray(forKey: seenURLsKey) ?? []
            let seen = Set(seenURLs)
            let next = candidates.first(where: { !seen.contains($0.url.absoluteString) }) ?? candidates[0]
            if seen.contains(next.url.absoluteString) {
                seenURLs.removeAll()
            }
            seenURLs.append(next.url.absoluteString)
            UserDefaults.standard.set(Array(seenURLs.suffix(50)), forKey: seenURLsKey)
            article = next
            let details = await articleDetails(at: next.url)
            guard article?.url == next.url else { return }
            article = next.with(details: details)
        } catch {
            // The recommendation view keeps its original local suggestion on a network failure.
        }
    }

    private func articleDetails(at url: URL) async -> SspaiArticle.Details {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return .empty }
            return SspaiArticle.Details.parse(from: html)
        } catch {
            return .empty
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

    init(title: String, url: URL, source: String, coverURL: URL?, date: String? = nil, author: String? = nil, readingTime: String? = nil) {
        self.title = title
        self.url = url
        self.source = source
        self.coverURL = coverURL
        self.date = date
        self.author = author
        self.readingTime = readingTime
    }

    var metadataText: String {
        [source, date, author, readingTime].compactMap { $0 }.joined(separator: " · ")
    }

    func with(details: Details) -> SspaiArticle {
        SspaiArticle(
            title: title,
            url: url,
            source: source,
            coverURL: coverURL,
            date: details.date,
            author: details.author,
            readingTime: details.readingTime
        )
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
        let href = hrefMatch[1]
        let titlePattern = #"<p\b[^>]*\bclass=[\"'][^\"']*article__card__title[^\"']*[\"'][^>]*>([\s\S]*?)</p>"#
        guard let titleMatch = firstMatch(titlePattern, in: body), titleMatch.count == 2 else { return nil }

        let title = htmlText(titleMatch[1])
        guard !title.isEmpty, let url = URL(string: href, relativeTo: URL(string: "https://sspai.com"))?.absoluteURL else { return nil }
        let coverPattern = #"<div\b(?=[^>]*\bclass=[\"'][^\"']*article__card__cover[^\"']*[\"'])[^>]*>[\s\S]*?<img\b[^>]*(?:\bdata-src|\bsrc)=[\"']([^\"']+)[\"']"#
        let coverURL: URL?
        if let match = firstMatch(coverPattern, in: body), match.count > 1 {
            coverURL = URL(string: match[1])
        } else {
            coverURL = nil
        }
        return SspaiArticle(title: title, url: url, source: "少数派", coverURL: coverURL)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func allMatches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
        }
    }

    private static func htmlText(_ value: String) -> String {
        let withoutTags = value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return entities.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
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
            let text = htmlText(match[1])
            return text.isEmpty ? nil : text
        }
    }
}
