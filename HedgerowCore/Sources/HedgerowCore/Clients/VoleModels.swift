import Foundation

// What the Monitors tab reads from Vigilant Vole (`GET /api/v1/monitors`, `/monitors/{id}`,
// `/monitors/{id}/heartbeats`, `/uptime`, `/events`). Decoding is tolerant: only the fields the app
// uses are read, unknown fields are ignored, and a missing optional field is just absent.
//
// Everything a person typed on the server (monitor names, descriptions, check messages) is data:
// it is kept as plain `String` and the app must show it verbatim, never as Markdown or links.

/// How a monitor is doing, as Vigilant Vole reports it.
public enum VoleStatus: String, Sendable, Equatable, CaseIterable {
    case up, down, pending, maintenance, paused, unknown

    /// An unknown or missing value is `.unknown`, never a decoding error.
    init(server value: String?) {
        self = value.flatMap { VoleStatus(rawValue: $0.lowercased()) } ?? .unknown
    }

    /// Sort rank for lists: what needs attention comes first ("down at the top").
    public var rank: Int {
        switch self {
        case .down: 0
        case .pending: 1
        case .unknown: 2
        case .maintenance: 3
        case .up: 4
        case .paused: 5
        }
    }
}

public struct VoleMonitor: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    /// The server's `monitor_type`, e.g. `http`, `tcp`, `group`.
    public let kind: String
    /// The server's `status`, which is `maintenance` while a window covers the monitor and
    /// `paused` for a paused one. `displayStatus` is what a person should see.
    public let status: VoleStatus
    /// Name of the group this monitor sits in (nested groups as "Outer / Inner"); filled in from
    /// the whole list by `monitors()`, `nil` for a monitor outside any group.
    public var group: String?
    /// The id of the group monitor above this one, if any.
    public let parentId: Int?
    /// The last response time. The list endpoint does not carry it, so it is filled in from the
    /// latest heartbeat on the detail screen.
    public var responseMs: Int?
    public let paused: Bool
    public let inMaintenance: Bool

    public init(
        id: Int, name: String, kind: String, status: VoleStatus, group: String? = nil,
        parentId: Int? = nil, responseMs: Int? = nil, paused: Bool = false, inMaintenance: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.group = group
        self.parentId = parentId
        self.responseMs = responseMs
        self.paused = paused
        self.inMaintenance = inMaintenance
    }

    public var isGroup: Bool { kind == "group" }

    /// Paused beats maintenance beats the check result.
    public var displayStatus: VoleStatus {
        if paused { return .paused }
        if inMaintenance { return .maintenance }
        return status
    }
}

/// One page of the monitor list.
public struct VoleMonitorPage: Sendable, Equatable {
    public let monitors: [VoleMonitor]
    /// Pass to the next call; `nil` on the last page.
    public let nextCursor: String?

    public init(monitors: [VoleMonitor], nextCursor: String?) {
        self.monitors = monitors
        self.nextCursor = nextCursor
    }
}

public struct VoleHeartbeat: Sendable, Equatable {
    public let status: VoleStatus
    public let responseMs: Int?
    /// What the check said ("200 OK", "timeout"). Plain text from the server.
    public let message: String?
    public let checkedAt: Date?

    public init(status: VoleStatus, responseMs: Int?, message: String?, checkedAt: Date?) {
        self.status = status
        self.responseMs = responseMs
        self.message = message
        self.checkedAt = checkedAt
    }
}

public enum VoleEventKind: String, Sendable, Equatable {
    case down, up, maintenance, paused, resumed, flapping
    case certExpiring = "cert_expiring"
    case domainExpiring = "domain_expiring"
    /// A kind this app version does not know.
    case other
}

public struct VoleEvent: Sendable, Equatable, Identifiable {
    public let id: Int
    public let kind: VoleEventKind
    public let message: String?
    public let startedAt: Date?
    /// `nil` while the event is still going on.
    public let endedAt: Date?
    public let durationSeconds: Int?

    public init(
        id: Int, kind: VoleEventKind, message: String?, startedAt: Date?, endedAt: Date?,
        durationSeconds: Int?
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
    }

    public var isOngoing: Bool { endedAt == nil }
}

