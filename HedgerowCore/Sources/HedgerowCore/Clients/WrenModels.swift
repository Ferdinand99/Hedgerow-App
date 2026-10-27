import Foundation

// What the Updates tab reads from Wise Wren (`GET /api/v1/servers`, `/updates`, `/schedules`, `/runs`,
// `/runs/{id}`). Decoding is tolerant: only the fields the app uses are read, unknown fields are
// ignored, a missing optional field is just absent, an unknown status is `.unknown`, and one malformed
// item in a list is skipped instead of failing the whole list.
//
// Names of servers and targets, image references, versions, run details and step logs are reported by
// agents and registries: they are kept as plain `String` and the app must show them verbatim, never as
// Markdown or links.

// MARK: - Servers

/// How the server's agent is doing, as Wren sees its heartbeats.
public enum WrenAgentStatus: String, Sendable, Equatable {
    /// Heartbeats arrive (at most 90 seconds apart).
    case online
    /// It has reported before, but not lately.
    case offline
    /// The server has a token, but the agent has not reported yet.
    case waiting
    /// The server has no agent token (never made, or revoked).
    case noToken = "no_token"
    case unknown

    init(server value: String?) {
        self = value.flatMap { WrenAgentStatus(rawValue: $0.lowercased()) } ?? .unknown
    }
}

/// What Wren does with an available update by itself.
public enum WrenMode: String, Sendable, Equatable {
    /// Waits for a person to approve.
    case approve
    /// Only tells.
    case notify
    /// Updates on its own inside the auto window.
    case auto
    case unknown

    init(server value: String?) {
        self = value.flatMap { WrenMode(rawValue: $0.lowercased()) } ?? .unknown
    }
}

/// The hours (local `HH:MM`, in the site's time zone) when `auto` targets may update.
public struct WrenAutoWindow: Sendable, Equatable {
    public let start: String
    public let end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

public struct WrenServer: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let status: WrenAgentStatus
    /// The agent's last heartbeat.
    public let lastSeen: Date?
    public let hostname: String?
    public let os: String?
    public let dockerVersion: String?
    /// What Docker said when the agent could not read it (empty when fine).
    public let dockerError: String?
    public let agentVersion: String?
    public let unraid: Bool
    public let mode: WrenMode
    public let autoWindow: WrenAutoWindow?

    public init(
        id: Int, name: String, status: WrenAgentStatus, lastSeen: Date? = nil, hostname: String? = nil,
        os: String? = nil, dockerVersion: String? = nil, dockerError: String? = nil, agentVersion: String? = nil,
        unraid: Bool = false, mode: WrenMode = .unknown, autoWindow: WrenAutoWindow? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.lastSeen = lastSeen
        self.hostname = hostname
        self.os = os
        self.dockerVersion = dockerVersion
        self.dockerError = dockerError
        self.agentVersion = agentVersion
        self.unraid = unraid
        self.mode = mode
        self.autoWindow = autoWindow
    }
}

// MARK: - Targets

/// What Wren watches on a server.
public enum WrenTargetKind: String, Sendable, Equatable {
    case container
    /// An Unraid template container.
    case unraid
    case compose
    case script
    case unknown

    init(server value: String?) {
        self = value.flatMap { WrenTargetKind(rawValue: $0.lowercased()) } ?? .unknown
    }
}

public struct WrenTarget: Sendable, Equatable, Identifiable {
    public let id: Int
    public let serverId: Int?
    /// May be empty (the server did not say); show a placeholder then.
    public let serverName: String
    public let kind: WrenTargetKind
    public let name: String
    public let image: String?
    /// The version in use, when Wren can tell (a version string; otherwise `nil`).
    public let installedVersion: String?
    /// The newest version, when Wren can tell.
    public let latestVersion: String?
    /// What is new, as Wren shows it: a short digest ("4f90b33d4a1c"), "2/6" images, or a version.
    public let available: String?
    /// Why the server's agent would refuse to update it. Server data: plain text only.
    public let blockedReason: String?
    /// The release's name (for example "v2.1.0"), when Wren found release notes. Its link is not kept:
    /// the app does not open links from servers.
    public let releaseTitle: String?
    public let lastChecked: Date?

