import HedgerowCore
import Observation
import SwiftUI

// Names of servers and targets, image references, versions, run details and release names come from
// agents and registries: they are shown with `Text(verbatim:)`, plain text, never Markdown, never a
// link. Nothing on this tab changes anything on a server: approving and scheduling come later.

// MARK: - Look of statuses

extension WrenRunStatus {
    /// Colour is never the only signal: every status also has its own symbol and its own word.
    var symbol: String {
        switch self {
        case .queued: "clock.fill"
        case .running: "arrow.triangle.2.circlepath.circle.fill"
        case .succeeded: "checkmark.circle.fill"
        case .rolledBack: "arrow.uturn.backward.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .rollbackFailed: "exclamationmark.octagon.fill"
        case .refused: "hand.raised.fill"
        case .cancelled: "minus.circle.fill"
        case .lapsed: "hourglass.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .succeeded: .green
        case .running, .queued: .blue
        case .rolledBack, .refused: .orange
        case .failed, .rollbackFailed: .red
        case .cancelled, .lapsed, .unknown: .gray
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .rolledBack: "Rolled back"
        case .failed: "Failed"
        case .rollbackFailed: "Rollback failed"
        case .refused: "Refused"
        case .cancelled: "Cancelled"
        case .lapsed: "Lapsed"
        case .unknown: "Unknown"
        }
    }
}

extension WrenAgentStatus {
    var symbol: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        case .waiting: "clock.fill"
        case .noToken: "lock.slash.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .online: .green
        case .offline: .red
        case .waiting, .noToken: .orange
        case .unknown: .gray
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .online: "Agent online"
        case .offline: "Agent offline"
        case .waiting: "Waiting for the agent"
        case .noToken: "No agent token"
        case .unknown: "Unknown"
        }
    }
}

extension WrenMode {
    var label: LocalizedStringKey {
        switch self {
        case .approve: "Approve first"
        case .notify: "Notify only"
        case .auto: "Automatic"
        case .unknown: "Unknown"
        }
    }
}

extension WrenTargetKind {
    /// `nil` for a kind this app does not know: nothing is better than a wrong word.
    var label: LocalizedStringKey? {
        switch self {
        case .container: "Container"
        case .unraid: "Unraid template"
        case .compose: "Compose stack"
        case .script: "Script stack"
        case .unknown: nil
        }
    }
}

/// The name of a target, or a placeholder when the server sent none.
struct WrenName: View {
    let name: String

    var body: some View {
        if name.isEmpty {
            Text("Unnamed")
        } else {
            Text(verbatim: name)
        }
    }
}

// MARK: - Model

/// Loads everything the Updates tab shows in one go: the targets with a new version, the scheduled
/// runs, the latest runs and the servers. The four requests run side by side, so the first screen
/// is as quick as the slowest one. Targets and runs are what the tab is about: the schedules and the
/// servers only add to them, so when those two fail (in any way) the tab shows without them.
@MainActor @Observable
final class UpdatesModel: ScreenModel {
    /// Sorted by server, then name.
    private(set) var waiting: [WrenTarget] = []
    /// Soonest first.
    private(set) var scheduled: [WrenRun] = []
    /// Newest first, without the scheduled ones.
    private(set) var recent: [WrenRun] = []
    private(set) var servers: [WrenServer] = []
    /// Per server id: is its auto window open now.
    private(set) var openWindows: Set<Int> = []
    private(set) var timeZone: String?
    /// True once a load has ended with an answer; before that there is nothing to show but progress.
    private(set) var hasLoaded = false
    let loader = LoadTracker()

    @ObservationIgnored private let connection: Connection
    @ObservationIgnored private let store: ConnectionStore

    init(connection: Connection, store: ConnectionStore) {
        self.connection = connection
        self.store = store
    }

    func fetch(_ ticket: LoadTracker.Ticket) async throws {
        let client = try wrenClient(for: connection, store: store).get()

        async let targets = client.updates()
        async let runs = client.runs()
        async let schedules = orFallback(WrenSchedules(timeZone: nil, scheduled: [], servers: [])) {
            try await client.schedules()
        }
        async let serverList = orFallback([WrenServer]()) { try await client.servers() }
        let (loadedTargets, loadedRuns, loadedSchedules, loadedServers) =
            try await (targets, runs, schedules, serverList)
        guard ticket.isCurrent else { return }
        waiting = wrenSortedTargets(loadedTargets)
        // A run that is only scheduled is under "Scheduled", not among the runs that happened.
        let scheduledIds = Set(loadedSchedules.scheduled.map(\.id))
        scheduled = loadedSchedules.scheduled.sorted { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
        recent = loadedRuns.filter { !scheduledIds.contains($0.id) && !$0.isScheduled }
        servers = loadedServers
        openWindows = Set(loadedSchedules.servers.filter(\.openNow).map(\.id))
        timeZone = loadedSchedules.timeZone
        hasLoaded = true
    }
}

// MARK: - Updates tab

/// The content of the Updates tab: what waits for approval, what is scheduled, the latest runs and
/// the servers with their agents. Read only.
struct UpdatesView: View {
    /// How many waiting targets show before "Show all": 88 rows are cheap in a lazy list, but the
    /// first screen should show every section, not 88 containers.
    static let collapsedLimit = 10

    let context: ServiceContext
    let store: ConnectionStore

    @State private var model: UpdatesModel
    @State private var showAllWaiting = false

    init(context: ServiceContext, store: ConnectionStore) {
        self.context = context
        self.store = store
        _model = State(initialValue: UpdatesModel(connection: context.connection, store: store))
    }