public struct VoleMonitorDetail: Sendable, Equatable {
    /// At most this many recent events are fetched.
    public static let maxEvents = 20

    /// `responseMs` is filled in from `lastHeartbeat`; `group` is `nil` (the caller knows it from the list).
    public let monitor: VoleMonitor
    public let description: String?
    /// The monitored address. The server hides credentials in it from read-only tokens.
    public let target: String?
    /// The real check result, which keeps coming in during maintenance.
    public let rawMessage: String?
    public let lastHeartbeat: VoleHeartbeat?
    /// Percent, 0...100.
    public let uptime24h: Double?
    public let uptime30d: Double?
    /// Newest first, at most `maxEvents`.
    public let events: [VoleEvent]

    /// An uptime percentage as it is shown: rounded down to two decimals, never up, so 99.996 % does not
    /// read "100 %" while a check has failed. Clamped to 0...100; `nil` for a value that is not a number.
    public static func displayedUptime(_ percent: Double) -> Double? {
        guard percent.isFinite else { return nil }
        let clamped = min(max(percent, 0), 100)
        // The tiny addition keeps 99.99 (stored a hair below) from dropping to 99.98.
        return min((clamped * 100 + 1e-6).rounded(.down) / 100, 100)
    }

    public init(
        monitor: VoleMonitor, description: String?, target: String?, rawMessage: String?,
        lastHeartbeat: VoleHeartbeat?, uptime24h: Double?, uptime30d: Double?, events: [VoleEvent]
    ) {
        self.monitor = monitor
        self.description = description
        self.target = target
        self.rawMessage = rawMessage
        self.lastHeartbeat = lastHeartbeat
        self.uptime24h = uptime24h
        self.uptime30d = uptime30d
        self.events = events
    }
}

// MARK: - Groups and sections

/// A group (or the monitors outside any group) with the monitors in it, ready to show.
public struct VoleMonitorSection: Sendable, Equatable, Identifiable {
    /// The group monitor's id, or `nil` for monitors outside any group.
    public let groupId: Int?
    /// The group's name (nested: "Outer / Inner"); `nil` for monitors outside any group.
    public let title: String?
    /// The group's own status, when it is a group monitor.
    public let status: VoleStatus?
    /// Group monitors themselves are not rows; they are the section.
    public let monitors: [VoleMonitor]

    public var id: String { groupId.map { "group-\($0)" } ?? "ungrouped" }

    /// How urgent the section is: its worst monitor (or the group itself).
    var rank: Int {
        min(monitors.map { $0.displayStatus.rank }.min() ?? Int.max, status?.rank ?? Int.max)
    }
}

extension VoleMonitor {
    /// Fills in `group` from the parents in `all`. A monitor whose parent is not in `all` (yet),
    /// or a loop of parents, is left ungrouped.
    static func resolvingGroups(_ all: [VoleMonitor]) -> [VoleMonitor] {
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func path(of parentId: Int?) -> String? {
            var names: [String] = []
            var seen: Set<Int> = []
            var next = parentId
            while let id = next, let parent = byId[id], parent.isGroup, seen.insert(id).inserted {
                names.append(parent.name)
                next = parent.parentId
            }
            return names.isEmpty ? nil : names.reversed().joined(separator: " / ")
        }
        return all.map { monitor in
            var copy = monitor
            copy.group = path(of: monitor.parentId)
            return copy
        }
    }
}

