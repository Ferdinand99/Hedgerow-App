import HedgerowCore
import Observation
import SwiftUI

// Target and server names, versions, the run's detail and every step's log come from agents: shown
// with `Text(verbatim:)`, plain monospaced text, never Markdown, never a link. Nothing here changes
// anything on the server.

extension WrenStepStatus {
    var symbol: String {
        switch self {
        case .running: "arrow.triangle.2.circlepath.circle.fill"
        case .ok: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "arrow.right.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .running: .blue
        case .ok: .green
        case .failed: .red
        case .skipped, .unknown: .gray
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .running: "Running"
        case .ok: "OK"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .unknown: "Unknown"
        }
    }
}

extension WrenRunStep {
    /// The step in the person's language; a step this app does not know shows the agent's own word.
    @ViewBuilder
    var title: some View {
        switch name {
        case .preflight: Text("Preflight checks")
        case .stop: Text("Stop")
        case .snapshot: Text("Snapshot")
        case .update: Text("Update")
        case .health: Text("Health check")
        case .rollback: Text("Rollback")
        case .unknown: Text(verbatim: rawName)
        }
    }
}

// MARK: - Model

/// Loads one run with its steps. The run from the list is shown at once; the steps follow.
@MainActor @Observable
final class RunDetailModel {
    private(set) var run: WrenRun
    private(set) var steps: [WrenRunStep] = []
    /// True once the steps have arrived (also when there are none).
    private(set) var hasLoaded = false
    private(set) var isLoading = true
    private(set) var problem: CardProblem?
    private(set) var lastLoaded: Date?

    @ObservationIgnored private let connection: Connection
    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private var generation = 0

    init(run: WrenRun, connection: Connection, store: ConnectionStore) {
        self.run = run
        self.connection = connection
        self.store = store
    }

    func load() async {
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }

        let client: WrenClient
        switch wrenClient(for: connection, store: store) {
        case .failure(let failure):
            problem = failure
            return
        case .success(let made):
            client = made
        }
        do {
            let detail = try await client.run(id: run.id)
            guard mine == generation else { return }
            run = detail.run
            steps = detail.steps
            hasLoaded = true
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

// MARK: - Run detail

/// One run: what it did to which target, and its steps as a timeline with the end of each log.
struct RunDetailView: View {
    /// A log with more lines than this is folded until the person asks for all of it.
    static let foldedLines = 8

    let context: ServiceContext

    @State private var model: RunDetailModel
    /// Steps whose whole log is open. A failed step starts open.
    @State private var opened: Set<Int> = []

    init(run: WrenRun, context: ServiceContext, store: ConnectionStore) {
        self.context = context
        _model = State(initialValue: RunDetailModel(run: run, connection: context.connection, store: store))
    }

    var body: some View {
        List {
            if let problem = model.problem {
                Section {
                    Label(problem.message(lastSeen: model.lastLoaded), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if problem == .tokenRejected {
                        Button("Replace token", action: context.replaceToken)
                    }
                }
            }
            summary
            stepsSection
        }
        .navigationTitle(model.run.targetName.isEmpty ? String(localized: "Run") : model.run.targetName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    // MARK: Summary

    private var summary: some View {
        let run = model.run
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: run.status.symbol)
                        .foregroundStyle(run.status.color)
                        .accessibilityHidden(true)
                    Text(run.status.label)
                        .font(.subheadline.weight(.semibold))
                }
                WrenName(name: run.targetName)
                    .font(.system(.headline, design: .monospaced))
                    .textSelection(.enabled)
                if !run.serverName.isEmpty {
                    Text(verbatim: run.serverName)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let detail = run.detail {
                    Text(verbatim: detail)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            if run.isRollback {
                LabeledContent("Type") { Text("Rollback") }
            }
            if let version = run.version {
                LabeledContent("Version") {
                    Text(verbatim: version)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if let who = run.requestedBy {
                LabeledContent("Requested by") { Text(verbatim: who) }
            }
            if let due = run.scheduledFor, run.isScheduled {
                LabeledContent("Scheduled for") { Text(due.formatted(date: .abbreviated, time: .shortened)) }
            }
            if let started = run.startedAt {
                LabeledContent("Started") { Text(started.formatted(date: .abbreviated, time: .shortened)) }
            }
            if let finished = run.finishedAt {
                LabeledContent("Finished") { Text(finished.formatted(date: .abbreviated, time: .shortened)) }
            }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepsSection: some View {
        Section {
            if model.steps.isEmpty {
                if model.hasLoaded {
                    Text("No steps yet")
                        .foregroundStyle(.secondary)
                } else if model.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading…")
                    }
                }
            }
            ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                StepRow(
                    step: step, isLast: index == model.steps.count - 1,
                    isOpen: opened.contains(step.id) || (step.status == .failed && !closedByPerson.contains(step.id)),
                    toggle: { toggle(step) }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }
        } header: {
            Text("Steps")
        }
    }

    /// Failed steps start open; a tap on them closes the log, which is remembered here.
    @State private var closedByPerson: Set<Int> = []

    private func toggle(_ step: WrenRunStep) {
        let currentlyOpen = opened.contains(step.id) || (step.status == .failed && !closedByPerson.contains(step.id))
        if currentlyOpen {
            opened.remove(step.id)
            closedByPerson.insert(step.id)
        } else {
            opened.insert(step.id)
            closedByPerson.remove(step.id)
        }
    }

    /// Whether a log is long enough to fold.
    static func isLong(_ log: String) -> Bool {
        log.count > 400 || log.reduce(into: 1) { if $1 == "\n" { $0 += 1 } } > foldedLines
    }
}

/// One step of the timeline: its symbol on a line that joins it to the next step, its name, status
/// and duration, and the end of its log as monospaced plain text.
private struct StepRow: View {
    let step: WrenRunStep
    let isLast: Bool
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: step.status.symbol)
                    .font(.title3)
                    .foregroundStyle(step.status.color)
                    .padding(.top, 10)
                    .accessibilityHidden(true)
                Rectangle()
                    .fill(Color.secondary.opacity(isLast ? 0 : 0.35))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    step.title
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(step.status.label)
                        .font(.caption)
                        .foregroundStyle(step.status.color)
                }
                metadata
                if !step.log.isEmpty {
                    log
                }
            }
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .contain)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if let started = step.startedAt {
                Text(started.formatted(date: .omitted, time: .standard))
            }
            if let ms = step.durationMs, step.status != .running {
                if step.startedAt != nil { Text(verbatim: "·") }
                Text(Duration.milliseconds(ms).formatted(
                    .units(allowed: [.hours, .minutes, .seconds, .milliseconds], width: .narrow, maximumUnitCount: 2)
                ))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var log: some View {
        let long = RunDetailView.isLong(step.log)
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: step.log)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(isOpen || !long ? nil : RunDetailView.foldedLines)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if step.logCut && isOpen {
                Text("Only the end of the log is shown.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if long {
                Button(action: toggle) {
                    if isOpen {
                        Text("Show less")
                    } else {
                        Text("Show the whole log")
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
    }
}
