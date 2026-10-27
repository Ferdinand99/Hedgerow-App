import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HedgerowCore

/// "Now" for every test: the fixtures' timestamps are set relative to it.
private let now = parseServerTimestamp("2026-10-23 12:00:00")!

private func key(_ request: URLRequest) -> String {
    let url = request.url!
    return url.query.map { url.path + "?" + $0 } ?? url.path
}

/// Answers by path and query; anything else is a 404.
private func router(_ table: [String: Data], status: Int = 200) -> StubTransport {
    StubTransport { request in
        if let body = table[key(request)] { return (body, status) }
        return (Data(), 404)
    }
}

private func json(_ text: String) -> Data { Data(text.utf8) }

private let voleBase = URL(string: "https://vole.example.com")!
private let kestrelBase = URL(string: "https://kestrel.example.com")!
private let wrenBase = URL(string: "https://wren.example.com")!

private func vole(_ transport: StubTransport) -> VoleClient {
    VoleClient(baseURL: voleBase, http: HedgerowHTTP(token: "vv_token", transport: transport), now: { now })
}

private func kestrel(_ transport: any HTTPTransport) -> KestrelClient {
    KestrelClient(baseURL: kestrelBase, http: HedgerowHTTP(token: "kk_token", transport: transport), now: { now })
}

private func wren(_ transport: StubTransport) -> WrenClient {
    WrenClient(baseURL: wrenBase, http: HedgerowHTTP(token: "ww_token", transport: transport), now: { now })
}

@Suite struct VoleSummaryTests {
    @Test func twoOfFortyDownIsCritical() async throws {
        let transport = router([
            VoleClient.healthPath: try fixture("vole-health-2-down.json"),
            VoleClient.downPath: try fixture("vole-monitors-down.json"),
        ])
        let summary = try await vole(transport).summary()
        #expect(summary.kind == .vole)
        #expect(summary.health == .critical)
        #expect(summary.headline.text == "2 down")
        #expect(summary.headline.key == "%lld down")
        #expect(summary.headline.arguments == [.number(2)])
        #expect(summary.details.map(\.text) == ["Website is down", "API is down", "2 paused"])
        #expect(summary.fetchedAt == now)
        // The token goes along, and the health call comes first.
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer vv_token")
        #expect(transport.requests.map(key) == ["/api/v1/health", "/api/v1/monitors?status=down&limit=500"])
    }

    @Test func allUpIsOkAndNeverFetchesTheMonitorList() async throws {
        let transport = router([VoleClient.healthPath: try fixture("vole-health-all-up.json")])
        let summary = try await vole(transport).summary()
        #expect(summary.health == .ok)
        #expect(summary.headline.text == "13 up")
        #expect(summary.details.map(\.text) == ["1 paused"])
        #expect(transport.requests.count == 1)
    }

