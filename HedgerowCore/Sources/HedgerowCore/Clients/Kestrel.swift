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

// MARK: - Lists and detail (Issues tab)

extension KestrelClient {
    /// Issues per request. 100 keeps a page far below the 2 MiB limit and the first rows quick.
    public static let issuePageSize = 100
    /// Projects per request (the server's largest page); a few pages cover any installation.
    static let projectPageSize = 500
    static let maxProjectPages = 20

    /// Every project with the project group it is in. The groups are only presentation: when the
    /// group list cannot be had (an older Keen Kestrel, or any failure of that one request), the
    /// projects come back ungrouped.
    /// `GET /api/v1/projects?limit=500&cursor=` (all pages) and `GET /api/v1/project-groups`.
    public func projects() async throws -> [KestrelProject] {
        async let groupList = orFallback([]) { try await projectGroups() }
        let rows = try await projectRows()
        let groups = Dictionary(try await groupList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            KestrelProject(
                id: row.id, name: row.name, platform: row.platform ?? "other",
                group: row.groupId.flatMap { groups[$0] }
            )
        }
    }

    /// The project groups, in the project list's order. `[]` if the server does not know groups.
    public func projectGroups() async throws -> [KestrelProjectGroup] {
        do {
            let list = try await http.getDecoded(
                KestrelListDTO<KestrelProjectGroupDTO>.self, "/api/v1/project-groups", from: baseURL
            )
            return list.data.map(\.model)
        } catch HedgerowError.badResponse(404) {
            return []
        }
    }

    private func projectRows() async throws -> [KestrelProjectDTO] {
        var all: [KestrelProjectDTO] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<Self.maxProjectPages {
            var path = "/api/v1/projects?limit=\(Self.projectPageSize)"
            if let cursor { path += "&cursor=" + VoleClient.queryEncoded(cursor) }
            let page = try await http.getDecoded(KestrelListDTO<KestrelProjectDTO>.self, path, from: baseURL)
            all += page.data
            guard let next = page.nextCursor else { break }
            // A cursor that comes back means the server is going in circles.
            guard seen.insert(next).inserted else { throw HedgerowError.unexpectedResponse }
            cursor = next
        }
        return all
    }

    /// One page of a project's unresolved issues, most recently active first.
    /// `GET /api/v1/projects/{id}/issues?status=unresolved&sort=last_seen&limit=&cursor=`
    /// (the cursor is the server's `next_cursor`; `total` is all matches).
    public func issuesPage(
        projectId: Int, cursor: String? = nil, limit: Int = KestrelClient.issuePageSize
    ) async throws -> KestrelIssuePage {
        var path = "/api/v1/projects/\(projectId)/issues?status=unresolved&sort=last_seen&limit=\(min(max(limit, 1), 500))"
        if let cursor { path += "&cursor=" + VoleClient.queryEncoded(cursor) }
        let page = try await http.getDecoded(KestrelListDTO<KestrelIssueDTO>.self, path, from: baseURL)
        return KestrelIssuePage(issues: page.data.map(\.model), nextCursor: page.nextCursor, total: page.total)
    }

    /// Unresolved issues of a project, newest activity first, one page at a time: ask again with
    /// `next` until it is `nil`.
    public func issues(projectId: Int, cursor: String? = nil) async throws -> (issues: [KestrelIssue], next: String?) {
        let page = try await issuesPage(projectId: projectId, cursor: cursor)
        return (page.issues, page.nextCursor)
    }

    /// How many unresolved issues a project has: one request for one issue, read from `total`.
    public func unresolvedCount(projectId: Int) async throws -> Int? {
        try await issuesPage(projectId: projectId, limit: 1).total
    }

    /// The issue's newest event that still has its details: level, release, environment, stack
    /// and tags. `HedgerowError.badResponse(404)` when no event of the issue has details left.
    /// `GET /api/v1/projects/{id}/issues/{issue_id}/events/latest`
    public func latestEvent(projectId: Int, issueId: Int) async throws -> KestrelEvent {
        let dto = try await http.getDecoded(
            KestrelEventDTO.self, "/api/v1/projects/\(projectId)/issues/\(issueId)/events/latest", from: baseURL
        )
        return dto.model
    }
}
