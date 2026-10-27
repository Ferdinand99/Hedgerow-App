import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HedgerowCore

private let base = URL(string: "https://kestrel.example.com")!

private func client(_ transport: StubTransport) -> KestrelClient {
    KestrelClient(baseURL: base, http: HedgerowHTTP(token: "kk_token", transport: transport))
}

private func key(_ request: URLRequest) -> String {
    let url = request.url!
    return url.query.map { url.path + "?" + $0 } ?? url.path
}

/// Answers by path and query; anything else is a 404.
private func router(_ table: [String: Data]) -> StubTransport {
    StubTransport { request in
        if let body = table[key(request)] { return (body, 200) }
        return (Data(), 404)
    }
}

private let projectsPath = "/api/v1/projects?limit=500"
private let groupsPath = "/api/v1/project-groups"
private let eventPath = "/api/v1/projects/1/issues/42/events/latest"

/// A project with `count` unresolved issues, served 100 at a time like the real list
/// (cursor = offset of the next page, `total` = all matches).
private func bigServer(count: Int) -> StubTransport {
    @Sendable func issueJSON(_ id: Int) -> String {
        #"{"id": \#(id), "project_id": 1, "title": "Issue \#(id)", "culprit": "app.module in function\#(id)", "level": "error", "platform": "python", "status": "unresolved", "substatus": "ongoing", "first_seen": "2026-10-01 08:00:00", "last_seen": "2026-10-22 09:15:00", "events": \#(id), "users": 2, "first_release": "app@1.0", "last_release": "app@1.1", "resolved_in_release": null, "ignore_until": null, "ignore_until_count": null, "grouping_config": "kestrel:v2", "unsymbolicated": false, "path": "/projects/1/issues/\#(id)"}"#
    }
    return StubTransport { request in
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let limit = Int(items.first { $0.name == "limit" }?.value ?? "") ?? 50
        let offset = Int(items.first { $0.name == "cursor" }?.value ?? "") ?? 0
        let ids = offset < count ? Array((offset + 1)...min(offset + limit, count)) : []
        let next = offset + limit < count ? "\"\(offset + limit)\"" : "null"
        let body = #"{"data": [\#(ids.map(issueJSON).joined(separator: ","))], "next_cursor": \#(next), "total": \#(count), "unknown_terms": []}"#
        return (Data(body.utf8), 200)
    }
}

@Suite struct KestrelProjectTests {
    private func server() throws -> StubTransport {
        router([
            projectsPath: try fixture("kestrel-projects.json"),
            groupsPath: try fixture("kestrel-project-groups.json"),
        ])
    }

    @Test func projectsComeWithTheirGroup() async throws {
        let transport = try server()
        let projects = try await client(transport).projects()

        #expect(Set(transport.requests.map(key)) == [projectsPath, groupsPath])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer kk_token" })
        #expect(projects.map(\.id) == [1, 2])

        let sylo = try #require(projects.first { $0.id == 1 })
        #expect(sylo.name == "Sylo for iOS")
        #expect(sylo.platform == "apple")
        #expect(sylo.group == KestrelProjectGroup(id: 2, name: "Sylo", sortOrder: 0))
        #expect(projects.first { $0.id == 2 }?.group == nil)
    }

    @Test func sectionsFollowTheGroupOrderThenTheUngrouped() async throws {
        let projects = try await client(try server()).projects()
        let sections = kestrelSections(projects)
        #expect(sections.map(\.title) == ["Sylo", nil])
        #expect(sections.map { $0.projects.map(\.id) } == [[1], [2]])
        #expect(sections.map(\.id) == ["group-2", "ungrouped"])
    }

    @Test func sectionsSortGroupsByPositionAndProjectsByName() {
        let late = KestrelProjectGroup(id: 1, name: "Alpha", sortOrder: 5)
        let early = KestrelProjectGroup(id: 2, name: "Zulu", sortOrder: 0)
        let projects = [
            KestrelProject(id: 1, name: "b-app", group: late),
            KestrelProject(id: 2, name: "A-app", group: late),
            KestrelProject(id: 3, name: "only", group: early),
        ]
        let sections = kestrelSections(projects)
        #expect(sections.map(\.title) == ["Zulu", "Alpha"])
        #expect(sections[1].projects.map(\.name) == ["A-app", "b-app"])
        #expect(kestrelSections([]).isEmpty)
    }