/// Sections per group as Vigilant Vole shows them: down at the top (sections and rows), then by
/// name. `query` keeps monitors whose name matches, or every monitor of a group whose name matches.
public func voleSections(_ all: [VoleMonitor], matching query: String = "") -> [VoleMonitorSection] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    func matches(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    let resolved = VoleMonitor.resolvingGroups(all)
    let groups = Dictionary(
        resolved.filter(\.isGroup).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
    )
    var buckets: [Int?: [VoleMonitor]] = [:]
    for monitor in resolved where !monitor.isGroup {
        // Grouped only when the parent is a group that is in the list.
        let key: Int? = monitor.group == nil ? nil : monitor.parentId
        buckets[key, default: []].append(monitor)
    }
    // A group with nothing in it still shows up when it is down, so an outage is not hidden.
    for (id, group) in groups where buckets[id] == nil && group.displayStatus == .down {
        buckets[id] = []
    }

    func isBefore(_ a: VoleMonitor, _ b: VoleMonitor) -> Bool {
        if a.displayStatus.rank != b.displayStatus.rank { return a.displayStatus.rank < b.displayStatus.rank }
        let byName = a.name.localizedCaseInsensitiveCompare(b.name)
        return byName == .orderedSame ? a.id < b.id : byName == .orderedAscending
    }

    var sections: [VoleMonitorSection] = []
    for (key, monitors) in buckets {
        let group = key.flatMap { groups[$0] }
        let title = group.map { g in g.group.map { $0 + " / " + g.name } ?? g.name }
        let kept: [VoleMonitor]
        if needle.isEmpty || matches(title) {
            kept = monitors
        } else {
            kept = monitors.filter { matches($0.name) }
        }
        // While searching, a section with no match is left out; otherwise only an empty group
        // that is not down is (nothing to show).
        if kept.isEmpty && (!needle.isEmpty || group?.displayStatus != .down) { continue }
        sections.append(VoleMonitorSection(
            groupId: key, title: title, status: group?.displayStatus, monitors: kept.sorted(by: isBefore)
        ))
    }
    return sections.sorted { a, b in
        if a.rank != b.rank { return a.rank < b.rank }
        // Monitors outside any group come last among equals.
        switch (a.title, b.title) {
        case (nil, _): return false
        case (_, nil): return true
        case (let x?, let y?):
            let byName = x.localizedCaseInsensitiveCompare(y)
            return byName == .orderedSame ? (a.groupId ?? 0) < (b.groupId ?? 0) : byName == .orderedAscending
        }
    }
}

// MARK: - Wire format

/// What the server sends. Internal: the app reads the public types above.
struct VoleMonitorDTO: Decodable {
    let id: Int
    let name: String
    let monitorType: String?
    let status: String?
    let parentId: Int?
    let active: Bool?
    let maintenance: Bool?
    let description: String?
    let target: String?
    let rawMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, active, maintenance, description, target
        case monitorType = "monitor_type"
        case parentId = "parent_id"
        case rawMessage = "raw_message"
    }

    var model: VoleMonitor {
        let status = VoleStatus(server: status)
        return VoleMonitor(
            id: id,
            name: name,
            kind: monitorType ?? "",
            status: status,
            parentId: parentId,
            paused: active == false || status == .paused,
            inMaintenance: maintenance == true || status == .maintenance
        )
    }
}

/// One monitor the app cannot read is skipped; the others still show.
struct VoleMonitorPageDTO: Decodable {
    let data: [VoleMonitorDTO]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([Lossy<VoleMonitorDTO>].self, forKey: .data).compactMap(\.value)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

struct VoleHeartbeatDTO: Decodable {
    let status: String?
    let responseTimeMs: Int?
    let message: String?
    let checkedAt: String?

    enum CodingKeys: String, CodingKey {
        case status, message
        case responseTimeMs = "response_time_ms"
        case checkedAt = "checked_at"
    }

    var model: VoleHeartbeat {
        VoleHeartbeat(
            status: VoleStatus(server: status), responseMs: responseTimeMs, message: message,
            checkedAt: parseServerTimestamp(checkedAt)
        )
    }
}

struct VoleHeartbeatListDTO: Decodable {
    let data: [VoleHeartbeatDTO]
}

struct VoleUptimeDTO: Decodable {
    let uptimePct: Double?
    let uptime24hPct: Double?

    enum CodingKeys: String, CodingKey {
        case uptimePct = "uptime_pct"
        case uptime24hPct = "uptime_24h_pct"
    }
}

struct VoleEventDTO: Decodable {
    let id: Int
    let kind: String?
    let message: String?
    let startedAt: String?
    let endedAt: String?
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id, kind, message
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
    }

    var model: VoleEvent {
        VoleEvent(
            id: id, kind: kind.flatMap(VoleEventKind.init(rawValue:)) ?? .other, message: message,
            startedAt: parseServerTimestamp(startedAt), endedAt: parseServerTimestamp(endedAt),
            durationSeconds: durationSeconds
        )
    }
}

struct VoleEventListDTO: Decodable {
    let data: [VoleEventDTO]
}
