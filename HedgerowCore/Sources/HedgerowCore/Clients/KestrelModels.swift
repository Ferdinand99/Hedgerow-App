import Foundation

// What the Issues tab reads from Keen Kestrel (`GET /api/v1/projects`, `/project-groups`,
// `/projects/{id}/issues`, `/projects/{id}/issues/{issue_id}/events/latest`). Decoding is tolerant:
// only the fields the app uses are read, unknown fields are ignored, a missing optional field is just
// absent, and one malformed item in a list is skipped instead of failing the whole page.
//
// Titles, messages, file names, function names and tags are data from the server (and from the app
// that crashed): they are kept as plain `String` and the app must show them verbatim, never as
// Markdown or links.

// MARK: - Projects

/// A project group, as Keen Kestrel's project list shows it.
public struct KestrelProjectGroup: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    /// Position in the project list (lower first); the server sends the groups in this order.
    public let sortOrder: Int

    public init(id: Int, name: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}

public struct KestrelProject: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    /// `apple`, `javascript`, `rust`, `python` or `other`.
    public let platform: String
    /// The group the project is in; `nil` for a project outside any group (or one whose group
    /// the server did not list).
    public let group: KestrelProjectGroup?

    public init(id: Int, name: String, platform: String = "other", group: KestrelProjectGroup? = nil) {
        self.id = id
        self.name = name
        self.platform = platform
        self.group = group
    }
}

/// A group (or the projects outside any group) with its projects, ready to show.
public struct KestrelProjectSection: Sendable, Equatable, Identifiable {
    public let group: KestrelProjectGroup?
    public let projects: [KestrelProject]

    public var id: String { group.map { "group-\($0.id)" } ?? "ungrouped" }
    public var title: String? { group?.name }
}

/// Sections in the order Keen Kestrel shows them: groups by their position, then the projects
/// outside any group; projects by name inside each.
public func kestrelSections(_ projects: [KestrelProject]) -> [KestrelProjectSection] {
    var buckets: [Int?: [KestrelProject]] = [:]
    var groups: [Int: KestrelProjectGroup] = [:]
    for project in projects {
        buckets[project.group?.id, default: []].append(project)
        if let group = project.group { groups[group.id] = group }
    }
    func byName(_ a: KestrelProject, _ b: KestrelProject) -> Bool {
        let order = a.name.localizedCaseInsensitiveCompare(b.name)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }
    let grouped = groups.values
        .sorted { ($0.sortOrder, $0.name, $0.id) < ($1.sortOrder, $1.name, $1.id) }
        .map { KestrelProjectSection(group: $0, projects: (buckets[$0.id] ?? []).sorted(by: byName)) }
    let rest = (buckets[nil] ?? []).sorted(by: byName)
    return rest.isEmpty ? grouped : grouped + [KestrelProjectSection(group: nil, projects: rest)]
}

// MARK: - Issues

/// How serious an issue is, as the SDK reported it.
public enum KestrelLevel: String, Sendable, Equatable, CaseIterable {
    case fatal, error, warning, info, debug, unknown

    /// An unknown or missing value is `.unknown`, never a decoding error.
    init(server value: String?) {
        self = value.flatMap { KestrelLevel(rawValue: $0.lowercased()) } ?? .unknown
    }
}

public struct KestrelIssue: Sendable, Equatable, Identifiable {
    public let id: Int
    public let projectId: Int?
    /// May be empty (the server had none); show a placeholder then.
    public let title: String
    /// Where it happened ("shop.views in checkout"), often a function or file.
    public let culprit: String?
    public let level: KestrelLevel
    public let firstSeen: Date?
    public let lastSeen: Date?
    /// How many times it happened.
    public let events: Int
    /// How many users it hit.
    public let users: Int
    public let lastRelease: String?

    public init(
        id: Int, projectId: Int? = nil, title: String, culprit: String? = nil, level: KestrelLevel = .error,
        firstSeen: Date? = nil, lastSeen: Date? = nil, events: Int = 0, users: Int = 0, lastRelease: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.culprit = culprit
        self.level = level
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.events = events
        self.users = users
        self.lastRelease = lastRelease
    }
}

/// One page of a project's unresolved issues, most recently active first.
public struct KestrelIssuePage: Sendable, Equatable {
    public let issues: [KestrelIssue]
    /// Pass to the next call; `nil` on the last page.
    public let nextCursor: String?
    /// How many issues match in all, not just on this page.
    public let total: Int?

    public init(issues: [KestrelIssue], nextCursor: String?, total: Int?) {
        self.issues = issues
        self.nextCursor = nextCursor
        self.total = total
    }
}

/// The issues loaded so far for one project, with the cursor of the next page. A screen appends
/// pages as the person scrolls; this keeps the list free of repeats (the list moves while new
/// events arrive) and stops a server that never ends its list.
public struct KestrelIssueList: Sendable, Equatable {
    /// Pages followed at most (50 000 issues), the same safety net as the monitor list.
    static let maxPages = 500

