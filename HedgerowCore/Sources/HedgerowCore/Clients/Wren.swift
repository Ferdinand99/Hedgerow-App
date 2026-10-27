import Foundation

/// Wise Wren: updates waiting, runs in progress, runs that failed in the last 24 hours.
///
/// - `GET /api/v1/updates` lists the targets with a new version (`{"targets": [...]}`);
///   there is no count-only form, so its length is the count and only names are kept.
/// - `GET /api/v1/runs?limit=50` lists runs, newest first (`{"runs": [...]}`; `limit` is the
///   documented parameter, at most 500). Failed means `failed`, `rolled_back` or
///   `rollback_failed`; in progress means `queued` or `running`.
public struct WrenClient: ServiceClient {
    static let updatesPath = "/api/v1/updates"
    static let runsPath = "/api/v1/runs?limit=50"
    static let failedStatuses: Set<String> = ["failed", "rolled_back", "rollback_failed"]
    static let activeStatuses: Set<String> = ["queued", "running"]

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

    private struct Named: Decodable {
        let name: String?
    }

    private struct UpdateList: Decodable {
        struct Item: Decodable {
            let name: String
            let server: Named?
        }

        let targets: [Item]
    }

    private struct RunList: Decodable {
        struct Item: Decodable {
            let status: String
            let createdAt: String?
            let finishedAt: String?
            let target: Named?

            enum CodingKeys: String, CodingKey {
                case status
                case createdAt = "created_at"
                case finishedAt = "finished_at"
                case target
            }
        }

        let runs: [Item]
    }

    public func summary() async throws -> ServiceSummary {
        let updates = try await http.getDecoded(UpdateList.self, Self.updatesPath, from: baseURL)
        let runs = try await http.getDecoded(RunList.self, Self.runsPath, from: baseURL)

        let current = now()
        let dayAgo = current.addingTimeInterval(-24 * 3600)
        let failed = runs.runs.filter { run in
            guard Self.failedStatuses.contains(run.status) else { return false }
            return parseServerTimestamp(run.finishedAt ?? run.createdAt).map { $0 >= dayAgo } ?? false
        }
        let running = runs.runs.filter { Self.activeStatuses.contains($0.status) }.count
        let pending = updates.targets.count

        var details = failed.prefix(2).map { SummaryLine("%@ failed", .text($0.target?.name ?? "?")) }
        if failed.count > 2 {
            details.append(SummaryLine("%lld more failed", .number(failed.count - 2)))
        }
        if running > 0 { details.append(SummaryLine("%lld running", .number(running))) }
        let shown = updates.targets.prefix(3)
        for target in shown {
            if let server = target.server?.name, !server.isEmpty {
                details.append(SummaryLine("%1$@ on %2$@ has an update", .text(target.name), .text(server)))
            } else {
                details.append(SummaryLine("%@ has an update", .text(target.name)))
            }
        }
        if pending > shown.count {
            details.append(SummaryLine("%lld more with updates", .number(pending - shown.count)))
        }

        let health: Health
        let headline: SummaryLine
        if !failed.isEmpty {
            health = .critical
            headline = SummaryLine("%lld failed in 24 h", .number(failed.count))
        } else if pending > 0 {
            health = .warning
            headline = SummaryLine("%lld updates pending", .number(pending))
        } else {
            health = .ok
            headline = SummaryLine("Everything up to date")
        }
        return ServiceSummary(kind: .wren, health: health, headline: headline, details: details, fetchedAt: current)
    }
}

// MARK: - Lists and detail (Updates tab)

extension WrenClient {
    /// Runs asked for in the tab; the newest first. The server allows 500, the screen needs a few.
    public static let recentRunsLimit = 30

    /// The servers with their agents' status and mode.
    /// `GET /api/v1/servers`
    public func servers() async throws -> [WrenServer] {
        try await http.getDecoded(WrenServersDTO.self, "/api/v1/servers", from: baseURL).servers.map(\.model)
    }

    /// The targets that have a new version, with the versions Wren knows. One request: the
    /// server has no pages for this list (88 targets are about 60 kB).
    /// `GET /api/v1/updates`
    public func updates() async throws -> [WrenTarget] {
        try await http.getDecoded(WrenTargetsDTO.self, Self.updatesPath, from: baseURL).targets.map(\.model)
    }

    /// Runs, newest first. `limit` is clamped to 1...500, the range the server accepts.
    /// `GET /api/v1/runs?limit=`
    public func runs(limit: Int = WrenClient.recentRunsLimit) async throws -> [WrenRun] {
        let path = "/api/v1/runs?limit=\(min(max(limit, 1), 500))"
        return try await http.getDecoded(WrenRunsDTO.self, path, from: baseURL).runs.map(\.model)
    }

    /// One run with its steps (status, duration and the end of each step's log).
    /// `HedgerowError.badResponse(404)` when there is no such run.
    /// `GET /api/v1/runs/{id}`
    public func run(id: Int) async throws -> WrenRunDetail {
        let dto = try await http.getDecoded(WrenRunDetailDTO.self, "/api/v1/runs/\(id)", from: baseURL)
        return WrenRunDetail(run: dto.run.model, steps: dto.steps.enumerated().map { $0.element.model(at: $0.offset) })
    }

    /// Updates approved for a later time (soonest first), and each server's auto window.
    /// Empty when the server does not know schedules (an older Wise Wren).
    /// `GET /api/v1/schedules`
    public func schedules() async throws -> WrenSchedules {
        let dto: WrenSchedulesDTO
        do {
            dto = try await http.getDecoded(WrenSchedulesDTO.self, "/api/v1/schedules", from: baseURL)
        } catch HedgerowError.badResponse(404) {
            return WrenSchedules(timeZone: nil, scheduled: [], servers: [])
        }
        return WrenSchedules(
            timeZone: dto.timeZone.flatMap { $0.isEmpty ? nil : $0 }, scheduled: dto.scheduled.map(\.model),
            servers: dto.servers.map(\.model)
        )
    }
}