    public init(
        id: Int, serverId: Int? = nil, serverName: String = "", kind: WrenTargetKind = .container, name: String,
        image: String? = nil, installedVersion: String? = nil, latestVersion: String? = nil,
        available: String? = nil, blockedReason: String? = nil, releaseTitle: String? = nil,
        lastChecked: Date? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.serverName = serverName
        self.kind = kind
        self.name = name
        self.image = image
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.available = available
        self.blockedReason = blockedReason
        self.releaseTitle = releaseTitle
        self.lastChecked = lastChecked
    }

    /// "1.4.2 → 1.5.0" when both versions are known, otherwise what is available ("4f90b33d4a1c",
    /// "2/6"); `nil` if nothing is known.
    public var change: String? {
        if let installedVersion, let latestVersion {
            return "\(installedVersion) → \(latestVersion)"
        }
        return available ?? latestVersion
    }
}

/// Targets in the order the Updates tab lists them: by server name, then by target name.
public func wrenSortedTargets(_ targets: [WrenTarget]) -> [WrenTarget] {
    targets.sorted { a, b in
        let server = a.serverName.localizedCaseInsensitiveCompare(b.serverName)
        if server != .orderedSame { return server == .orderedAscending }
        let name = a.name.localizedCaseInsensitiveCompare(b.name)
        if name != .orderedSame { return name == .orderedAscending }
        return a.id < b.id
    }
}

// MARK: - Runs

public enum WrenRunStatus: String, Sendable, Equatable, CaseIterable {
    /// Approved, waiting for the agent (or, with a time, scheduled).
    case queued
    case running
    case succeeded
    /// The update failed and was undone.
    case rolledBack = "rolled_back"
    /// Nothing changed.
    case failed
    /// Needs a person.
    case rollbackFailed = "rollback_failed"
    /// Refused by the agent's own configuration.
    case refused
    case cancelled
    /// A newer version appeared before it started.
    case lapsed
    case unknown

    init(server value: String?) {
        self = value.flatMap { WrenRunStatus(rawValue: $0.lowercased()) } ?? .unknown
    }

    /// Something went wrong (the same statuses the Overview counts as failed).
    public var isFailure: Bool {
        switch self {
        case .failed, .rolledBack, .rollbackFailed: true
        default: false
        }
    }

    /// Queued or running.
    public var isActive: Bool { self == .queued || self == .running }
}

public struct WrenRun: Sendable, Equatable, Identifiable {
    public let id: Int
    public let serverId: Int?
    public let serverName: String
    public let targetId: Int?
    /// May be empty; show a placeholder then.
    public let targetName: String
    public let targetKind: WrenTargetKind
    /// `update` or `rollback`.
    public let kind: String
    public let status: WrenRunStatus
    /// Why it ended as it did (an agent's words). Server data: plain text only.
    public let detail: String?
    /// The version the run moved to, as Wren shows it.
    public let version: String?
    public let requestedBy: String?
    /// `user`, `schedule` or `auto`.
    public let trigger: String?
    /// When a scheduled run is due.
    public let scheduledFor: Date?
    public let createdAt: Date?
    public let startedAt: Date?
    public let finishedAt: Date?

    public init(
        id: Int, serverId: Int? = nil, serverName: String = "", targetId: Int? = nil, targetName: String = "",
        targetKind: WrenTargetKind = .container, kind: String = "update", status: WrenRunStatus,
        detail: String? = nil, version: String? = nil, requestedBy: String? = nil, trigger: String? = nil,
        scheduledFor: Date? = nil, createdAt: Date? = nil, startedAt: Date? = nil, finishedAt: Date? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.serverName = serverName
        self.targetId = targetId
        self.targetName = targetName
        self.targetKind = targetKind
        self.kind = kind
        self.status = status
        self.detail = detail
        self.version = version
        self.requestedBy = requestedBy
        self.trigger = trigger
        self.scheduledFor = scheduledFor
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var isRollback: Bool { kind == "rollback" }

    /// Approved for a later time and not started.
    public var isScheduled: Bool { status == .queued && scheduledFor != nil }

    /// The time that matters for sorting and "x ago": when it ended, else started, else created.
    public var when: Date? { finishedAt ?? startedAt ?? createdAt }
}

/// The steps of a run, in the order the agent took them.
public enum WrenStepName: String, Sendable, Equatable {
    case preflight, stop, snapshot, update, health, rollback
    case unknown
}

public enum WrenStepStatus: String, Sendable, Equatable {
    case running, ok, failed, skipped
    case unknown