    public private(set) var issues: [KestrelIssue] = []
    public private(set) var total: Int?
    /// The cursor to ask for next, `nil` when the end is reached.
    public private(set) var nextCursor: String?
    public private(set) var pages = 0
    private var ids: Set<Int> = []
    private var cursors: Set<String> = []

    public init() {}

    public var hasMore: Bool { nextCursor != nil }

    /// Adds a page. A cursor that comes back (or too many pages) means the server is going in
    /// circles: the list is closed and `HedgerowError.unexpectedResponse` is thrown.
    public mutating func append(_ page: KestrelIssuePage) throws {
        for issue in page.issues where ids.insert(issue.id).inserted {
            issues.append(issue)
        }
        total = page.total ?? total
        pages += 1
        guard let next = page.nextCursor else {
            nextCursor = nil
            return
        }
        guard cursors.insert(next).inserted, pages < Self.maxPages else {
            nextCursor = nil
            throw HedgerowError.unexpectedResponse
        }
        nextCursor = next
    }
}

// MARK: - Latest event

/// One line of a stack trace.
public struct KestrelStackFrame: Sendable, Equatable {
    public let function: String?
    /// The file, or the full path when the SDK sent no short name.
    public let filename: String?
    public let module: String?
    /// The binary or library the code lives in (native stacks).
    public let package: String?
    public let line: Int?
    public let column: Int?
    /// Code of the app itself, as opposed to the system or a library.
    public let inApp: Bool

    public init(
        function: String? = nil, filename: String? = nil, module: String? = nil, package: String? = nil,
        line: Int? = nil, column: Int? = nil, inApp: Bool = false
    ) {
        self.function = function
        self.filename = filename
        self.module = module
        self.package = package
        self.line = line
        self.column = column
        self.inApp = inApp
    }

    /// "File.swift:42:7", or the module or package when there is no file; `nil` if nothing is known.
    public var location: String? {
        guard let place = [filename, module, package].lazy.compactMap({ $0 }).first(where: { !$0.isEmpty })
        else { return nil }
        guard let line else { return place }
        return column.map { "\(place):\(line):\($0)" } ?? "\(place):\(line)"
    }
}

/// An exception with its stack trace (or, when the event has none, the stack of a thread).
public struct KestrelException: Sendable, Equatable {
    public let type: String?
    public let value: String?
    /// The innermost call first: where it happened at the top, how it got there below.
    public let frames: [KestrelStackFrame]

    public init(type: String?, value: String?, frames: [KestrelStackFrame]) {
        self.type = type
        self.value = value
        self.frames = frames
    }

    /// "ValueError: invalid literal", or whichever half there is.
    public var heading: String? {
        let parts = [type, value].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ": ")
    }
}

public struct KestrelTag: Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// The newest event of an issue that still has its details.
public struct KestrelEvent: Sendable, Equatable {
    public let eventId: String
    public let level: KestrelLevel
    public let release: String?
    public let environment: String?
    public let timestamp: Date?
    public let platform: String?
    /// The log message of the event, when it has one.
    public let message: String?
    /// Most recent exception first (the one that was raised), each with its frames innermost first.
    public let exceptions: [KestrelException]
    /// Sorted by key.
    public let tags: [KestrelTag]

    public init(
        eventId: String, level: KestrelLevel, release: String?, environment: String?, timestamp: Date?,
        platform: String?, message: String?, exceptions: [KestrelException], tags: [KestrelTag]
    ) {
        self.eventId = eventId
        self.level = level
        self.release = release
        self.environment = environment
        self.timestamp = timestamp
        self.platform = platform
        self.message = message
        self.exceptions = exceptions
        self.tags = tags
    }

    /// What to call the event: the main exception, else the log message.
    public var title: String? { exceptions.first?.heading ?? message }

    /// The stack trace to show first: the main exception's frames, innermost first.
    public var stack: [KestrelStackFrame] { exceptions.first?.frames ?? [] }
}

// MARK: - Wire format

/// Decodes to `nil` instead of throwing, so one bad item does not fail the list around it.
struct Lossy<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

/// A JSON string, number or boolean as text; anything else is `nil` (no throw).
struct LooseText: Decodable {
    let text: String?

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let string = try? single.decode(String.self) {
            text = string
        } else if let int = try? single.decode(Int.self) {
            text = String(int)
        } else if let double = try? single.decode(Double.self) {
            text = String(double)
        } else if let bool = try? single.decode(Bool.self) {
            text = String(bool)
        } else {
            text = nil
        }
    }
}

struct KestrelProjectGroupDTO: Decodable {
    let id: Int
    let name: String
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case sortOrder = "sort_order"
    }

    var model: KestrelProjectGroup {
        KestrelProjectGroup(id: id, name: name, sortOrder: sortOrder ?? 0)
    }
}

struct KestrelProjectDTO: Decodable {
    let id: Int
    let name: String
    let platform: String?
    let groupId: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, platform
        case groupId = "group_id"
    }
}

