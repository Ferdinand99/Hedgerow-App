import Foundation

/// Keen Kestrel: unresolved issues, and how many appeared in the last 24 hours.
///
/// - `GET /api/v1/projects?limit=20` (the summary reads at most 20 projects; `next_cursor`
///   says there were more);
/// - per project `GET /api/v1/projects/{id}/issues?status=unresolved&sort=first_seen&limit=20`:
///   `total` is the unresolved count, and the newest 20 by `first_seen` show how many are
///   younger than 24 hours. At most 4 projects are asked at once.
public struct KestrelClient: ServiceClient {
    static let maxProjects = 20
    static let issuesPerProject = 20
    static let concurrency = 4
    static let projectsPath = "/api/v1/projects?limit=\(maxProjects)"

    static func issuesPath(_ projectID: Int) -> String {
        "/api/v1/projects/\(projectID)/issues?status=unresolved&sort=first_seen&limit=\(issuesPerProject)"
    }

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

    private struct ProjectList: Decodable {
        struct Item: Decodable {
            let id: Int
            let name: String
        }

        let data: [Item]
        let nextCursor: String?

        enum CodingKeys: String, CodingKey {
            case data
            case nextCursor = "next_cursor"
        }
    }

    private struct IssueList: Decodable {
        struct Item: Decodable {
            let firstSeen: String?

            enum CodingKeys: String, CodingKey {
                case firstSeen = "first_seen"
            }
        }

        let data: [Item]
        let total: Int?
    }

    private struct ProjectCount: Sendable {
        let name: String
        let unresolved: Int
        let new: Int
    }

    public func summary() async throws -> ServiceSummary {
        let projectList = try await http.getDecoded(ProjectList.self, Self.projectsPath, from: baseURL)
        let projects = Array(projectList.data.prefix(Self.maxProjects))
        let moreProjects = projectList.nextCursor != nil || projectList.data.count > Self.maxProjects

        let current = now()
        let dayAgo = current.addingTimeInterval(-24 * 3600)
        let http = self.http
        let baseURL = self.baseURL
        let counts = try await boundedMap(projects, limit: Self.concurrency) { project in
            let issues = try await http.getDecoded(IssueList.self, Self.issuesPath(project.id), from: baseURL)
            let new = issues.data.filter { item in
                parseServerTimestamp(item.firstSeen).map { $0 >= dayAgo } ?? false
            }.count
            return ProjectCount(name: project.name, unresolved: issues.total ?? issues.data.count, new: new)
        }

        let unresolved = counts.reduce(0) { $0 + $1.unresolved }
        let new = counts.reduce(0) { $0 + $1.new }

        let busiest = counts.filter { $0.unresolved > 0 }.sorted {
            ($0.new, $0.unresolved) > ($1.new, $1.unresolved)
        }
        var details = busiest.prefix(moreProjects ? ServiceSummary.maxDetails - 1 : ServiceSummary.maxDetails).map {
            SummaryLine("%1$@: %2$lld unresolved, %3$lld new", .text($0.name), .number($0.unresolved), .number($0.new))
        }
        if moreProjects {
            details.append(SummaryLine("Only the first %lld projects are counted", .number(Self.maxProjects)))
        }

        let health: Health
        let headline: SummaryLine
        if projects.isEmpty {
            health = .unknown
            headline = SummaryLine("No projects")
        } else if new > 0 {
            health = .warning
            headline = SummaryLine("%lld new in 24 h", .number(new))
        } else {
            health = .ok
            headline = unresolved > 0
                ? SummaryLine("%lld unresolved", .number(unresolved))
                : SummaryLine("No open issues")
        }
        return ServiceSummary(kind: .kestrel, health: health, headline: headline, details: details, fetchedAt: current)
    }
}
