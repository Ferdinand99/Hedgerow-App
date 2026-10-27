import HedgerowCore
import Observation
import SwiftUI

// Everything a person typed on the server (monitor names, groups, addresses, messages) is shown with
// `Text(verbatim:)`: plain text, never Markdown, never turned into a link.

// MARK: - Status look

extension VoleStatus {
    /// Colour is never the only signal: every status also has its own symbol and its own word.
    var symbol: String {
        switch self {
        case .up: "checkmark.circle.fill"
        case .down: "xmark.octagon.fill"
        case .pending: "clock.fill"
        case .maintenance: "wrench.and.screwdriver.fill"
        case .paused: "pause.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .up: .green
        case .down: .red
        case .pending: .orange
        case .maintenance: .blue
        case .paused, .unknown: .gray
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .pending: "Pending"
        case .maintenance: "Maintenance"
        case .paused: "Paused"
        case .unknown: "Unknown"
        }
    }
}

/// The symbol and the word for a status, side by side.
struct VoleStatusLabel: View {
    let status: VoleStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
                .accessibilityHidden(true)
            Text(status.label)
        }
    }
}

// MARK: - Model

/// Loads the monitors of one connection, page by page, and keeps them for the screen.
@MainActor @Observable
final class MonitorsModel {
    private(set) var monitors: [VoleMonitor] = []
    /// True until the first load has ended, and while a reload runs.
    private(set) var isLoading = true
    /// Why the last load failed; the list from before stays on screen next to it.
    private(set) var problem: CardProblem?
    private(set) var lastLoaded: Date?

    @ObservationIgnored private let connection: Connection
    @ObservationIgnored private let store: ConnectionStore
    /// A newer load makes an older one stop touching the screen.
    @ObservationIgnored private var generation = 0

    init(connection: Connection, store: ConnectionStore) {
        self.connection = connection
        self.store = store
    }

    func load() async {
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }

        let token: String?
        do {
            token = try store.token(for: connection.id)
        } catch {
            problem = .tokenUnreadable
            return
        }
        // No token in the Keychain is the same to the user as a token that doesn't work.
        guard let token else {
            problem = .tokenRejected
            return
        }
        let client = VoleClient(baseURL: connection.baseURL, http: HedgerowHTTP(token: token))

        // On a first load the rows appear as pages arrive; on a reload the list stays as it is
        // until the new one is complete, so it does not jump.
        let showProgress = monitors.isEmpty
        do {
            let all = try await client.monitors { [weak self] soFar in
                guard showProgress, let self, self.generation == mine else { return }
                self.monitors = soFar
            }
            guard mine == generation else { return }
            monitors = all
            problem = nil
            lastLoaded = Date()
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            problem = CardProblem(error)
        }
    }
}

// MARK: - Monitors tab

/// The content of the Monitors tab: the monitors of one Vigilant Vole, in sections per group,
/// what is down first.
struct MonitorsView: View {
    let context: ServiceContext
    let store: ConnectionStore

    @State private var model: MonitorsModel
    @State private var query = ""

    init(context: ServiceContext, store: ConnectionStore) {
        self.context = context
        self.store = store
        _model = State(initialValue: MonitorsModel(connection: context.connection, store: store))
    }

    var body: some View {
        Group {
            if model.monitors.isEmpty {
                emptyContent
            } else {
                list
            }
        }
        .searchable(text: $query, prompt: Text("Search monitors"))
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
        .task { await model.load() }
    }

    @ViewBuilder
    private var emptyContent: some View {
        if let problem = model.problem {
            ServiceProblemView(problem: problem, lastSeen: model.lastLoaded, replaceToken: context.replaceToken)
        } else if model.isLoading {
            ServiceLoadingView()
        } else {
            ContentUnavailableView {
                Label("No monitors", systemImage: "waveform.path.ecg")
            } description: {
                Text("Add a monitor in Vigilant Vole to see it here.")
            }
        }
    }

    private var list: some View {
        let sections = voleSections(model.monitors, matching: query)
        let hasGroups = sections.contains { $0.title != nil }
        let count = model.monitors.reduce(0) { $0 + ($1.isGroup ? 0 : 1) }
        return List {
            if let problem = model.problem {
                Section {
                    Label(problem.message(lastSeen: model.lastLoaded), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if problem == .tokenRejected {
                        Button("Replace token", action: context.replaceToken)
                    }
                }
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.monitors) { monitor in
                        NavigationLink {
                            MonitorDetailView(monitor: monitor, context: context, store: store)
                        } label: {
                            MonitorRow(monitor: monitor)
                        }
                    }
                } header: {
                    MonitorSectionHeader(section: section, hasGroups: hasGroups)
                }
            }
            Section {
            } footer: {
                if model.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading more…")
                    }
                } else if query.isEmpty {
                    Text("\(count) monitors")
                }
            }
        }
        .overlay {
            if sections.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .refreshable { await model.load() }
    }
}

private struct MonitorSectionHeader: View {
    let section: VoleMonitorSection
    let hasGroups: Bool

    var body: some View {
        HStack {
            if let title = section.title {
                Text(verbatim: title)
            } else if hasGroups {
                Text("Not in a group")
            }
            Spacer()
            if let status = section.status {
                VoleStatusLabel(status: status)
                    .font(.caption)
            }
        }
        .textCase(nil)
    }
}

private struct MonitorRow: View {
    let monitor: VoleMonitor

    var body: some View {
        let status = monitor.displayStatus
        HStack(spacing: 12) {
            Image(systemName: status.symbol)
                .font(.title3)
                .foregroundStyle(status.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: monitor.name)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(status.label)
                    Text(verbatim: "·")
                    Text(verbatim: monitor.kind)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
