import Foundation

/// Vigilant Vole: how many monitors are up, down, paused.
///
/// Two calls, so a big installation never has to send every monitor:
/// - `GET /api/v1/health` has `monitors.total` and `monitors.by_status` for all monitors;
/// - only when something is down, `GET /api/v1/monitors?status=down&limit=500` names the
///   ones that are down, and says which are covered by a maintenance window (those do not count).
public struct VoleClient: ServiceClient {
    static let healthPath = "/api/v1/health"
    static let downPath = "/api/v1/monitors?status=down&limit=500"

    let baseURL: URL
    let http: HedgerowHTTP
    let now: @Sendable () -> Date

    public init(baseURL: URL, http: HedgerowHTTP) {
        self.init(baseURL: baseURL, http: http, now: { Date() })
    }

    init(baseURL: URL, http: HedgerowHTTP, now: @escaping @Sendable () -> Date) {
        self.baseURL = baseURL
        self.http = http
        self.now = now
    }

    private struct HealthResponse: Decodable {
        struct Monitors: Decodable {
            let total: Int?
            let byStatus: [String: Int]?

            enum CodingKeys: String, CodingKey {
                case total
                case byStatus = "by_status"
            }
        }

        let monitors: Monitors
    }

    private struct MonitorList: Decodable {
        struct Item: Decodable {
            let name: String
            let status: String?
            let maintenance: Bool?
        }

        let data: [Item]
        let nextCursor: String?

        enum CodingKeys: String, CodingKey {
            case data
            case nextCursor = "next_cursor"
        }
    }

    public func summary() async throws -> ServiceSummary {
        let health = try await http.getDecoded(HealthResponse.self, Self.healthPath, from: baseURL)
        let counts = health.monitors.byStatus ?? [:]
        let total = health.monitors.total ?? counts.values.reduce(0, +)
        var down = counts["down"] ?? 0
        var downNames: [String] = []

        if down > 0 {
            let list = try await http.getDecoded(MonitorList.self, Self.downPath, from: baseURL)
            let real = list.data.filter { ($0.maintenance ?? false) == false && $0.status != "maintenance" }
            downNames = real.map(\.name)
            // A page that is cut off cannot be counted; the health count then stands.
            down = list.nextCursor == nil ? real.count : down
        }

        let up = counts["up"] ?? 0
        let paused = counts["paused"] ?? 0
        let pending = counts["pending"] ?? 0

        var details = downNames.prefix(3).map { SummaryLine("%@ is down", .text($0)) }
        if down > details.count {
            details.append(SummaryLine("%lld more down", .number(down - details.count)))
        }
        if paused > 0 { details.append(SummaryLine("%lld paused", .number(paused))) }
        if pending > 0 { details.append(SummaryLine("%lld pending", .number(pending))) }

        let healthValue: Health
        let headline: SummaryLine
        if down > 0 {
            healthValue = .critical
            headline = SummaryLine("%lld down", .number(down))
        } else if total == 0 {
            healthValue = .unknown
            headline = SummaryLine("No monitors")
        } else {
            healthValue = .ok
            headline = SummaryLine("%lld up", .number(up))
        }
        return ServiceSummary(kind: .vole, health: healthValue, headline: headline, details: details, fetchedAt: now())
    }
}