    @Test func downMonitorsInMaintenanceDoNotCount() async throws {
        let health = json(#"{"monitors": {"total": 3, "by_status": {"up": 2, "down": 1}}}"#)
        let list = json(#"{"data": [{"name": "Site", "status": "down", "maintenance": true}], "next_cursor": null}"#)
        let summary = try await vole(router([VoleClient.healthPath: health, VoleClient.downPath: list])).summary()
        #expect(summary.health == .ok)
        #expect(summary.headline.text == "2 up")
    }

    @Test func noMonitorsIsUnknown() async throws {
        let health = json(#"{"monitors": {"total": 0, "by_status": {}}}"#)
        let summary = try await vole(router([VoleClient.healthPath: health])).summary()
        #expect(summary.health == .unknown)
        #expect(summary.headline.text == "No monitors")
    }

    @Test func largeInventoryIsSummarised() async throws {
        let names = (1...120).map { #"{"name": "Monitor \#($0)", "status": "down", "maintenance": false}"# }
        let list = json(#"{"data": [\#(names.joined(separator: ","))], "next_cursor": null}"#)
        let health = json(#"{"monitors": {"total": 500, "by_status": {"up": 370, "down": 120, "paused": 8, "pending": 2}}}"#)
        let summary = try await vole(router([VoleClient.healthPath: health, VoleClient.downPath: list])).summary()
        #expect(summary.health == .critical)
        #expect(summary.headline.text == "120 down")
        #expect(summary.details.count <= ServiceSummary.maxDetails)
        #expect(summary.details.first?.text == "Monitor 1 is down")
        #expect(summary.details.map(\.text).contains("117 more down"))
    }

    @Test func aCutOffListKeepsTheHealthCount() async throws {
        let health = json(#"{"monitors": {"total": 900, "by_status": {"up": 100, "down": 800}}}"#)
        let list = json(#"{"data": [{"name": "A", "status": "down", "maintenance": false}], "next_cursor": "500"}"#)
        let summary = try await vole(router([VoleClient.healthPath: health, VoleClient.downPath: list])).summary()
        #expect(summary.headline.text == "800 down")
    }

    @Test func htmlWithStatus200IsAnUnexpectedResponse() async throws {
        let transport = router([VoleClient.healthPath: try fixture("pangolin-login.html")])
        await #expect(throws: HedgerowError.unexpectedResponse) { try await vole(transport).summary() }
    }

    @Test func wrongShapeIsAnUnexpectedResponse() async throws {
        let transport = router([VoleClient.healthPath: json(#"{"monitors": "many"}"#)])
        await #expect(throws: HedgerowError.unexpectedResponse) { try await vole(transport).summary() }
    }

    @Test func expiredTokenIsUnauthorized() async throws {
        let transport = StubTransport(status: 401)
        await #expect(throws: HedgerowError.unauthorized) { try await vole(transport).summary() }
    }
}

@Suite struct KestrelSummaryTests {
    private func projects(_ count: Int, more: Bool = false) -> Data {
        let items = (1...count).map { #"{"id": \#($0), "name": "Project \#($0)", "slug": "p\#($0)"}"# }
        return json(#"{"data": [\#(items.joined(separator: ","))], "next_cursor": \#(more ? "\"20\"" : "null")}"#)
    }

    @Test func newIssuesInTheLastDayIsAWarning() async throws {
        let transport = router([
            KestrelClient.projectsPath: try fixture("kestrel-projects.json"),
            KestrelClient.issuesPath(1): try fixture("kestrel-issues-new.json"),
            KestrelClient.issuesPath(2): try fixture("kestrel-issues-old.json"),
        ])
        let summary = try await kestrel(transport).summary()
        #expect(summary.kind == .kestrel)
        #expect(summary.health == .warning)
        // 2 of project 1's newest issues are younger than 24 hours; project 2 has none.
        #expect(summary.headline.text == "2 new in 24 h")
        #expect(summary.details.map(\.text) == [
            "Sylo for iOS: 132 unresolved, 2 new",
            "Shop: 2 unresolved, 0 new",
        ])
        #expect(Set(transport.requests.map(key)) == [
            "/api/v1/projects?limit=20",
            "/api/v1/projects/1/issues?status=unresolved&sort=first_seen&limit=20",
            "/api/v1/projects/2/issues?status=unresolved&sort=first_seen&limit=20",
        ])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer kk_token" })
    }

    @Test func onlyOldIssuesIsOk() async throws {
        let transport = router([
            KestrelClient.projectsPath: try fixture("kestrel-projects.json"),
            KestrelClient.issuesPath(1): try fixture("kestrel-issues-old.json"),
            KestrelClient.issuesPath(2): try fixture("kestrel-issues-old.json"),
        ])
        let summary = try await kestrel(transport).summary()
        #expect(summary.health == .ok)
        #expect(summary.headline.text == "4 unresolved")
    }

    @Test func noIssuesIsOk() async throws {
        let empty = json(#"{"data": [], "next_cursor": null, "total": 0, "unknown_terms": []}"#)
        let transport = router([
            KestrelClient.projectsPath: try fixture("kestrel-projects.json"),
            KestrelClient.issuesPath(1): empty,
            KestrelClient.issuesPath(2): empty,
        ])
        let summary = try await kestrel(transport).summary()
        #expect(summary.health == .ok)
        #expect(summary.headline.text == "No open issues")
        #expect(summary.details.isEmpty)
    }

    @Test func noProjectsIsUnknown() async throws {
        let transport = router([KestrelClient.projectsPath: json(#"{"data": [], "next_cursor": null}"#)])
        let summary = try await kestrel(transport).summary()
        #expect(summary.health == .unknown)
        #expect(summary.headline.text == "No projects")
    }

    @Test func largeInventoryIsSummarised() async throws {
        // 25 projects exist, the server cuts the page at the 20 asked for.
        var table = [KestrelClient.projectsPath: projects(20, more: true)]
        for id in 1...20 { table[KestrelClient.issuesPath(id)] = try fixture("kestrel-issues-old.json") }
        let transport = router(table)
        let summary = try await kestrel(transport).summary()
        #expect(summary.details.count == ServiceSummary.maxDetails)
        #expect(summary.details.last?.text == "Only the first 20 projects are counted")
        #expect(summary.headline.text == "40 unresolved")
        // One projects call plus one per project, never more than 20 projects.
        #expect(transport.requests.count == 21)
    }

    @Test func neverMoreThanTwentyProjectsEvenIfTheServerSendsMore() async throws {
        var table = [KestrelClient.projectsPath: projects(30)]
        for id in 1...30 { table[KestrelClient.issuesPath(id)] = try fixture("kestrel-issues-old.json") }
        let transport = router(table)
        _ = try await kestrel(transport).summary()
        #expect(transport.requests.count == 21)
    }

    @Test func projectsAreAskedFourAtATime() async throws {
        let transport = SlowTransport(projects: projects(20), issues: try fixture("kestrel-issues-old.json"))
        let summary = try await kestrel(transport).summary()
        #expect(summary.headline.text == "40 unresolved")
        #expect(transport.maxInFlight > 1)
        #expect(transport.maxInFlight <= 4)
    }

    @Test func oneProjectFailingFailsTheSummary() async throws {
        let transport = router([
            KestrelClient.projectsPath: try fixture("kestrel-projects.json"),
            KestrelClient.issuesPath(1): try fixture("kestrel-issues-old.json"),
        ])
        await #expect(throws: HedgerowError.badResponse(404)) { try await kestrel(transport).summary() }
    }

    @Test func wrongShapeIsAnUnexpectedResponse() async throws {
        let transport = router([KestrelClient.projectsPath: try fixture("pangolin-login.html")])
        await #expect(throws: HedgerowError.unexpectedResponse) { try await kestrel(transport).summary() }
    }

    @Test func forbiddenTokenIsReported() async throws {
        let transport = StubTransport(status: 403)
        await #expect(throws: HedgerowError.forbidden) { try await kestrel(transport).summary() }
    }
}

/// Answers every issues call after a short wait and records how many run at once.
private final class SlowTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var peak = 0
    private let projects: Data
    private let issues: Data

    init(projects: Data, issues: Data) {
        self.projects = projects
        self.issues = issues
    }

    var maxInFlight: Int { lock.withLock { peak } }

    func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let isIssues = request.url!.path.hasSuffix("/issues")
        if isIssues {
            lock.withLock {
                inFlight += 1
                peak = max(peak, inFlight)
            }
        }
        defer { if isIssues { lock.withLock { inFlight -= 1 } } }
        if isIssues { try await Task.sleep(nanoseconds: 30_000_000) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (isIssues ? issues : projects, response)
    }
}

@Suite struct WrenSummaryTests {
    @Test func pendingUpdatesAreAWarningAndRunningIsCounted() async throws {
        let runs = json(#"{"runs": [{"status": "running", "created_at": "2026-10-23 11:50:00", "target": {"name": "grafana"}}]}"#)
        let transport = router([
            WrenClient.updatesPath: try fixture("wren-updates.json"),
            WrenClient.runsPath: runs,
        ])
        let summary = try await wren(transport).summary()
        #expect(summary.kind == .wren)
        #expect(summary.health == .warning)
        #expect(summary.headline.text == "1 updates pending")
        #expect(summary.details.map(\.text) == ["1 running", "postiz on LANBox has an update"])
        #expect(transport.requests.map(key) == ["/api/v1/updates", "/api/v1/runs?limit=50"])
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer ww_token")
    }

    @Test func aRunThatFailedInTheLastDayIsCritical() async throws {
        let transport = router([
            WrenClient.updatesPath: try fixture("wren-updates-none.json"),
            WrenClient.runsPath: try fixture("wren-runs.json"),
        ])
        let summary = try await wren(transport).summary()
        #expect(summary.health == .critical)
        #expect(summary.headline.text == "1 failed in 24 h")
        #expect(summary.details.map(\.text) == ["redis failed", "1 running"])
    }

    @Test func aFailureOlderThanADayDoesNotCount() async throws {
        let transport = router([
            WrenClient.updatesPath: try fixture("wren-updates-none.json"),
            WrenClient.runsPath: try fixture("wren-runs-old-failure.json"),
        ])
        let summary = try await wren(transport).summary()
        #expect(summary.health == .ok)
        #expect(summary.headline.text == "Everything up to date")
        #expect(summary.details.isEmpty)
    }

    @Test func largeInventoryIsSummarised() async throws {
        let targets = (1...88).map {
            #"{"id": \#($0), "server": {"id": 1, "name": "Tower"}, "kind": "container", "name": "app-\#($0)", "status": "update"}"#
        }
        let failedRuns = (1...6).map {
            #"{"status": "failed", "created_at": "2026-10-23 10:0\#($0):00", "target": {"name": "job-\#($0)"}}"#
        }
        let transport = router([
            WrenClient.updatesPath: json(#"{"targets": [\#(targets.joined(separator: ","))]}"#),
            WrenClient.runsPath: json(#"{"runs": [\#(failedRuns.joined(separator: ","))]}"#),
        ])
        let summary = try await wren(transport).summary()
        #expect(summary.health == .critical)
        #expect(summary.headline.text == "6 failed in 24 h")
        #expect(summary.details.count <= ServiceSummary.maxDetails)

        let calm = router([
            WrenClient.updatesPath: json(#"{"targets": [\#(targets.joined(separator: ","))]}"#),
            WrenClient.runsPath: json(#"{"runs": []}"#),
        ])
        let pending = try await wren(calm).summary()
        #expect(pending.headline.text == "88 updates pending")
        #expect(pending.details.count == 4)
        #expect(pending.details.last?.text == "85 more with updates")
    }

    @Test func wrongShapeIsAnUnexpectedResponse() async throws {
        let transport = router([WrenClient.updatesPath: json(#"{"targets": 5}"#)])
        await #expect(throws: HedgerowError.unexpectedResponse) { try await wren(transport).summary() }
    }

    @Test func expiredTokenIsUnauthorized() async throws {
        await #expect(throws: HedgerowError.unauthorized) { try await wren(StubTransport(status: 401)).summary() }
    }
}

@Suite struct SummaryLineTests {
    @Test func rendersPlaceholdersInOrderAndByPosition() {
        #expect(SummaryLine("%lld of %lld up", .number(2), .number(40)).text == "2 of 40 up")
        #expect(SummaryLine("%@ is down", .text("Website")).text == "Website is down")
        #expect(SummaryLine("%2$@ has %1$lld issues", .number(3), .text("Shop")).text == "Shop has 3 issues")
        #expect(SummaryLine("100%% sure").text == "100% sure")
        #expect(SummaryLine("Everything up to date").text == "Everything up to date")
    }

    @Test func formatArgumentsFeedStringFormat() {
        let line = SummaryLine("%1$@: %2$lld", .text("Shop"), .number(4))
        #expect(String(format: line.key, arguments: line.formatArguments) == "Shop: 4")
    }

    @Test func timestampsAreReadAsUTC() {
        #expect(parseServerTimestamp("1970-01-02 00:00:00") == Date(timeIntervalSince1970: 86_400))
        #expect(parseServerTimestamp("2026-10-19T14:01:00Z") == parseServerTimestamp("2026-10-19 14:01:00"))
        #expect(parseServerTimestamp("not a date") == nil)
        #expect(parseServerTimestamp(nil) == nil)
    }

    @Test func clientsFollowTheConnectionKind() {
        let url = URL(string: "https://x.example.com")!
        #expect(makeClient(for: Connection(name: "a", baseURL: url, kind: .vole), token: "t") is VoleClient)
        #expect(makeClient(for: Connection(name: "a", baseURL: url, kind: .kestrel), token: "t") is KestrelClient)
        #expect(makeClient(for: Connection(name: "a", baseURL: url, kind: .wren), token: "t") is WrenClient)
    }
}

@Suite struct JustNowTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func recentOrFutureIsJustNow() {
        #expect(isJustNow(base, now: base))
        #expect(isJustNow(base, now: base.addingTimeInterval(9)))
        // Clock skew: the fetch time is ahead of the phone's clock.
        #expect(isJustNow(base.addingTimeInterval(3), now: base))
    }

    @Test func tenSecondsOrMoreIsNotJustNow() {
        #expect(!isJustNow(base, now: base.addingTimeInterval(10)))
        #expect(!isJustNow(base, now: base.addingTimeInterval(120)))
    }
}
