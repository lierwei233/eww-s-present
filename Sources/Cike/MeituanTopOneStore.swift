import Foundation
import Combine

/// Calls a product-owned proxy. The proxy is responsible for the contracted
/// Meituan API integration and must never expose partner credentials to this app.
@MainActor
final class MeituanTopOneStore: ObservableObject {
    @Published private var recommendations: [MealPeriod: MeituanTopOne] = [:]
    private var loadedPeriods = Set<MealPeriod>()

    func topOne(for period: MealPeriod) -> MeituanTopOne? {
        recommendations[period]
    }

    func loadTopOne(for period: MealPeriod) async {
        guard !loadedPeriods.contains(period) else { return }
        loadedPeriods.insert(period)

        guard let endpoint = Self.endpoint else { return }

        var request = URLRequest(url: endpoint.appending(path: "v1/recommendations/meituan/top1"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8

        let payload = TopOneRequest(
            mealPeriod: period.rawValue,
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }

            let topOne = try JSONDecoder().decode(MeituanTopOne.self, from: data)
            guard topOne.source == "meituan", topOne.rank == 1, topOne.landingURL != nil else { return }
            recommendations[period] = topOne
        } catch {
            // The UI keeps its explicit prototype fallback when the service is unavailable.
        }
    }

    private static var endpoint: URL? {
        let configuredValue = UserDefaults.standard.string(forKey: "MeituanRecommendationEndpoint")
            ?? Bundle.main.object(forInfoDictionaryKey: "MeituanRecommendationEndpoint") as? String
        guard let configuredValue,
              let url = URL(string: configuredValue),
              url.scheme == "https" else { return nil }
        return url
    }
}

private struct TopOneRequest: Encodable {
    let mealPeriod: String
    let locale: String
    let timeZone: String
}

struct MeituanTopOne: Decodable {
    let source: String
    let rank: Int
    let itemName: String
    let description: String
    let priceText: String
    let deliveryText: String
    let shopName: String
    let landingURL: URL?
    let updatedAt: String

    var statusText: String {
        "美团当前 Top 1 · \(shopName) · 更新于 \(updatedAt)"
    }
}
