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
