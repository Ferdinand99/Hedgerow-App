import Foundation

/// One connection's push handle. No secrets: the handle itself (`hrh_…`) goes from the relay to the
/// server and is not kept. This is what lets the app (and the notification extension) tell which
/// connection a push belongs to, and what is needed to take the handle down again.
public struct PushEntry: Codable, Sendable, Equatable {
    /// The tag the relay echoes in every push for the handle.
    public let tag: String
    public let connectionId: UUID
    /// The relay device the handle belongs to (`hrd_…`). When the device is registered again the
    /// handle is dead, and this is how the app notices.
    public let relayDeviceId: String
    /// The relay's id for the handle, to revoke it.
    public let relayHandleId: String
    /// The server's id for the device registration, to remove it.
    public let serverDeviceId: Int
    public let created: Date

    public init(
        tag: String, connectionId: UUID, relayDeviceId: String, relayHandleId: String, serverDeviceId: Int,
        created: Date
    ) {
        self.tag = tag
        self.connectionId = connectionId
        self.relayDeviceId = relayDeviceId
        self.relayHandleId = relayHandleId
        self.serverDeviceId = serverDeviceId
        self.created = created
    }
}

/// The tags in use, in a JSON file in the App Group container (written by the app, read by the
/// notification extension). Writes are atomic. A missing, damaged or newer file reads as empty:
/// the app finds the handles again by asking the relay (see `PushHandleManager.reconcile`).
public final class PushRegistry: @unchecked Sendable {
    private struct File: Codable {
        var version = 1
        var entries: [PushEntry]
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func entries() -> [PushEntry] {
        lock.withLock { read() }
    }

    public func entry(forTag tag: String) -> PushEntry? {
        entries().first { $0.tag == tag }
    }

    public func entry(forConnection id: UUID) -> PushEntry? {
        entries().first { $0.connectionId == id }
    }

    /// Replaces the entry the connection (or the tag) already had.
    public func save(_ entry: PushEntry) throws {
        try lock.withLock {
            var list = read().filter { $0.connectionId != entry.connectionId && $0.tag != entry.tag }
            list.append(entry)
            try write(list)
        }
    }

    public func remove(connectionId: UUID) throws {
        try lock.withLock {
            let list = read()
            let kept = list.filter { $0.connectionId != connectionId }
            if kept.count != list.count { try write(kept) }
        }
    }

    public func removeAll() throws {
        try lock.withLock {
            if !read().isEmpty { try write([]) }
        }
    }

    private func read() -> [PushEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data), file.version == 1 else { return [] }
        return file.entries
    }

    private func write(_ entries: [PushEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(File(entries: entries))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

/// The connections as the app saved them (no tokens), for the notification extension, which has no
/// `ConnectionStore`. An unreadable file is an empty list.
public func readConnections(at fileURL: URL) -> [Connection] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return (try? JSONDecoder().decode([Connection].self, from: data)) ?? []
}

// MARK: - The person's choice

/// Which connections the person switched push off for. New connections are on by default (once
/// notifications are on for the device). Ids only.
public struct PushPreferences: @unchecked Sendable {
    private static let key = "push.disabledConnections"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isOn(_ id: UUID) -> Bool {
        !disabled.contains(id.uuidString)
    }

    public func set(_ id: UUID, on: Bool) {
        var list = disabled
        list.remove(id.uuidString)
        if !on { list.insert(id.uuidString) }
        defaults.set(Array(list).sorted(), forKey: Self.key)
    }

    private var disabled: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }
}

// MARK: - Not trying again at once

/// A connection whose handle could not be set up (the server has push off, is busy, or the relay's
/// hourly limit is used up) is not tried again on every launch: the relay allows 10 new handles an
/// hour and each try uses one. The result is remembered for an hour. A switch the person flips by
/// hand always tries.
public struct PushBackoff: @unchecked Sendable {
    private static let key = "push.retryAfter"
    static let window: TimeInterval = 3600

    private struct Item: Codable {
        let status: PushConnectionStatus
        let until: Date
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The remembered result while the hour has not passed.
    public func blocked(_ id: UUID, now: Date = Date()) -> PushConnectionStatus? {
        guard let item = items[id.uuidString] else { return nil }
        // A time further ahead than the window (the clock was set back) does not count.
        guard item.until > now, item.until.timeIntervalSince(now) <= Self.window else { return nil }
        return item.status
    }

    public func record(_ id: UUID, status: PushConnectionStatus, now: Date = Date()) {
        var list = items
        list[id.uuidString] = Item(status: status, until: now.addingTimeInterval(Self.window))
        save(list)
    }

    public func clear(_ id: UUID) {
        var list = items
        if list.removeValue(forKey: id.uuidString) != nil { save(list) }
    }

    private var items: [String: Item] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Item].self, from: data)) ?? [:]
    }

    private func save(_ list: [String: Item]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try? encoder.encode(list), forKey: Self.key)
    }
}
