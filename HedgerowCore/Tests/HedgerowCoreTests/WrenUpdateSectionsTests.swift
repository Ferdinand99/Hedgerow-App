import Foundation
import Testing
@testable import HedgerowCore

@Suite struct WrenUpdateSectionsTests {
    private func target(_ id: Int, server: Int?, name: String = "t") -> WrenTarget {
        WrenTarget(id: id, serverId: server, serverName: "S", name: "\(name)\(id)")
    }

    private let night = WrenAutoWindow(start: "02:00", end: "04:00")

    private var servers: [WrenServer] {
        [
            WrenServer(id: 1, name: "Approve", status: .online, mode: .approve),
            WrenServer(id: 2, name: "Auto", status: .online, mode: .auto, autoWindow: night),
            WrenServer(id: 3, name: "Notify", status: .online, mode: .notify),
            WrenServer(id: 4, name: "Odd", status: .online, mode: .unknown),
        ]
    }

    @Test func eachModeLandsInItsSectionInOrder() {
        // Given in server order 3, 2, 1: the sections still come in the fixed order.
        let targets = [target(10, server: 3), target(11, server: 2), target(12, server: 1), target(13, server: 2)]

        let sections = wrenUpdateSections(targets, servers: servers)

        #expect(sections.map(\.group) == [.waitingForApproval, .updatesAutomatically, .available])
        #expect(sections[0].targets.map(\.id) == [12])
        #expect(sections[1].targets.map(\.id) == [11, 13])
        #expect(sections[2].targets.map(\.id) == [10])
        // Only the automatic section has a window.
        #expect(sections[0].autoWindows.isEmpty)
        #expect(sections[1].autoWindows == [night])
        #expect(sections[2].autoWindows.isEmpty)
    }

    @Test func anUnknownServerOrModeOrNoServerIdIsAvailable() {
        let targets = [
            target(1, server: 99),   // a server /servers did not list
            target(2, server: nil),  // a target without a server
            target(3, server: 4),    // a server whose mode is not known
            target(4, server: 3),    // notify
        ]

        let sections = wrenUpdateSections(targets, servers: servers)

        #expect(sections.map(\.group) == [.available])
        #expect(sections[0].targets.map(\.id) == [1, 2, 3, 4])
    }

    @Test func anEmptyServerListPutsEverythingUnderAvailable() {
        // /servers failed and fell back to an empty list.
        let targets = [target(1, server: 1), target(2, server: 2), target(3, server: 3)]

        let sections = wrenUpdateSections(targets, servers: [])

        #expect(sections.map(\.group) == [.available])
        #expect(sections[0].targets.map(\.id) == [1, 2, 3])
        #expect(sections[0].autoWindows.isEmpty)
    }

    @Test func sectionsWithoutRowsAreLeftOut() {
        #expect(wrenUpdateSections([], servers: servers).isEmpty)
        let onlyAuto = wrenUpdateSections([target(1, server: 2)], servers: servers)
        #expect(onlyAuto.map(\.group) == [.updatesAutomatically])
    }

    @Test func aWindowIsKnownOnlyWhenTheServerHasOne() {
        let noWindow = [WrenServer(id: 5, name: "No window", status: .online, mode: .auto)]
        let sections = wrenUpdateSections([target(1, server: 5)], servers: noWindow)
        #expect(sections.map(\.group) == [.updatesAutomatically])
        #expect(sections[0].autoWindows.isEmpty)
    }

    @Test func differentWindowsAreAllKeptAndEqualOnesOnce() {
        let day = WrenAutoWindow(start: "12:00", end: "13:00")
        let two = [
            WrenServer(id: 1, name: "A", status: .online, mode: .auto, autoWindow: night),
            WrenServer(id: 2, name: "B", status: .online, mode: .auto, autoWindow: day),
            WrenServer(id: 3, name: "C", status: .online, mode: .auto, autoWindow: night),
        ]
        let targets = [target(1, server: 1), target(2, server: 2), target(3, server: 3), target(4, server: 1)]

        let sections = wrenUpdateSections(targets, servers: two)

        #expect(sections[0].autoWindows == [night, day])
    }

    @Test func aRepeatedServerIdDoesNotCrashAndTheFirstOneWins() {
        let twice = [
            WrenServer(id: 1, name: "First", status: .online, mode: .approve),
            WrenServer(id: 1, name: "Second", status: .online, mode: .auto),
        ]
        let sections = wrenUpdateSections([target(1, server: 1)], servers: twice)
        #expect(sections.map(\.group) == [.waitingForApproval])
    }

    @Test func theCasesAreTheSectionsInOrder() {
        #expect(WrenUpdateGroup.allCases == [.waitingForApproval, .updatesAutomatically, .available])
    }
}
