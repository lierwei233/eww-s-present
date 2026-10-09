import Foundation

/// A small, local history of observations and actions. It never stores message text,
/// screenshots, precise location, or the destination URL of an external link.
struct ContextEvent: Codable, Sendable {
    struct Place: Codable, Sendable {
        let appBundleID: String?
        let surface: String?
    }

    struct Inference: Codable, Sendable {
        let intent: String
        let source: String
    }

    let id: UUID
    let when: Date
    let place: Place
    let what: String
    let inference: Inference?
    let targetID: String?
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id, when, what, inference, targetID, durationSeconds
        case place = "where"
    }

    init(
        when: Date = .now,
        appBundleID: String?,
        surface: String? = nil,
        what: String,
        inference: Inference? = nil,
        targetID: String? = nil,
        durationSeconds: Int? = nil
    ) {
        id = UUID()
        self.when = when
        place = Place(appBundleID: appBundleID, surface: surface)
        self.what = what
        self.inference = inference
        self.targetID = targetID
        self.durationSeconds = durationSeconds
    }
}

actor ContextEventStore {
    static let shared = ContextEventStore()

    private let maxEvents = 300
    private let retention: TimeInterval = 14 * 24 * 60 * 60
    private let fileURL: URL
    private var events: [ContextEvent]

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cike", isDirectory: true)
        fileURL = directory.appendingPathComponent("context-events.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([ContextEvent].self, from: data) {
            events = decoded
        } else {
            events = []
        }
    }

    func record(_ event: ContextEvent) {
        let cutoff = Date.now.addingTimeInterval(-retention)
        events.append(event)
        events = Array(events.filter { $0.when >= cutoff }.suffix(maxEvents))
        persist()
    }

    func clear() {
        events.removeAll()
        persist()
    }

    private func persist() {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(events)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Event history is best-effort and must never block the recommendation UI.
        }
    }

    static func opaqueID(for value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
