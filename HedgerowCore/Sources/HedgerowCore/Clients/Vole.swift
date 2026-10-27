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

// MARK: - Lists and detail (Monitors tab)

extension VoleClient {
    /// Monitors per request. 250 is about 200 kB of JSON: far under the 2 MiB limit, few requests for
    /// a big installation, and the first rows still quick.
    public static let pageSize = 250
    /// Pages followed at most by `monitors()` (20 000 monitors), so a server that never ends its
    /// list cannot keep the app busy.
    static let maxPages = 80

    /// One page of monitors (ordered by id), `nextCursor` set while there are more.
    /// `GET /api/v1/monitors?limit=&cursor=`
    public func monitorsPage(cursor: String? = nil, limit: Int = VoleClient.pageSize) async throws -> VoleMonitorPage {
        var path = "/api/v1/monitors?limit=\(min(max(limit, 1), 500))"
        if let cursor { path += "&cursor=" + Self.queryEncoded(cursor) }
        let page = try await http.getDecoded(VoleMonitorPageDTO.self, path, from: baseURL)
        return VoleMonitorPage(monitors: page.data.map(\.model), nextCursor: page.nextCursor)
    }

    /// Every monitor, page by page, each with the name of its group filled in. `progress` gets
    /// everything loaded so far after each page, so a screen can show the first rows at once.
    public func monitors(
        progress: (@MainActor @Sendable (_ soFar: [VoleMonitor]) -> Void)? = nil
    ) async throws -> [VoleMonitor] {
        var all: [VoleMonitor] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<Self.maxPages {
            let page = try await monitorsPage(cursor: cursor)
            all += page.monitors
            if let progress, page.nextCursor != nil { await progress(VoleMonitor.resolvingGroups(all)) }
            guard let next = page.nextCursor else { break }
            // A cursor that comes back means the server is going in circles.
            guard seen.insert(next).inserted else { throw HedgerowError.unexpectedResponse }
            cursor = next
        }
        return VoleMonitor.resolvingGroups(all)
    }

    /// One monitor with its latest check, uptime (24 h and 30 d) and up to 20 recent events.
    /// Four requests, made together:
    /// `/monitors/{id}`, `/monitors/{id}/heartbeats?limit=1`, `/monitors/{id}/uptime?days=30`,
    /// `/monitors/{id}/events?limit=20`.
    public func monitor(id: Int) async throws -> VoleMonitorDetail {
        let base = "/api/v1/monitors/\(id)"
        async let monitor = http.getDecoded(VoleMonitorDTO.self, base, from: baseURL)
        async let heartbeats = http.getDecoded(VoleHeartbeatListDTO.self, base + "/heartbeats?limit=1", from: baseURL)
        async let uptime = http.getDecoded(VoleUptimeDTO.self, base + "/uptime?days=30", from: baseURL)
        async let events = http.getDecoded(
            VoleEventListDTO.self, base + "/events?limit=\(VoleMonitorDetail.maxEvents)", from: baseURL
        )
        let dto = try await monitor
        let heartbeat = try await heartbeats.data.first?.model
        let up = try await uptime
        let recent = try await events

        var model = dto.model
        model.responseMs = heartbeat?.responseMs
        return VoleMonitorDetail(
            monitor: model,
            description: dto.description.flatMap { $0.isEmpty ? nil : $0 },
            target: dto.target.flatMap { $0.isEmpty ? nil : $0 },
            rawMessage: dto.rawMessage,
            lastHeartbeat: heartbeat,
            uptime24h: up.uptime24hPct,
            uptime30d: up.uptimePct,
            events: Array(recent.data.prefix(VoleMonitorDetail.maxEvents)).map(\.model)
        )
    }

    /// Everything except unreserved characters is escaped, so a cursor from the server can never
    /// add a parameter of its own.
    static func queryEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