    @Test func aServerWithoutGroupsStillListsItsProjects() async throws {
        // An older Keen Kestrel answers 404 for the group list.
        let transport = router([projectsPath: try fixture("kestrel-projects.json")])
        let projects = try await client(transport).projects()
        #expect(projects.map(\.id) == [1, 2])
        #expect(projects.allSatisfy { $0.group == nil })
    }

    @Test func aGroupIdTheServerDidNotListLeavesTheProjectUngrouped() async throws {
        let transport = router([
            projectsPath: try fixture("kestrel-projects.json"),
            groupsPath: Data(#"{"data": [], "next_cursor": null}"#.utf8),
        ])
        #expect(try await client(transport).projects().allSatisfy { $0.group == nil })
    }

    @Test func projectsAreReadPageByPage() async throws {
        let page1 = Data(#"{"data": [{"id": 1, "name": "One", "group_id": null}], "next_cursor": "1"}"#.utf8)
        let page2 = Data(#"{"data": [{"id": 2, "name": "Two", "platform": "rust"}], "next_cursor": null}"#.utf8)
        let transport = router([
            projectsPath: page1, projectsPath + "&cursor=1": page2,
            groupsPath: Data(#"{"data": []}"#.utf8),
        ])
        let projects = try await client(transport).projects()
        #expect(projects.map(\.id) == [1, 2])
        #expect(projects.map(\.platform) == ["other", "rust"])
    }

    @Test func aProjectListThatLoopsItsCursorIsRefused() async throws {
        let loop = StubTransport { request in
            if request.url?.path == "/api/v1/project-groups" { return (Data(#"{"data": []}"#.utf8), 200) }
            return (Data(#"{"data": [], "next_cursor": "5"}"#.utf8), 200)
        }
        await #expect(throws: HedgerowError.unexpectedResponse) {
            _ = try await client(loop).projects()
        }
    }

    @Test func aBrokenProjectIsSkippedNotFatal() async throws {
        let body = Data(#"{"data": [{"id": 1, "name": "Good"}, {"id": "x"}, 7, {"id": 3, "name": "Also good"}], "next_cursor": null}"#.utf8)
        let transport = router([projectsPath: body, groupsPath: Data(#"{"data": []}"#.utf8)])
        #expect(try await client(transport).projects().map(\.id) == [1, 3])
    }

    @Test func errorsKeepTheirMeaning() async throws {
        await #expect(throws: HedgerowError.unauthorized) {
            _ = try await client(StubTransport(status: 401)).projects()
        }
        await #expect(throws: HedgerowError.unexpectedResponse) {
            _ = try await client(StubTransport(status: 200, body: Data("not json".utf8))).projects()
        }
        #expect(CardProblem(HedgerowError.unauthorized) == .tokenRejected)
        #expect(CardProblem(HedgerowError.unexpectedResponse) == .unexpectedAnswer)
    }
}

@Suite struct KestrelIssueTests {
    private let listPath = "/api/v1/projects/1/issues?status=unresolved&sort=last_seen&limit=100"

    @Test func anIssuePageIsReadAndMalformedItemsAreSkipped() async throws {
        let transport = router([listPath: try fixture("kestrel-issues-list.json")])
        let page = try await client(transport).issuesPage(projectId: 1)

        #expect(transport.requests.map(key) == [listPath])
        #expect(page.nextCursor == "100")
        #expect(page.total == 132)
        // The item with an id that is not a number, and the null, are gone; the rest stay in order.
        #expect(page.issues.map(\.id) == [42, 57, 58])

        let first = page.issues[0]
        #expect(first.title == "ValueError: invalid literal for int() with base 10: 'abc'")
        #expect(first.culprit == "shop.views in checkout")
        #expect(first.level == .error)
        #expect(first.events == 17)
        #expect(first.users == 4)
        #expect(first.lastRelease == "shop@1.4.1")
        #expect(first.firstSeen == parseServerTimestamp("2026-10-22 08:00:00"))
        #expect(first.lastSeen == parseServerTimestamp("2026-10-22 09:15:00"))

        #expect(page.issues[1].level == .fatal)
        #expect(page.issues[1].culprit == nil)
        #expect(page.issues[1].lastRelease == nil)
        // An unknown level is not an error.
        #expect(page.issues[2].level == .unknown)
    }

    @Test func titlesStayPlainText() async throws {
        let transport = router([listPath: try fixture("kestrel-issues-list.json")])
        let page = try await client(transport).issuesPage(projectId: 1)
        #expect(page.issues[1].title == "**bold** [click](https://evil.example/phish) <b>title</b>")
    }

    @Test func theTupleFormGivesIssuesAndTheNextCursor() async throws {
        let transport = router([listPath: try fixture("kestrel-issues-list.json")])
        let (issues, next) = try await client(transport).issues(projectId: 1)
        #expect(issues.count == 3)
        #expect(next == "100")
    }

    @Test func aCursorIsSentEscapedAndCannotAddParameters() async throws {
        let transport = StubTransport { _ in (Data(#"{"data": [], "next_cursor": null, "total": 0}"#.utf8), 200) }
        _ = try await client(transport).issues(projectId: 1, cursor: "1&limit=500#x y")
        let sent = try #require(transport.requests.first?.url)
        let items = URLComponents(url: sent, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.map(\.name) == ["status", "sort", "limit", "cursor"])
        #expect(items.last?.value == "1&limit=500#x y")
    }

    @Test func pageSizeIsKeptInTheServersRange() async throws {
        let transport = StubTransport { _ in (Data(#"{"data": [], "next_cursor": null}"#.utf8), 200) }
        let kestrel = client(transport)
        _ = try await kestrel.issuesPage(projectId: 1, limit: 0)
        _ = try await kestrel.issuesPage(projectId: 1, limit: 9999)
        let limits = transport.requests.map { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "limit" }?.value
        }
        #expect(limits == ["1", "500"])
    }

    @Test func theUnresolvedCountIsReadFromTotalWithOneIssue() async throws {
        let body = Data(#"{"data": [], "next_cursor": "1", "total": 132}"#.utf8)
        let transport = router(["/api/v1/projects/3/issues?status=unresolved&sort=last_seen&limit=1": body])
        #expect(try await client(transport).unresolvedCount(projectId: 3) == 132)
    }

    @Test func aMissingTotalGivesNoCount() async throws {
        let transport = StubTransport { _ in (Data(#"{"data": []}"#.utf8), 200) }
        #expect(try await client(transport).unresolvedCount(projectId: 3) == nil)
    }

    @Test func errorsKeepTheirMeaning() async throws {
        await #expect(throws: HedgerowError.unauthorized) {
            _ = try await client(StubTransport(status: 401)).issuesPage(projectId: 1)
        }
        await #expect(throws: HedgerowError.badResponse(404)) {
            _ = try await client(StubTransport(status: 404)).issuesPage(projectId: 1)
        }
        await #expect(throws: HedgerowError.unexpectedResponse) {
            _ = try await client(StubTransport(status: 200, body: Data(#"{"data": 5}"#.utf8))).issuesPage(projectId: 1)
        }
    }
}

@Suite struct KestrelManyIssuesTests {
    @Test func twoThousandIssuesComeInPagesOfAHundredByCursor() async throws {
        let transport = bigServer(count: 2000)
        let kestrel = client(transport)

        var list = KestrelIssueList()
        var cursor: String?
        repeat {
            try list.append(try await kestrel.issuesPage(projectId: 1, cursor: cursor))
            cursor = list.nextCursor
        } while cursor != nil

        #expect(list.issues.count == 2000)
        #expect(Set(list.issues.map(\.id)).count == 2000)
        #expect(list.issues.first?.id == 1)
        #expect(list.issues.last?.id == 2000)
        #expect(list.total == 2000)
        #expect(list.pages == 20)
        #expect(!list.hasMore)

        let sent = transport.requests.map(key)
        #expect(sent.count == 20)
        #expect(sent[0] == "/api/v1/projects/1/issues?status=unresolved&sort=last_seen&limit=100")
        #expect(sent[1] == "/api/v1/projects/1/issues?status=unresolved&sort=last_seen&limit=100&cursor=100")
        #expect(sent[19] == "/api/v1/projects/1/issues?status=unresolved&sort=last_seen&limit=100&cursor=1900")
    }

    @Test func theFirstScreenIsOneRequestOfAHundredNotTheWholeList() async throws {
        let transport = bigServer(count: 2000)
        let page = try await client(transport).issuesPage(projectId: 1)
        #expect(transport.requests.count == 1)
        #expect(page.issues.count == 100)
        #expect(page.total == 2000)
        #expect(page.nextCursor == "100")
        // A page of the real shape stays far below the response limit.
        let bytes = try await transport.send(
            URLRequest(url: URL(string: "https://kestrel.example.com/api/v1/projects/1/issues?limit=100")!), maxBytes: .max
        ).0
        #expect(bytes.count < HedgerowHTTP.maxResponseBytes / 4)
    }

    @Test func aPageOfExactlyTheLimitEndsWhenThereIsNoCursor() async throws {
        let transport = bigServer(count: 100)
        let page = try await client(transport).issuesPage(projectId: 1)
        #expect(page.issues.count == 100)
        #expect(page.nextCursor == nil)
    }
}

@Suite struct KestrelIssueListTests {
    private func page(_ ids: [Int], next: String?, total: Int? = nil) -> KestrelIssuePage {
        KestrelIssuePage(issues: ids.map { KestrelIssue(id: $0, title: "t\($0)") }, nextCursor: next, total: total)
    }

    @Test func pagesAreAppendedInOrder() throws {
        var list = KestrelIssueList()
        try list.append(page([1, 2], next: "2", total: 3))
        #expect(list.hasMore)
        try list.append(page([3], next: nil))
        #expect(list.issues.map(\.id) == [1, 2, 3])
        #expect(list.total == 3)
        #expect(!list.hasMore)
    }

    @Test func anIssueThatMovedToTheNextPageIsNotShownTwice() throws {
        var list = KestrelIssueList()
        try list.append(page([1, 2], next: "2"))
        try list.append(page([2, 3], next: nil))
        #expect(list.issues.map(\.id) == [1, 2, 3])
    }

    @Test func aCursorThatComesBackClosesTheList() throws {
        var list = KestrelIssueList()
        try list.append(page([1], next: "1"))
        #expect(throws: HedgerowError.unexpectedResponse) {
            try list.append(page([2], next: "1"))
        }
        #expect(!list.hasMore)
        #expect(list.issues.map(\.id) == [1, 2])
    }

    @Test func aListThatNeverEndsIsStopped() throws {
        var list = KestrelIssueList()
        #expect(throws: HedgerowError.unexpectedResponse) {
            for index in 0..<(KestrelIssueList.maxPages + 1) {
                try list.append(page([index], next: "c\(index)"))
            }
        }
        #expect(!list.hasMore)
    }
}

@Suite struct KestrelEventTests {
    private func event(_ file: String, projectId: Int = 1, issueId: Int = 42) async throws -> KestrelEvent {
        let path = "/api/v1/projects/\(projectId)/issues/\(issueId)/events/latest"
        return try await client(router([path: try fixture(file)])).latestEvent(projectId: projectId, issueId: issueId)
    }

    @Test func theLatestEventHasLevelReleaseEnvironmentAndTime() async throws {
        let transport = router([eventPath: try fixture("kestrel-event-latest.json")])
        let latest = try await client(transport).latestEvent(projectId: 1, issueId: 42)

        #expect(transport.requests.map(key) == [eventPath])
        #expect(latest.eventId == "9ec79c33ec9942ab8353589fcb2e04dc")
        #expect(latest.level == .error)
        #expect(latest.release == "shop@1.4.1")
        #expect(latest.environment == "production")
        #expect(latest.platform == "python")
        #expect(latest.timestamp == parseServerTimestamp("2026-10-22 09:15:00"))
        #expect(latest.message == "Checkout failed for [order](https://evil.example)")
    }

    @Test func theStackIsInnermostFirstWithInAppFlagged() async throws {
        let latest = try await event("kestrel-event-latest.json")

        // The raised exception first, the one it was chained from after it.
        #expect(latest.exceptions.map(\.type) == ["ValueError", "KeyError"])
        #expect(latest.title == "ValueError: invalid literal for int() with base 10: 'abc'")

        // The server lists the oldest call first; the app shows the innermost first. The item
        // that is not a frame is skipped.
        let frames = latest.stack
        #expect(frames.map(\.function) == ["abort", "total", "dispatch **now**", "checkout"])
        #expect(frames.map(\.inApp) == [false, true, false, true])

        let checkout = frames[3]
        #expect(checkout.filename == "shop/views.py")
        #expect(checkout.module == "shop.views")
        #expect(checkout.line == 88)
        #expect(checkout.column == 9)
        #expect(checkout.location == "shop/views.py:88:9")

        // No short name: the full path stands in; a line number sent as text still counts.
        #expect(frames[1].location == "/srv/shop/shop/cart.py:21")
        #expect(frames[2].line == 55)
        // Only a package (a native frame): that is the place.
        #expect(frames[0].location == "libsystem_c.dylib")
        #expect(KestrelStackFrame(function: "f").location == nil)

        let cause = latest.exceptions[1]
        #expect(cause.heading == "KeyError: 'cart'")
        #expect(cause.frames.map(\.function) == ["get_response", "application"])
    }

    @Test func tagsAreSortedAndOnlyScalarsSurvive() async throws {
        let latest = try await event("kestrel-event-latest.json")
        #expect(latest.tags == [
            KestrelTag(key: "browser", value: "Firefox 131"),
            KestrelTag(key: "ok", value: "true"),
            KestrelTag(key: "retries", value: "3"),
            KestrelTag(key: "server_name", value: "web-1"),
        ])
    }

    @Test func serverTextStaysPlainText() async throws {
        let latest = try await event("kestrel-event-latest.json")
        #expect(latest.stack[2].function == "dispatch **now**")
        #expect(latest.message == "Checkout failed for [order](https://evil.example)")
    }

    @Test func withoutAnExceptionTheCrashedThreadGivesTheStack() async throws {
        let latest = try await event("kestrel-event-thread.json", issueId: 43)
        #expect(latest.level == .fatal)
        #expect(latest.release == "app@2.0+7")
        // An empty environment is no environment.
        #expect(latest.environment == nil)
        #expect(latest.exceptions.count == 1)
        #expect(latest.exceptions[0].value == "com.apple.root.default-qos")
        #expect(latest.stack.map(\.function) == ["swift_retain", "Sylo.sync()", "start"])
        #expect(latest.stack.map(\.inApp) == [false, true, false])
        #expect(latest.stack[1].location == "Sync.swift:30:5")
        // The server turns tags into an object; a list of pairs is ignored if it ever reaches the app.
        #expect(latest.tags.isEmpty)
    }

    @Test func anEventWithAnUnreadablePayloadIsStillAnEvent() async throws {
        let latest = try await event("kestrel-event-bare.json", issueId: 44)
        #expect(latest.eventId == "aaaabbbbccccddddeeeeffff00001111")
        #expect(latest.level == .warning)
        #expect(latest.release == nil)
        #expect(latest.environment == nil)
        #expect(latest.exceptions.isEmpty)
        #expect(latest.stack.isEmpty)
        #expect(latest.tags.isEmpty)
        #expect(latest.title == nil)
    }

    @Test func anEventWithoutDetailsIsA404NotACrash() async throws {
        await #expect(throws: HedgerowError.badResponse(404)) {
            _ = try await client(StubTransport(status: 404)).latestEvent(projectId: 1, issueId: 42)
        }
    }

    @Test func aRejectedTokenOnTheEventIsTokenRejected() async throws {
        do {
            _ = try await client(StubTransport(status: 403)).latestEvent(projectId: 1, issueId: 42)
            Issue.record("expected an error")
        } catch {
            #expect(CardProblem(error) == .tokenRejected)
        }
    }
}