    init(server value: String?) {
        self = value.flatMap { WrenStepStatus(rawValue: $0.lowercased()) } ?? .unknown
    }
}

public struct WrenRunStep: Sendable, Equatable, Identifiable {
    /// A step is told apart by its position (the same step can come twice, for example after a retry).
    public let id: Int
    public let name: WrenStepName
    /// The step's name as the agent sent it (shown as is when `name` is `.unknown`).
    public let rawName: String
    public let status: WrenStepStatus
    public let startedAt: Date?
    public let durationMs: Int?
    /// The end of the step's log, plain text; empty when there is none. Long logs are cut to their
    /// last `WrenRunStep.maxLogCharacters` characters (`logCut`).
    public let log: String
    public let logCut: Bool

    /// What the screen holds of one step's log; the agent already sends only the end of it.
    public static let maxLogCharacters = 20_000

    public init(
        id: Int, name: WrenStepName, rawName: String? = nil, status: WrenStepStatus, startedAt: Date? = nil,
        durationMs: Int? = nil, log: String = "", logCut: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rawName = rawName ?? name.rawValue
        self.status = status
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.log = log
        self.logCut = logCut
    }
}

public struct WrenRunDetail: Sendable, Equatable {
    public let run: WrenRun
    public let steps: [WrenRunStep]

    public init(run: WrenRun, steps: [WrenRunStep]) {
        self.run = run
        self.steps = steps
    }
}

// MARK: - Schedules

/// Upcoming scheduled updates, and per server when `auto` targets may update by themselves.
public struct WrenSchedules: Sendable, Equatable {
    /// The site's time zone, the one the auto windows' `HH:MM` are in.
    public let timeZone: String?
    /// Soonest first.
    public let scheduled: [WrenRun]
    public let servers: [WrenServerWindow]

    public init(timeZone: String?, scheduled: [WrenRun], servers: [WrenServerWindow]) {
        self.timeZone = timeZone
        self.scheduled = scheduled
        self.servers = servers
    }
}

public struct WrenServerWindow: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let mode: WrenMode
    public let window: WrenAutoWindow?
    public let openNow: Bool
    /// The names of the targets that update on their own inside the window.
    public let autoTargets: [String]

    public init(
        id: Int, name: String, mode: WrenMode, window: WrenAutoWindow?, openNow: Bool, autoTargets: [String]
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.window = window
        self.openNow = openNow
        self.autoTargets = autoTargets
    }
}

// MARK: - Wire format

private func clean(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return text
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Every Wren list is `{"<name>": [ ... ]}` where each item may be malformed: those are skipped.
private func wrenItems<Item: Decodable>(_ decoder: Decoder, key name: String, as: Item.Type) throws -> [Item] {
    let container = try decoder.container(keyedBy: AnyKey.self)
    return try container.decode([Lossy<Item>].self, forKey: AnyKey(stringValue: name)!).compactMap(\.value)
}

struct WrenNamedDTO: Decodable {
    let id: Int?
    let name: String?
    let kind: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        name = (try? c.decodeIfPresent(LooseText.self, forKey: .name))?.text
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind }
}

struct WrenServersDTO: Decodable {
    let servers: [WrenServerDTO]

    enum CodingKeys: String, CodingKey { case servers }

    init(from decoder: Decoder) throws {
        servers = try wrenItems(decoder, key: "servers", as: WrenServerDTO.self)
    }
}

struct WrenWindowDTO: Decodable {
    let start: String?
    let end: String?
    let openNow: Bool?

    enum CodingKeys: String, CodingKey {
        case start, end
        case openNow = "open_now"
    }

    var model: WrenAutoWindow? {
        guard let start = clean(start), let end = clean(end) else { return nil }
        return WrenAutoWindow(start: start, end: end)
    }
}

struct WrenServerDTO: Decodable {
    let id: Int
    let name: String?
    let status: String?
    let lastSeenAt: String?
    let hostname: String?
    let os: String?
    let dockerVersion: String?
    let dockerError: String?
    let agentVersion: String?
    let unraid: Bool?
    let mode: String?
    let autoWindow: Lossy<WrenWindowDTO>?

