import CryptoKit
import Foundation

/// Durable, local-only history for content that has appeared in the popover.
/// URL hashes avoid storing a readable browsing history on disk.
struct ContentHistoryStore {
    private struct Entry: Codable {
        let id: String
        let source: String
        let firstShownAt: Date
    }

    private let fileURL: URL
    private var entries: [Entry]
    private var seenIDs: Set<String>

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cike", isDirectory: true)
        fileURL = directory.appendingPathComponent("content-history.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? Data(contentsOf: fileURL))
            .flatMap { try? decoder.decode([Entry].self, from: $0) } ?? []
        seenIDs = Set(entries.map(\.id))

        // Preserve recommendations shown by versions that used UserDefaults.
        let previousURLs = UserDefaults.standard.stringArray(forKey: "Cike.shownContentURLs") ?? []
        for raw in previousURLs {
            guard let url = URL(string: raw) else { continue }
            let id = Self.id(for: url)
            guard seenIDs.insert(id).inserted else { continue }
            entries.append(Entry(id: id, source: "legacy", firstShownAt: Date(timeIntervalSince1970: 0)))
        }
        if !previousURLs.isEmpty && persist() {
            UserDefaults.standard.removeObject(forKey: "Cike.shownContentURLs")
        }
    }

    func hasShown(_ url: URL) -> Bool {
        seenIDs.contains(Self.id(for: url))
    }

    mutating func record(_ url: URL, source: String) {
        let id = Self.id(for: url)
        guard seenIDs.insert(id).inserted else { return }
        entries.append(Entry(id: id, source: source, firstShownAt: .now))
        _ = persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            // A storage failure must not block the popover.
            return false
        }
    }

    private static func id(for url: URL) -> String {
        var canonical = url.absoluteString
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let scheme = components.scheme?.lowercased()
            components.scheme = scheme
            if let host = components.host?.lowercased() {
                components.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            var path = components.path
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            components.path = path
            let queryItems = components.queryItems
            components.queryItems = queryItems?.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !["fbclid", "gclid", "ref", "source"].contains(name)
            }
            if components.host != "github.com" || components.path != "/trending" {
                components.fragment = nil
            }
            canonical = components.url?.absoluteString ?? canonical
        }
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