/// `{"data": [ … ], "next_cursor": …, "total": …}` where each item may be malformed.
struct KestrelListDTO<Item: Decodable>: Decodable {
    let data: [Item]
    let nextCursor: String?
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case data, total
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([Lossy<Item>].self, forKey: .data).compactMap(\.value)
        nextCursor = try? container.decodeIfPresent(String.self, forKey: .nextCursor)
        total = try? container.decodeIfPresent(Int.self, forKey: .total)
    }
}

struct KestrelIssueDTO: Decodable {
    let id: Int
    let projectId: Int?
    let title: String?
    let culprit: String?
    let level: String?
    let firstSeen: String?
    let lastSeen: String?
    let events: Int?
    let users: Int?
    let lastRelease: String?

    enum CodingKeys: String, CodingKey {
        case id, title, culprit, level, events, users
        case projectId = "project_id"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case lastRelease = "last_release"
    }

    var model: KestrelIssue {
        KestrelIssue(
            id: id, projectId: projectId, title: title ?? "", culprit: culprit.flatMap { $0.isEmpty ? nil : $0 },
            level: KestrelLevel(server: level), firstSeen: parseServerTimestamp(firstSeen),
            lastSeen: parseServerTimestamp(lastSeen), events: events ?? 0, users: users ?? 0,
            lastRelease: lastRelease.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// A stack frame, read field by field: a field of the wrong type is left out, not an error.
struct KestrelFrameDTO: Decodable {
    let model: KestrelStackFrame

    private enum Keys: String, CodingKey {
        case function, filename, module, package, lineno, colno
        case absPath = "abs_path"
        case inApp = "in_app"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func text(_ key: Keys) -> String? {
            guard let value = (try? c.decodeIfPresent(LooseText.self, forKey: key))?.text, !value.isEmpty else {
                return nil
            }
            return value
        }
        func number(_ key: Keys) -> Int? {
            text(key).flatMap { Int($0) }
        }
        model = KestrelStackFrame(
            function: text(.function), filename: text(.filename) ?? text(.absPath), module: text(.module),
            package: text(.package), line: number(.lineno), column: number(.colno),
            inApp: (try? c.decodeIfPresent(Bool.self, forKey: .inApp)) ?? false
        )
    }
}

struct KestrelStacktraceDTO: Decodable {
    let frames: [Lossy<KestrelFrameDTO>]?
}

struct KestrelExceptionDTO: Decodable {
    let type: String?
    let value: String?
    let name: String?
    let crashed: Bool?
    let current: Bool?
    let stacktrace: Lossy<KestrelStacktraceDTO>?

    /// Innermost call first (the server sends the oldest call first).
    var frames: [KestrelStackFrame] {
        (stacktrace?.value?.frames ?? []).compactMap { $0.value?.model }.reversed()
    }
}

struct KestrelValuesDTO<Item: Decodable>: Decodable {
    let values: [Lossy<Item>]?
}

struct KestrelLogEntryDTO: Decodable {
    let formatted: String?
    let message: String?
}

struct KestrelPayloadDTO: Decodable {
    let platform: String?
    let logentry: Lossy<KestrelLogEntryDTO>?
    let exception: Lossy<KestrelValuesDTO<KestrelExceptionDTO>>?
    let threads: Lossy<KestrelValuesDTO<KestrelExceptionDTO>>?
    let tags: Lossy<[String: LooseText]>?
}

struct KestrelEventDTO: Decodable {
    let eventId: String?
    let timestamp: String?
    let level: String?
    let release: String?
    let environment: String?
    let payload: Lossy<KestrelPayloadDTO>?

    enum CodingKeys: String, CodingKey {
        case level, release, environment, timestamp, payload
        case eventId = "event_id"
    }

    var model: KestrelEvent {
        let payload = payload?.value
        // The oldest exception is first on the wire; the one that was raised is last, and shown first.
        var exceptions = (payload?.exception?.value?.values ?? []).compactMap(\.value).reversed().map {
            KestrelException(type: $0.type, value: $0.value, frames: $0.frames)
        }
        if exceptions.allSatisfy({ $0.frames.isEmpty }) {
            // No exception stack: the thread that crashed (or the current one) has it.
            let threads = (payload?.threads?.value?.values ?? []).compactMap(\.value)
            if let thread = threads.first(where: { $0.crashed == true })
                ?? threads.first(where: { $0.current == true && !$0.frames.isEmpty })
                ?? threads.first(where: { !$0.frames.isEmpty }) {
                exceptions.append(KestrelException(type: nil, value: thread.name, frames: thread.frames))
            }
        }
        let message = payload?.logentry?.value.flatMap { $0.formatted ?? $0.message }.flatMap { $0.isEmpty ? nil : $0 }
        let tags = (payload?.tags?.value ?? [:]).compactMap { key, value in
            value.text.map { KestrelTag(key: key, value: $0) }
        }.sorted { $0.key < $1.key }
        return KestrelEvent(
            eventId: eventId ?? "", level: KestrelLevel(server: level), release: release.flatMap { $0.isEmpty ? nil : $0 },
            environment: environment.flatMap { $0.isEmpty ? nil : $0 }, timestamp: parseServerTimestamp(timestamp),
            platform: payload?.platform, message: message, exceptions: exceptions, tags: tags
        )
    }
}