    enum CodingKeys: String, CodingKey {
        case id, name, status, hostname, os, unraid, mode
        case lastSeenAt = "last_seen_at"
        case dockerVersion = "docker_version"
        case dockerError = "docker_error"
        case agentVersion = "agent_version"
        case autoWindow = "auto_window"
    }

    var model: WrenServer {
        WrenServer(
            id: id, name: name ?? "", status: WrenAgentStatus(server: status),
            lastSeen: parseServerTimestamp(lastSeenAt), hostname: clean(hostname), os: clean(os),
            dockerVersion: clean(dockerVersion), dockerError: clean(dockerError), agentVersion: clean(agentVersion),
            unraid: unraid ?? false, mode: WrenMode(server: mode), autoWindow: autoWindow?.value?.model
        )
    }
}

struct WrenReleaseDTO: Decodable {
    let title: String?
}

struct WrenTargetsDTO: Decodable {
    let targets: [WrenTargetDTO]

    enum CodingKeys: String, CodingKey { case targets }

    init(from decoder: Decoder) throws {
        targets = try wrenItems(decoder, key: "targets", as: WrenTargetDTO.self)
    }
}

struct WrenTargetDTO: Decodable {
    let id: Int
    let server: Lossy<WrenNamedDTO>?
    let kind: String?
    let name: String?
    let image: String?
    let installedVersion: String?
    let latestVersion: String?
    let available: String?
    let blockedReason: String?
    let releaseNotes: Lossy<WrenReleaseDTO>?
    let lastCheckedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, server, kind, name, image, available
        case installedVersion = "installed_version"
        case latestVersion = "latest_version"
        case blockedReason = "blocked_reason"
        case releaseNotes = "release_notes"
        case lastCheckedAt = "last_checked_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        server = try? c.decodeIfPresent(Lossy<WrenNamedDTO>.self, forKey: .server)
        func text(_ key: CodingKeys) -> String? {
            (try? c.decodeIfPresent(LooseText.self, forKey: key))?.text
        }
        kind = text(.kind)
        name = text(.name)
        image = text(.image)
        installedVersion = text(.installedVersion)
        latestVersion = text(.latestVersion)
        available = text(.available)
        blockedReason = text(.blockedReason)
        releaseNotes = try? c.decodeIfPresent(Lossy<WrenReleaseDTO>.self, forKey: .releaseNotes)
        lastCheckedAt = text(.lastCheckedAt)
    }

    var model: WrenTarget {
        WrenTarget(
            id: id, serverId: server?.value?.id, serverName: server?.value?.name ?? "",
            kind: WrenTargetKind(server: kind), name: name ?? "", image: clean(image),
            installedVersion: clean(installedVersion), latestVersion: clean(latestVersion),
            available: clean(available), blockedReason: clean(blockedReason),
            releaseTitle: clean(releaseNotes?.value?.title), lastChecked: parseServerTimestamp(lastCheckedAt)
        )
    }
}

struct WrenRunsDTO: Decodable {
    let runs: [WrenRunDTO]

    enum CodingKeys: String, CodingKey { case runs }

    init(from decoder: Decoder) throws {
        runs = try wrenItems(decoder, key: "runs", as: WrenRunDTO.self)
    }
}

struct WrenRunDTO: Decodable {
    let id: Int
    let server: Lossy<WrenNamedDTO>?
    let target: Lossy<WrenNamedDTO>?
    let kind: String?
    let status: String?
    let detail: String?
    let version: String?
    let requestedBy: String?
    let trigger: String?
    let scheduledFor: String?
    let createdAt: String?
    let startedAt: String?
    let finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, server, target, kind, status, detail, version, trigger
        case requestedBy = "requested_by"
        case scheduledFor = "scheduled_for"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        server = try? c.decodeIfPresent(Lossy<WrenNamedDTO>.self, forKey: .server)
        target = try? c.decodeIfPresent(Lossy<WrenNamedDTO>.self, forKey: .target)
        func text(_ key: CodingKeys) -> String? {
            (try? c.decodeIfPresent(LooseText.self, forKey: key))?.text
        }
        kind = text(.kind)
        status = text(.status)
        detail = text(.detail)
        version = text(.version)
        requestedBy = text(.requestedBy)
        trigger = text(.trigger)
        scheduledFor = text(.scheduledFor)
        createdAt = text(.createdAt)
        startedAt = text(.startedAt)
        finishedAt = text(.finishedAt)
    }

    var model: WrenRun {
        WrenRun(
            id: id, serverId: server?.value?.id, serverName: server?.value?.name ?? "",
            targetId: target?.value?.id, targetName: target?.value?.name ?? "",
            targetKind: WrenTargetKind(server: target?.value?.kind), kind: clean(kind) ?? "update",
            status: WrenRunStatus(server: status), detail: clean(detail), version: clean(version),
            requestedBy: clean(requestedBy), trigger: clean(trigger),
            scheduledFor: parseServerTimestamp(scheduledFor), createdAt: parseServerTimestamp(createdAt),
            startedAt: parseServerTimestamp(startedAt), finishedAt: parseServerTimestamp(finishedAt)
        )
    }
}

