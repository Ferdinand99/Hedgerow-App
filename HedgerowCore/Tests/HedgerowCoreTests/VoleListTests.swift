import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HedgerowCore

private let base = URL(string: "https://vole.example.com")!

private func client(_ transport: StubTransport) -> VoleClient {
    VoleClient(baseURL: base, http: HedgerowHTTP(token: "vv_token", transport: transport))
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

private let page1Path = "/api/v1/monitors?limit=250"
private let page2Path = "/api/v1/monitors?limit=250&cursor=9"

private func twoPages() throws -> StubTransport {
    router([
        page1Path: try fixture("vole-monitors-page-1.json"),
        page2Path: try fixture("vole-monitors-page-2.json"),
    ])
}

/// A server with `count` monitors: ten groups (ids 1...10) and the rest spread over them, ids ascending,
/// served 100 at a time like the real list (cursor = id of the last monitor on the page).
private func bigServer(count: Int) -> StubTransport {
    @Sendable func monitorJSON(_ id: Int) -> String {
        if id <= 10 {
            return #"{"id": \#(id), "name": "Group \#(id)", "description": "", "monitor_type": "group", "target": "", "parent_id": null, "active": true, "status": "up", "maintenance": false}"#
        }
        let parent = 1 + id % 10
        let status = id % 7 == 0 ? "down" : "up"
        return #"{"id": \#(id), "name": "Monitor \#(id)", "description": "", "monitor_type": "http", "target": "https://m\#(id).example.com", "parent_id": \#(parent), "interval_seconds": 60, "timeout_seconds": 10, "retries": 1, "active": true, "upside_down": false, "http_method": "GET", "accepted_status_codes": "200-399", "max_redirects": 10, "ignore_tls": false, "expiry_notify": true, "expiry_days": 14, "status": "\#(status)", "maintenance": false, "raw_status": "\#(status)", "raw_status_since": "2026-10-19T14:01:00Z", "raw_message": "200 OK", "tags": [{"id": 2, "name": "production", "color": "green", "value": ""}], "notifications": [{"channel_id": 1, "escalation": false}], "created_at": "2026-10-19 08:00:00", "updated_at": "2026-10-19 08:00:00"}"#
    }
    return StubTransport { request in
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let items = components.queryItems ?? []
        let limit = Int(items.first { $0.name == "limit" }?.value ?? "") ?? 50
        let after = Int(items.first { $0.name == "cursor" }?.value ?? "") ?? 0
        let ids = Array((after + 1)...count).prefix(limit)
        let more = (ids.last ?? count) < count
        let cursor = more ? "\"\(ids.last!)\"" : "null"
        let body = #"{"data": [\#(ids.map(monitorJSON).joined(separator: ","))], "next_cursor": \#(cursor)}"#
        return (Data(body.utf8), 200)
    }
}

@Suite struct VoleMonitorListTests {
    @Test func listsEveryPageWithGroupsResolved() async throws {
        let transport = try twoPages()
        let monitors = try await client(transport).monitors()

        #expect(transport.requests.map(key) == [page1Path, page2Path])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer vv_token" })
        #expect(monitors.map(\.id) == [1, 2, 7, 8, 9, 10, 11, 12, 13])

        let website = try #require(monitors.first { $0.id == 7 })
        #expect(website.name == "Website")
        #expect(website.kind == "http")
        #expect(website.status == .up)
        #expect(website.group == "Production")
        #expect(website.parentId == 1)
        #expect(website.responseMs == nil)
        #expect(!website.paused && !website.inMaintenance)

        let database = try #require(monitors.first { $0.id == 9 })
        #expect(database.paused)
        #expect(database.displayStatus == .paused)
        #expect(database.group == "Staging")

        let mail = try #require(monitors.first { $0.id == 11 })
        #expect(mail.inMaintenance)
        #expect(mail.displayStatus == .maintenance)

        #expect(monitors.first { $0.id == 10 }?.status == .pending)
        #expect(monitors.first { $0.id == 10 }?.group == nil)
        #expect(monitors.first { $0.id == 1 }?.isGroup == true)
    }

    @MainActor private final class Progress {
        var counts: [Int] = []
    }

    @Test @MainActor func progressShowsEachPageBeforeTheLast() async throws {
        let progress = Progress()
        let all = try await client(try twoPages()).monitors { progress.counts.append($0.count) }
        // After page 1 of 2 (the last page is the returned list).
        #expect(progress.counts == [5])
        #expect(all.count == 9)
    }

    @Test func aMissingStatusIsUnknownNotAnError() async throws {
        let monitors = try await client(try twoPages()).monitors()
        let fresh = try #require(monitors.first { $0.id == 13 })
        #expect(fresh.status == .unknown)
        #expect(fresh.kind == "http")
    }

    @Test func serverTextStaysPlainText() async throws {
        let monitors = try await client(try twoPages()).monitors()
        let odd = try #require(monitors.first { $0.id == 12 })
        #expect(odd.name == "**bold** [click](https://evil.example/phish) <b>name</b>")
    }

    @Test func oneBrokenMonitorDoesNotFailTheList() async throws {
        let body = #"""
        {"data": [
            {"id": 1, "name": "Good", "monitor_type": "http", "status": "up"},
            {"id": "x", "name": "Wrong id type"},
            {"id": 3},
            "not even an object",
            {"id": 4, "name": "Also good", "monitor_type": "tcp", "status": "down"}
        ], "next_cursor": null}
        """#
        let transport = router([page1Path: Data(body.utf8)])
        let monitors = try await client(transport).monitors()
        #expect(monitors.map(\.id) == [1, 4])
        #expect(monitors.map(\.name) == ["Good", "Also good"])
        #expect(monitors[1].status == .down)
    }

    @Test func aListThatIsNotAListIsStillUnexpected() async throws {
        let transport = router([page1Path: Data(#"{"data": "nope", "next_cursor": null}"#.utf8)])
        await #expect(throws: HedgerowError.unexpectedResponse) {
            _ = try await client(transport).monitors()
        }
    }

    @Test func aSinglePageCanBeFetchedWithACursor() async throws {
        let transport = try twoPages()
        let page = try await client(transport).monitorsPage(cursor: "9")
        #expect(page.nextCursor == nil)
        #expect(page.monitors.count == 4)
        #expect(transport.requests.map(key) == [page2Path])
    }

    @Test func aCursorCannotAddQueryParameters() async throws {
        let transport = StubTransport { _ in (Data(#"{"data": [], "next_cursor": null}"#.utf8), 200) }
        _ = try await client(transport).monitorsPage(cursor: "1&limit=500#x y")
        let sent = try #require(transport.requests.first?.url)
        let items = URLComponents(url: sent, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.map(\.name) == ["limit", "cursor"])
        #expect(items.last?.value == "1&limit=500#x y")
    }

    @Test func pageSizeIsKeptInTheServersRange() async throws {
        let transport = StubTransport { _ in (Data(#"{"data": [], "next_cursor": null}"#.utf8), 200) }
        let vole = client(transport)
        _ = try await vole.monitorsPage(limit: 0)
        _ = try await vole.monitorsPage(limit: 9999)
        #expect(transport.requests.map(key) == ["/api/v1/monitors?limit=1", "/api/v1/monitors?limit=500"])
    }

    @Test func aListThatLoopsItsCursorIsRefused() async throws {
        let loop = StubTransport { _ in (Data(#"{"data": [], "next_cursor": "5"}"#.utf8), 200) }
        await #expect(throws: HedgerowError.unexpectedResponse) {
            _ = try await client(loop).monitors()
        }
    }

    @Test func errorsKeepTheirMeaning() async throws {
        await #expect(throws: HedgerowError.unauthorized) {
            _ = try await client(StubTransport(status: 401)).monitors()
        }
        await #expect(throws: HedgerowError.unexpectedResponse) {
            _ = try await client(StubTransport(status: 200, body: Data("not json".utf8))).monitors()
        }
        // The same words as on the Overview card.
        #expect(CardProblem(HedgerowError.unauthorized) == .tokenRejected)
        #expect(CardProblem(HedgerowError.unexpectedResponse) == .unexpectedAnswer)
    }
}

@Suite struct VoleManyMonitorsTests {
    @Test func fiveHundredMonitorsComeInPagesOf250() async throws {
        let transport = bigServer(count: 500)
        let monitors = try await client(transport).monitors()

        #expect(monitors.count == 500)
        #expect(Set(monitors.map(\.id)).count == 500)
        #expect(transport.requests.count == 2)
        #expect(transport.requests.map(key) == [
            "/api/v1/monitors?limit=250",
            "/api/v1/monitors?limit=250&cursor=250",
        ])
        // A page of the real shape stays far below the response limit.
        let page = try await transport.send(
            URLRequest(url: URL(string: "https://vole.example.com/api/v1/monitors?limit=250")!), maxBytes: .max
        ).0
        #expect(page.count < HedgerowHTTP.maxResponseBytes / 4)
    }

    @Test func fiveHundredMonitorsMakeTenSectionsWithDownFirst() async throws {
        let monitors = try await client(bigServer(count: 500)).monitors()
        let sections = voleSections(monitors)

        #expect(sections.count == 10)
        #expect(sections.reduce(0) { $0 + $1.monitors.count } == 490)
        // Every group has at least one monitor that is down, so rows inside start with a down one.
        for section in sections {
            #expect(section.monitors.first?.displayStatus == .down)
        }
    }

    @Test func aPageOfExactlyTheLimitStopsWhenThereIsNoCursor() async throws {
        let transport = bigServer(count: 100)
        let monitors = try await client(transport).monitors()
        #expect(monitors.count == 100)
        #expect(transport.requests.count == 1)
    }
}

@Suite struct VoleUptimeDisplayTests {
    @Test func neverRoundsUpToAHundred() {
        #expect(VoleMonitorDetail.displayedUptime(99.996) == 99.99)
        #expect(VoleMonitorDetail.displayedUptime(99.999) == 99.99)
        #expect(VoleMonitorDetail.displayedUptime(99.9999) == 99.99)
        #expect(VoleMonitorDetail.displayedUptime(0.004) == 0)
    }

    @Test func exactValuesStayAsTheyAre() {
        #expect(VoleMonitorDetail.displayedUptime(100) == 100)
        #expect(VoleMonitorDetail.displayedUptime(99.98) == 99.98)
        #expect(VoleMonitorDetail.displayedUptime(99.99) == 99.99)
        #expect(VoleMonitorDetail.displayedUptime(99.5) == 99.5)
        #expect(VoleMonitorDetail.displayedUptime(0) == 0)
        #expect(VoleMonitorDetail.displayedUptime(12.34) == 12.34)
    }

    @Test func outOfRangeAndNonNumbersAreHandled() {
        #expect(VoleMonitorDetail.displayedUptime(100.5) == 100)
        #expect(VoleMonitorDetail.displayedUptime(-3) == 0)
        #expect(VoleMonitorDetail.displayedUptime(.nan) == nil)
        #expect(VoleMonitorDetail.displayedUptime(.infinity) == nil)
    }
}

@Suite struct VoleSectionTests {
    private func all() async throws -> [VoleMonitor] {
        try await client(try twoPages()).monitors()
    }

    @Test func sectionsFollowGroupsWithTheWorstFirst() async throws {
        let sections = voleSections(try await all())

        // Production has a down monitor, Staging only a paused one, the rest has a pending one.
        #expect(sections.map(\.title) == ["Production", nil, "Staging"])
        #expect(sections[0].status == .down)
        #expect(sections[0].monitors.map(\.id) == [8, 11, 7])
        #expect(sections[1].monitors.map(\.id) == [10, 13, 12])
        #expect(sections[2].monitors.map(\.id) == [9])
    }

    @Test func downComesBeforePendingUnknownMaintenanceUpAndPaused() {
        let kinds: [(VoleStatus, Bool, Bool)] = [
            (.up, false, false), (.down, false, false), (.pending, false, false),
            (.up, true, false), (.up, false, true), (.unknown, false, false),
        ]
        let monitors = kinds.enumerated().map { index, kind in
            VoleMonitor(id: index + 1, name: "m\(index + 1)", kind: "http", status: kind.0, paused: kind.1, inMaintenance: kind.2)
        }
        let order = voleSections(monitors)[0].monitors.map(\.displayStatus)
        #expect(order == [.down, .pending, .unknown, .maintenance, .up, .paused])
    }

    @Test func searchFindsMonitorsByNameAndKeepsOnlyTheirSections() async throws {
        let sections = voleSections(try await all(), matching: "  WEB ")
        #expect(sections.count == 1)
        #expect(sections[0].title == "Production")
        #expect(sections[0].monitors.map(\.name) == ["Website"])
    }

    @Test func searchingForAGroupNameShowsItsWholeGroup() async throws {
        let sections = voleSections(try await all(), matching: "staging")
        #expect(sections.map(\.title) == ["Staging"])
        #expect(sections[0].monitors.map(\.id) == [9])
    }

    @Test func searchWithNoMatchGivesNothing() async throws {
        #expect(voleSections(try await all(), matching: "zzz").isEmpty)
    }

    @Test func searchTreatsTheQueryAsPlainText() async throws {
        #expect(voleSections(try await all(), matching: "[click](").map(\.monitors.count) == [1])
        #expect(voleSections(try await all(), matching: ".*").isEmpty)
    }

    @Test func aChildWhoseGroupHasNotArrivedYetIsUngrouped() {
        let orphan = VoleMonitor(id: 50, name: "Orphan", kind: "http", status: .up, parentId: 3)
        let sections = voleSections([orphan])
        #expect(sections.map(\.title) == [nil])
        #expect(sections[0].monitors.map(\.id) == [50])
    }

    @Test func nestedGroupsGetTheirFullPath() {
        let monitors = [
            VoleMonitor(id: 1, name: "Outer", kind: "group", status: .up),
            VoleMonitor(id: 2, name: "Inner", kind: "group", status: .up, parentId: 1),
            VoleMonitor(id: 3, name: "Leaf", kind: "http", status: .up, parentId: 2),
        ]
        let sections = voleSections(monitors)
        #expect(sections.map(\.title) == ["Outer / Inner"])
        #expect(VoleMonitor.resolvingGroups(monitors)[2].group == "Outer / Inner")
    }

    @Test func aLoopOfGroupsDoesNotHang() {
        let monitors = [
            VoleMonitor(id: 1, name: "A", kind: "group", status: .up, parentId: 2),
            VoleMonitor(id: 2, name: "B", kind: "group", status: .up, parentId: 1),
            VoleMonitor(id: 3, name: "Leaf", kind: "http", status: .up, parentId: 1),
        ]
        #expect(voleSections(monitors).count == 1)
    }

    @Test func aDownGroupWithNoMonitorsIsStillShown() {
        let sections = voleSections([VoleMonitor(id: 1, name: "Lonely", kind: "group", status: .down)])
        #expect(sections.map(\.title) == ["Lonely"])
        #expect(voleSections([VoleMonitor(id: 1, name: "Calm", kind: "group", status: .up)]).isEmpty)
    }
}

@Suite struct VoleDetailTests {
    private func detailServer() throws -> StubTransport {
        router([
            "/api/v1/monitors/7": try fixture("vole-monitor-detail.json"),
            "/api/v1/monitors/7/heartbeats?limit=1": try fixture("vole-heartbeats.json"),
            "/api/v1/monitors/7/uptime?days=30": try fixture("vole-uptime.json"),
            "/api/v1/monitors/7/events?limit=20": try fixture("vole-events.json"),
        ])
    }

    @Test func detailCombinesTheFourCalls() async throws {
        let transport = try detailServer()
        let detail = try await client(transport).monitor(id: 7)

        #expect(Set(transport.requests.map(key)) == [
            "/api/v1/monitors/7", "/api/v1/monitors/7/heartbeats?limit=1",
            "/api/v1/monitors/7/uptime?days=30", "/api/v1/monitors/7/events?limit=20",
        ])
        #expect(detail.monitor.id == 7)
        #expect(detail.monitor.status == .up)
        #expect(detail.monitor.responseMs == 84)
        #expect(detail.target == "https://example.com")
        #expect(detail.description == "The **public** site")
        #expect(detail.rawMessage == "200 OK")

        let beat = try #require(detail.lastHeartbeat)
        #expect(beat.status == .up)
        #expect(beat.responseMs == 84)
        #expect(beat.message == "200 OK")
        #expect(beat.checkedAt == parseServerTimestamp("2026-10-19 14:03:00"))

        #expect(detail.uptime24h == 100.0)
        #expect(detail.uptime30d == 99.98)
    }

    @Test func eventsKeepTheirOrderKindsAndPlainText() async throws {
        let detail = try await client(try detailServer()).monitor(id: 7)

        #expect(detail.events.map(\.id) == [14, 13, 12, 11])
        #expect(detail.events.map(\.kind) == [.down, .maintenance, .down, .other])
        #expect(detail.events[0].isOngoing)
        #expect(detail.events[0].message == "connection refused <script>alert(1)</script>")
        #expect(detail.events[1].message == nil)
        #expect(detail.events[2].durationSeconds == 240)
        #expect(detail.events[2].startedAt == parseServerTimestamp("2026-10-18 03:10:00"))
        #expect(detail.events[2].endedAt == parseServerTimestamp("2026-10-18 03:14:00"))
    }

    @Test func atMostTwentyEventsAreShownEvenIfTheServerSendsMore() async throws {
        let many = (1...30).map {
            #"{"id": \#($0), "monitor_id": 7, "kind": "up", "message": null, "started_at": "2026-10-18 03:10:00", "ended_at": "2026-10-18 03:10:00", "duration_seconds": 0}"#
        }.joined(separator: ",")
        let transport = router([
            "/api/v1/monitors/7": try fixture("vole-monitor-detail.json"),
            "/api/v1/monitors/7/heartbeats?limit=1": Data(#"{"data": [], "next_cursor": null}"#.utf8),
            "/api/v1/monitors/7/uptime?days=30": try fixture("vole-uptime.json"),
            "/api/v1/monitors/7/events?limit=20": Data(#"{"data": [\#(many)], "next_cursor": null}"#.utf8),
        ])
        let detail = try await client(transport).monitor(id: 7)
        #expect(detail.events.count == VoleMonitorDetail.maxEvents)
        // No check yet: no heartbeat and no response time, but still a detail.
        #expect(detail.lastHeartbeat == nil)
        #expect(detail.monitor.responseMs == nil)
    }

    @Test func aMonitorThatIsGoneIsAnErrorNotACrash() async throws {
        await #expect(throws: HedgerowError.badResponse(404)) {
            _ = try await client(StubTransport(status: 404)).monitor(id: 7)
        }
    }

    @Test func aRejectedTokenOnTheDetailIsTokenRejected() async throws {
        do {
            _ = try await client(StubTransport(status: 403)).monitor(id: 7)
            Issue.record("expected an error")
        } catch {
            #expect(CardProblem(error) == .tokenRejected)
        }
    }
}
