import HedgerowCore
import Observation
import SwiftUI

// Names, addresses, descriptions and messages come from the server: shown with `Text(verbatim:)`,
// plain text, never Markdown, never a link.

/// Loads one monitor's detail (latest check, uptime, recent events).
@MainActor @Observable
final class MonitorDetailModel: ScreenModel {
    private(set) var detail: VoleMonitorDetail?
    let loader = LoadTracker()

    @ObservationIgnored private let connection: Connection
    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private let monitorId: Int

    init(monitorId: Int, connection: Connection, store: ConnectionStore) {
        self.monitorId = monitorId
        self.connection = connection
        self.store = store
    }

    func fetch(_ ticket: LoadTracker.Ticket) async throws {
        let client = try voleClient(for: connection, store: store).get()
        let loaded = try await client.monitor(id: monitorId)
        guard ticket.isCurrent else { return }
        detail = loaded
    }
}

/// One monitor: how it is doing now, its last check, uptime and recent events.
struct MonitorDetailView: View {
    /// The monitor as the list showed it (name, group and status while the detail loads).
    let monitor: VoleMonitor
    let context: ServiceContext

    @State private var model: MonitorDetailModel

    init(monitor: VoleMonitor, context: ServiceContext, store: ConnectionStore) {
        self.monitor = monitor
        self.context = context
        _model = State(initialValue: MonitorDetailModel(
            monitorId: monitor.id, connection: context.connection, store: store
        ))
    }

    var body: some View {
        Group {
            if let detail = model.detail {
                content(detail)
            } else {
                firstLoad
            }
        }
        .navigationTitle(monitor.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .refreshPolicy(model)
    }

    /// Before the first answer: progress, or why there is none, with a way to try again (a list, so
    /// pulling down works here too).
    private var firstLoad: some View {
        List {
            if let problem = model.problem {
                ServiceProblemBanner(
                    problem: problem, lastSeen: model.lastLoaded, replaceToken: context.replaceToken,
                    retry: { Task { await model.load() } }
                )
            } else {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading…")
                    }
                }
            }
        }
    }

    private func content(_ detail: VoleMonitorDetail) -> some View {
        let status = detail.monitor.displayStatus
        return List {
            if let problem = model.problem {
                ServiceProblemBanner(problem: problem, lastSeen: model.lastLoaded, replaceToken: context.replaceToken)
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: status.symbol)
                        .font(.title2)
                        .foregroundStyle(status.color)
                        .accessibilityHidden(true)
                    Text(status.label)
                        .font(.title3.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                LabeledContent("Type") { Text(verbatim: detail.monitor.kind) }
                if let group = monitor.group {
                    LabeledContent("Group") { Text(verbatim: group) }
                }
                if let target = detail.target {
                    LabeledContent("Address") {
                        Text(verbatim: target).textSelection(.enabled)
                    }
                }
                if let description = detail.description {
                    Text(verbatim: description)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Last check") {
                if let beat = detail.lastHeartbeat {
                    if let ms = beat.responseMs {
                        LabeledContent("Response time") { Text("\(ms) ms") }
                    }
                    if let checkedAt = beat.checkedAt {
                        LabeledContent("Checked") { Text(relativeAge(of: checkedAt)) }
                    }
                    if let message = beat.message ?? detail.rawMessage, !message.isEmpty {
                        LabeledContent("Message") { Text(verbatim: message) }
                    }
                } else {
                    Text("No checks yet")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Uptime") {
                LabeledContent("Last 24 hours") { uptimeText(detail.uptime24h) }
                LabeledContent("Last 30 days") { uptimeText(detail.uptime30d) }
            }

            Section("Recent events") {
                if detail.events.isEmpty {
                    Text("No events yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detail.events) { event in
                        EventRow(event: event)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func uptimeText(_ percent: Double?) -> some View {
        // Rounded down, never up: 99.996 % must not read "100 %".
        if let percent, let shown = VoleMonitorDetail.displayedUptime(percent) {
            Text(shown / 100, format: .percent.precision(.fractionLength(0...2)))
        } else {
            Text(verbatim: "–")
        }
    }
}

private struct EventRow: View {
    let event: VoleEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                if let message = event.message, !message.isEmpty {
                    Text(verbatim: message)
                        .font(.subheadline)
                }
                timing
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var timing: some View {
        HStack(spacing: 6) {
            if let startedAt = event.startedAt {
                Text(startedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if event.isOngoing {
                Text(verbatim: "·")
                Text("Ongoing")
            } else if let seconds = event.durationSeconds {
                Text(verbatim: "·")
                Text(Duration.seconds(seconds).formatted(
                    .units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
                ))
            }
        }
    }

    private var label: LocalizedStringKey {
        switch event.kind {
        case .down: "Outage"
        case .up: "Back up"
        case .maintenance: "Maintenance"
        case .paused: "Paused"
        case .resumed: "Resumed"
        case .flapping: "Flapping"
        case .certExpiring: "Certificate expiring"
        case .domainExpiring: "Domain expiring"
        case .other: "Event"
        }
    }

    private var symbol: String {
        switch event.kind {
        case .down: "xmark.octagon.fill"
        case .up: "checkmark.circle.fill"
        case .maintenance: "wrench.and.screwdriver.fill"
        case .paused: "pause.circle.fill"
        case .resumed: "play.circle.fill"
        case .flapping: "arrow.triangle.2.circlepath"
        case .certExpiring, .domainExpiring: "calendar.badge.exclamationmark"
        case .other: "circle.fill"
        }
    }

    private var color: Color {
        switch event.kind {
        case .down: .red
        case .up: .green
        case .maintenance: .blue
        case .flapping, .certExpiring, .domainExpiring: .orange
        case .paused, .resumed, .other: .gray
        }
    }
}