struct WrenStepDTO: Decodable {
    let step: String?
    let status: String?
    let startedAt: String?
    let durationMs: Int?
    let log: String?

    enum CodingKeys: String, CodingKey {
        case step, status, log
        case startedAt = "started_at"
        case durationMs = "duration_ms"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        step = (try? c.decodeIfPresent(LooseText.self, forKey: .step))?.text
        status = (try? c.decodeIfPresent(LooseText.self, forKey: .status))?.text
        startedAt = (try? c.decodeIfPresent(LooseText.self, forKey: .startedAt))?.text
        durationMs = try? c.decodeIfPresent(Int.self, forKey: .durationMs)
        log = (try? c.decodeIfPresent(LooseText.self, forKey: .log))?.text
    }

    func model(at index: Int) -> WrenRunStep {
        let raw = step ?? ""
        let text = log ?? ""
        let cut = text.count > WrenRunStep.maxLogCharacters
        return WrenRunStep(
            id: index, name: WrenStepName(rawValue: raw.lowercased()) ?? .unknown, rawName: raw,
            status: WrenStepStatus(server: status), startedAt: parseServerTimestamp(startedAt),
            durationMs: durationMs.map { max($0, 0) },
            log: cut ? String(text.suffix(WrenRunStep.maxLogCharacters)) : text, logCut: cut
        )
    }
}

/// A run with its `steps` (the run's own fields sit beside them).
struct WrenRunDetailDTO: Decodable {
    let run: WrenRunDTO
    let steps: [WrenStepDTO]

    enum CodingKeys: String, CodingKey { case steps }

    init(from decoder: Decoder) throws {
        run = try WrenRunDTO(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A step without a name is not a step.
        steps = ((try? c.decodeIfPresent([Lossy<WrenStepDTO>].self, forKey: .steps)) ?? [])
            .compactMap(\.value)
            .filter { !($0.step ?? "").isEmpty }
    }
}

struct WrenSchedulesDTO: Decodable {
    struct ServerItem: Decodable {
        struct TargetItem: Decodable {
            let name: String?
        }

        let id: Int
        let name: String?
        let mode: String?
        let autoWindow: Lossy<WrenWindowDTO>?
        let autoTargets: [Lossy<TargetItem>]?

        enum CodingKeys: String, CodingKey {
            case id, name, mode
            case autoWindow = "auto_window"
            case autoTargets = "auto_targets"
        }

        var model: WrenServerWindow {
            let window = autoWindow?.value
            return WrenServerWindow(
                id: id, name: name ?? "", mode: WrenMode(server: mode), window: window?.model,
                openNow: window?.openNow ?? false,
                autoTargets: (autoTargets ?? []).compactMap { $0.value?.name }.filter { !$0.isEmpty }
            )
        }
    }

    let timeZone: String?
    let scheduled: [WrenRunDTO]
    let servers: [ServerItem]

    enum CodingKeys: String, CodingKey {
        case timeZone = "time_zone"
        case scheduled, servers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeZone = try? c.decodeIfPresent(String.self, forKey: .timeZone)
        scheduled = ((try? c.decodeIfPresent([Lossy<WrenRunDTO>].self, forKey: .scheduled)) ?? []).compactMap(\.value)
        servers = ((try? c.decodeIfPresent([Lossy<ServerItem>].self, forKey: .servers)) ?? []).compactMap(\.value)
    }
}