    var body: some View {
        Group {
            if model.hasLoaded {
                list
            } else if let problem = model.problem {
                ServiceProblemView(problem: problem, lastSeen: model.lastLoaded, replaceToken: context.replaceToken)
            } else {
                ServiceLoadingView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await model.load() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
        .refreshPolicy(model)
    }

    private var list: some View {
        List {
            if let problem = model.problem {
                ServiceProblemBanner(problem: problem, lastSeen: model.lastLoaded, replaceToken: context.replaceToken)
            }
            waitingSection
            if !model.scheduled.isEmpty {
                scheduledSection
            }
            recentSection
            if !model.servers.isEmpty {
                serversSection
            }
        }
        .refreshable { await model.load() }
    }

    // MARK: Waiting for approval

    private var waitingSection: some View {
        let shown = showAllWaiting ? model.waiting : Array(model.waiting.prefix(Self.collapsedLimit))
        return Section {
            if model.waiting.isEmpty {
                Label("Everything up to date", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(shown) { target in
                TargetRow(target: target)
            }
            if model.waiting.count > Self.collapsedLimit {
                Button {
                    showAllWaiting.toggle()
                } label: {
                    if showAllWaiting {
                        Text("Show fewer")
                    } else {
                        Text("Show all \(model.waiting.count) updates")
                    }
                }
            }
        } header: {
            SectionHeader(count: model.waiting.count) { Text("Waiting for approval") }
        }
    }

    // MARK: Scheduled

    private var scheduledSection: some View {
        Section {
            ForEach(model.scheduled) { run in
                NavigationLink {
                    RunDetailView(run: run, context: context, store: store)
                } label: {
                    ScheduledRow(run: run)
                }
            }
        } header: {
            SectionHeader(count: model.scheduled.count) { Text("Scheduled") }
        }
    }

    // MARK: Recent runs

    private var recentSection: some View {
        Section {
            if model.recent.isEmpty {
                Text("No runs yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.recent) { run in
                NavigationLink {
                    RunDetailView(run: run, context: context, store: store)
                } label: {
                    RunRow(run: run)
                }
            }
        } header: {
            Text("Recent runs")
        }
    }

    // MARK: Servers

    private var serversSection: some View {
        Section {
            ForEach(model.servers) { server in
                ServerRow(server: server, windowOpen: model.openWindows.contains(server.id), timeZone: model.timeZone)
            }
        } header: {
            Text("Servers")
        }
    }
}

/// A section title with how many rows there are, right-aligned.
private struct SectionHeader<Title: View>: View {
    let count: Int
    let title: Title

    init(count: Int, @ViewBuilder title: () -> Title) {
        self.count = count
        self.title = title()
    }

    var body: some View {
        HStack {
            title
            Spacer()
            Text(count, format: .number)
        }
        .textCase(nil)
    }
}

// MARK: - Rows

private struct TargetRow: View {
    let target: WrenTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WrenName(name: target.name)
                .lineLimit(2)
            HStack(spacing: 6) {
                if !target.serverName.isEmpty {
                    Text(verbatim: target.serverName)
                }
                if let kind = target.kind.label {
                    if !target.serverName.isEmpty { Text(verbatim: "·") }
                    Text(kind)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let change = target.change {
                Text(verbatim: change)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let release = target.releaseTitle {
                Label {
                    Text(verbatim: release)
                } icon: {
                    Image(systemName: "doc.text")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let reason = target.blockedReason {
                VStack(alignment: .leading, spacing: 1) {
                    Label("Blocked", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(verbatim: reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ScheduledRow: View {
    let run: WrenRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WrenName(name: run.targetName)
                .lineLimit(2)
            if !run.serverName.isEmpty {
                Text(verbatim: run.serverName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let due = run.scheduledFor {
                Label {
                    Text(due.formatted(date: .abbreviated, time: .shortened))
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RunRow: View {
    let run: WrenRun

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: run.status.symbol)
                .font(.title3)
                .foregroundStyle(run.status.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                WrenName(name: run.targetName)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(run.status.label)
                    if run.isRollback {
                        Text(verbatim: "·")
                        Text("Rollback")
                    }
                    if let when = run.when {
                        Text(verbatim: "·")
                        Text(relativeAge(of: when))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !run.serverName.isEmpty {
                    Text(verbatim: run.serverName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let detail = run.detail, run.status.isFailure {
                    Text(verbatim: detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ServerRow: View {
    let server: WrenServer
    let windowOpen: Bool
    let timeZone: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                WrenName(name: server.name)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                Label(server.status.label, systemImage: server.status.symbol)
                    .font(.caption)
                    .foregroundStyle(server.status.color)
            }
            HStack(spacing: 6) {
                Text(server.mode.label)
                if let seen = server.lastSeen, server.status != .online {
                    Text(verbatim: "·")
                    Text("Last seen \(relativeAge(of: seen))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if server.mode == .auto, let window = server.autoWindow {
                HStack(spacing: 6) {
                    Text("Auto window")
                    Text(verbatim: windowText(window))
                    if windowOpen {
                        Text(verbatim: "·")
                        Text("Open now")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let os = server.os {
                Text(verbatim: os)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = server.dockerError {
                VStack(alignment: .leading, spacing: 1) {
                    Label("Docker reports a problem", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(verbatim: error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func windowText(_ window: WrenAutoWindow) -> String {
        let hours = "\(window.start)–\(window.end)"
        guard let timeZone, !timeZone.isEmpty else { return hours }
        return "\(hours) (\(timeZone))"
    }
}
