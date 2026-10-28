import Foundation
import Testing
@testable import HedgerowCore

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("hedgerow-push-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("push-tags.json")
}

private func cleanUp(_ file: URL) {
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
}

private func entry(
    _ tag: String = "tag-a", connection: UUID = UUID(), device: String = "hrd_one", handle: String = "h1", server: Int = 7
) -> PushEntry {
    PushEntry(
        tag: tag, connectionId: connection, relayDeviceId: device, relayHandleId: handle, serverDeviceId: server,
        created: Date(timeIntervalSince1970: 1_800_000_000)
    )
}

@Suite struct PushRegistryTests {
    @Test func savesAndLooksUpByTagAndByConnection() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let registry = PushRegistry(fileURL: file)
        let first = entry("tag-a")
        let second = entry("tag-b", handle: "h2", server: 9)
        try registry.save(first)
        try registry.save(second)

        #expect(registry.entry(forTag: "tag-a") == first)
        #expect(registry.entry(forTag: "tag-b") == second)
        #expect(registry.entry(forConnection: second.connectionId) == second)
        #expect(registry.entry(forTag: "nope") == nil)
        #expect(registry.entry(forConnection: UUID()) == nil)
        #expect(registry.entries().count == 2)
    }

    @Test func aSecondReaderSeesWhatTheAppWrote() throws {
        // The notification extension reads the file the app wrote, in another process.
        let file = tempFile()
        defer { cleanUp(file) }
        let saved = entry()
        try PushRegistry(fileURL: file).save(saved)
        #expect(PushRegistry(fileURL: file).entry(forTag: saved.tag) == saved)
    }

    @Test func savingAgainReplacesTheConnectionsEntry() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let registry = PushRegistry(fileURL: file)
        let connection = UUID()
        try registry.save(entry("old", connection: connection))
        try registry.save(entry("new", connection: connection, handle: "h9"))

        #expect(registry.entries().count == 1)
        #expect(registry.entry(forTag: "old") == nil)
        #expect(registry.entry(forConnection: connection)?.tag == "new")
    }

    @Test func removesOneConnectionOrAll() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let registry = PushRegistry(fileURL: file)
        let a = entry("a")
        let b = entry("b")
        try registry.save(a)
        try registry.save(b)

        try registry.remove(connectionId: a.connectionId)
        #expect(registry.entry(forTag: "a") == nil)
        #expect(registry.entry(forTag: "b") == b)

        try registry.remove(connectionId: UUID())
        #expect(registry.entries() == [b])

        try registry.removeAll()
        #expect(registry.entries().isEmpty)
    }

    @Test func aMissingDamagedOrNewerFileReadsAsEmpty() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let registry = PushRegistry(fileURL: file)
        #expect(registry.entries().isEmpty)

        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        #expect(registry.entries().isEmpty)
        // The next save replaces the damaged file.
        try registry.save(entry())
        #expect(registry.entries().count == 1)

        try Data(#"{"version":2,"entries":[]}"#.utf8).write(to: file)
        #expect(registry.entries().isEmpty)
    }

    @Test func theFileHoldsNoSecrets() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        try PushRegistry(fileURL: file).save(entry())
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("hrh_"))
        #expect(!text.contains("hrm_"))
        #expect(!text.contains("token"))
    }

    @Test func connectionsAreReadFromTheAppsFile() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        #expect(readConnections(at: file).isEmpty)
        let connection = Connection(name: "Home", baseURL: URL(string: "https://vole.example.com")!, kind: .vole)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([connection]).write(to: file)
        #expect(readConnections(at: file) == [connection])
        try Data("{".utf8).write(to: file)
        #expect(readConnections(at: file).isEmpty)
    }
}

@Suite struct PushPreferencesTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "hedgerow-tests-\(UUID().uuidString)")!
    }

    @Test func connectionsAreOnUntilSwitchedOff() {
        let preferences = PushPreferences(defaults: defaults())
        let id = UUID()
        #expect(preferences.isOn(id))
        preferences.set(id, on: false)
        #expect(!preferences.isOn(id))
        #expect(preferences.isOn(UUID()))
        preferences.set(id, on: true)
        #expect(preferences.isOn(id))
    }
}

@Suite struct PushBackoffTests {
    private func backoff() -> PushBackoff {
        PushBackoff(defaults: UserDefaults(suiteName: "hedgerow-tests-\(UUID().uuidString)")!)
    }

    @Test func aProblemIsRememberedForAnHour() {
        let backoff = backoff()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(backoff.blocked(id, now: start) == nil)

        backoff.record(id, status: .serverPushOff, now: start)
        #expect(backoff.blocked(id, now: start.addingTimeInterval(60)) == .serverPushOff)
        #expect(backoff.blocked(id, now: start.addingTimeInterval(3599)) == .serverPushOff)
        #expect(backoff.blocked(id, now: start.addingTimeInterval(3600)) == nil)
        #expect(backoff.blocked(UUID(), now: start) == nil)
    }

    @Test func clearingForgetsIt() {
        let backoff = backoff()
        let id = UUID()
        let now = Date()
        backoff.record(id, status: .tryLater, now: now)
        backoff.clear(id)
        #expect(backoff.blocked(id, now: now) == nil)
    }

    @Test func aClockSetBackDoesNotBlockForLonger() {
        let backoff = backoff()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        backoff.record(id, status: .tryLater, now: start)
        #expect(backoff.blocked(id, now: start.addingTimeInterval(-7200)) == nil)
    }
}
