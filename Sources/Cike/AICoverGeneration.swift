import Combine
import Foundation
import Security
import SwiftUI

@MainActor
final class AICoverGeneration: ObservableObject {
    @Published private(set) var generatedURLs: [String: URL] = [:]
    @Published var hasAPIKey: Bool
    @Published var pendingAPIKey = ""
    @Published private(set) var didSaveAPIKey = false
    @Published var isShowingSetup = false

    private let service = "com.cike.menubar.dashscope"
    private let account = "api-key"
    private var apiKey: String?
    @Published private var generating = Set<String>()
    @Published private var failed = Set<String>()

    init() {
        apiKey = Keychain.value(service: service, account: account)
        hasAPIKey = apiKey != nil
    }

    func imageURL(for article: SspaiArticle) -> URL? {
        let key = cacheKey(for: article)
        if let cached = generatedURLs[key] { return cached }
        let fileURL = cacheDirectory.appendingPathComponent("\(key).png")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        generatedURLs[key] = fileURL
        return fileURL
    }

    func isGenerating(_ article: SspaiArticle) -> Bool {
        generating.contains(cacheKey(for: article))
    }

    func hasFailed(_ article: SspaiArticle) -> Bool {
        failed.contains(cacheKey(for: article))
    }

    func generateIfNeeded(for article: SspaiArticle, force: Bool = false) {
        guard (force || article.coverURL == nil), let apiKey else { return }
        let key = cacheKey(for: article)
        guard imageURL(for: article) == nil, !failed.contains(key), generating.insert(key).inserted else { return }

        Task { [weak self] in
            let generated = await DashScopeCoverClient.generate(title: article.title, source: article.source, apiKey: apiKey)
            guard let self else { return }
            defer { self.generating.remove(key) }
            guard let generated else {
                self.failed.insert(key)
                return
            }
            do {
                try FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
                try generated.write(to: self.cacheDirectory.appendingPathComponent("\(key).png"), options: .atomic)
                self.generatedURLs[key] = self.cacheDirectory.appendingPathComponent("\(key).png")
            } catch {
                self.failed.insert(key)
            }
        }
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.save(trimmed, service: service, account: account)
        self.apiKey = trimmed
        hasAPIKey = true
        pendingAPIKey = ""
        didSaveAPIKey = true
    }

    func removeAPIKey() {
        Keychain.remove(service: service, account: account)
        apiKey = nil
        hasAPIKey = false
        didSaveAPIKey = false
    }

    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cike/AICovers", isDirectory: true)
    }

    private func cacheKey(for article: SspaiArticle) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in article.url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct AICoverSettingsView: View {
    @ObservedObject var generation: AICoverGeneration

    var body: some View {
        Form {
            Section("AI 封面") {
                Text("文章没有原始首图时，此刻会根据标题生成一张语意相近的封面。已有首图的文章不会调用生成服务。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                SecureField(generation.hasAPIKey ? "已保存新的 API Key 可在这里替换" : "DashScope API Key", text: $generation.pendingAPIKey)
                HStack {
                    Button("保存密钥") {
                        generation.saveAPIKey(generation.pendingAPIKey)
                    }
                    .disabled(generation.pendingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if generation.hasAPIKey {
                        Button("移除密钥", role: .destructive) { generation.removeAPIKey() }
                    }
                    if generation.didSaveAPIKey {
                        Text("已保存到此 Mac 的钥匙串")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("调用方式") {
                Text("标题由 qwen3.8-flash 转成画面提示词，再交给 wan2.6-t2i 生成一张 16:9 图片。每次只生成 1 张，并缓存到本机。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 280)
        .padding()
    }
}

struct AICoverSetupAdvice: View {
    @ObservedObject var generation: AICoverGeneration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("开启 AI 封面")
                .font(.system(size: 18, weight: .semibold))
            Text("没有原图的内容会根据标题生成一张语意相近的封面。密钥只保存在这台 Mac 的钥匙串中。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(generation.hasAPIKey ? "输入新的 DashScope API Key 以替换" : "粘贴 DashScope API Key", text: $generation.pendingAPIKey)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Button("保存并启用") {
                    generation.saveAPIKey(generation.pendingAPIKey)
                }
                .buttonStyle(.borderedProminent)
                .disabled(generation.pendingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if generation.hasAPIKey {
                    Text("已保存")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 150, alignment: .top)
    }
}

private enum Keychain {
    static func value(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, service: String, account: String) {
        remove(service: service, account: account)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(value.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func remove(service: String, account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum DashScopeCoverClient {
    static func generate(title: String, source: String, apiKey: String) async -> Data? {
        let prompt = await visualPrompt(title: title, source: source, apiKey: apiKey)
            ?? "为文章《\(title)》创作一张克制、明亮、有编辑感的中文内容封面插画；不含任何文字、商标或人物肖像。"
        guard let imageURL = await createImage(prompt: prompt, apiKey: apiKey) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: imageURL)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { return nil }
            return data
        } catch { return nil }
    }

    private static func visualPrompt(title: String, source: String, apiKey: String) async -> String? {
        let request = ChatRequest(
            model: "qwen3.8-flash",
            messages: [
                .init(role: "system", content: "你是内容编辑的视觉策展人。根据文章标题写一条中文文生图提示词，限 90 字以内。画面应有杂志感、明亮、克制；不要文字、logo、人物肖像、名人、受版权保护的角色。只输出提示词。"),
                .init(role: "user", content: "来源：\(source)\n标题：\(title)")
            ],
            temperature: 0.55,
            maxTokens: 80,
            enableThinking: false
        )
        guard let data = try? JSONEncoder().encode(request),
              let response: ChatResponse = await sendJSON(
                url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
                body: data,
                apiKey: apiKey,
                timeout: 12
              ) else { return nil }
        return response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func createImage(prompt: String, apiKey: String) async -> URL? {
        let request = ImageRequest(
            model: "wan2.6-t2i",
            input: .init(messages: [.init(role: "user", content: [.init(text: prompt)])]),
            parameters: .init(promptExtend: false, watermark: false, n: 1, size: "1536*864")
        )
        guard let data = try? JSONEncoder().encode(request),
              let response: ImageResponse = await sendJSON(
                url: URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!,
                body: data,
                apiKey: apiKey,
                timeout: 40
              ) else { return nil }
        return response.output?.choices?.first?.message.content.first?.image.flatMap(URL.init(string:))
    }

    private static func sendJSON<Response: Decodable>(url: URL, body: Data, apiKey: String, timeout: TimeInterval) async -> Response? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { return nil }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch { return nil }
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int
        let enableThinking: Bool
        enum CodingKeys: String, CodingKey { case model, messages, temperature; case maxTokens = "max_tokens"; case enableThinking = "enable_thinking" }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        let choices: [Choice]
    }

    private struct ImageRequest: Encodable {
        struct Input: Encodable { struct Message: Encodable { struct Content: Encodable { let text: String }; let role: String; let content: [Content] }; let messages: [Message] }
        struct Parameters: Encodable { let promptExtend: Bool; let watermark: Bool; let n: Int; let size: String; enum CodingKeys: String, CodingKey { case watermark, n, size; case promptExtend = "prompt_extend" } }
        let model: String
        let input: Input
        let parameters: Parameters
    }

    private struct ImageResponse: Decodable {
        struct Output: Decodable { struct Choice: Decodable { struct Message: Decodable { struct Content: Decodable { let image: String? }; let content: [Content] }; let message: Message }; let choices: [Choice]? }
        let output: Output?
    }
}
