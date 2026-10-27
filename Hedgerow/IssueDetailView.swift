import HedgerowCore
import Observation
import SwiftUI

// Titles, messages, file and function names, release names and tags come from the server (and from
// the app that crashed): shown with `Text(verbatim:)`, plain text, never Markdown, never a link.
// Stack traces are monospaced text; frames of the app itself are highlighted.

/// Loads the latest event of one issue (summary fields, stack trace, tags).
@MainActor @Observable
final class IssueDetailModel: ScreenModel {
    private(set) var event: KestrelEvent?
    /// True when the server has no event with details left for this issue (a 404 on the latest event).
    private(set) var noDetails = false
    let loader = LoadTracker()

    @ObservationIgnored private let projectId: Int
    @ObservationIgnored private let issueId: Int
    @ObservationIgnored private let connection: Connection
    @ObservationIgnored private let store: ConnectionStore

    init(projectId: Int, issueId: Int, connection: Connection, store: ConnectionStore) {
        self.projectId = projectId
        self.issueId = issueId
        self.connection = connection
        self.store = store
    }

    func fetch(_ ticket: LoadTracker.Ticket) async throws {
        let client = try kestrelClient(for: connection, store: store).get()
        do {
            let loaded = try await client.latestEvent(projectId: projectId, issueId: issueId)
            guard ticket.isCurrent else { return }
            event = loaded
            noDetails = false
        } catch HedgerowError.badResponse(404) {
            guard ticket.isCurrent else { return }
            event = nil
            noDetails = true
        }
    }
}

/// One issue: what it is and how often it happens (from the list), and the latest event with its
/// stack trace and tags.
struct IssueDetailView: View {
    /// The issue as the list showed it.
    let issue: KestrelIssue
    let project: KestrelProject
    let context: ServiceContext

    @State private var model: IssueDetailModel

    init(issue: KestrelIssue, project: KestrelProject, context: ServiceContext, store: ConnectionStore) {
        self.issue = issue
        self.project = project
        self.context = context
        _model = State(initialValue: IssueDetailModel(
            projectId: project.id, issueId: issue.id, connection: context.connection, store: store
        ))
    }

    var body: some View {
        List {
            if let problem = model.problem {
                ServiceProblemBanner(problem: problem, lastSeen: model.lastLoaded, replaceToken: context.replaceToken)
            }

            summary

            if let event = model.event {
                eventSections(event)
            } else if model.noDetails {
                Section("Latest event") {
                    Text("No event details are stored for this issue.")
                        .foregroundStyle(.secondary)
                }
            } else if model.isLoading {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading…")
                    }
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .refreshPolicy(model)
    }

    // MARK: Summary

    private var summary: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: issue.level.symbol)
                        .foregroundStyle(issue.level.color)
                        .accessibilityHidden(true)
                    Text(issue.level.label)
                        .font(.subheadline.weight(.semibold))
                }
                IssueTitle(issue: issue)
                    .font(.system(.headline, design: .monospaced))
                    .textSelection(.enabled)
                if let culprit = issue.culprit {
                    Text(verbatim: culprit)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            LabeledContent("Events") { Text(issue.events, format: .number) }
            LabeledContent("Users") { Text(issue.users, format: .number) }
            if let firstSeen = issue.firstSeen {
                LabeledContent("First seen") {
                    Text(firstSeen.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if let lastSeen = issue.lastSeen {
                LabeledContent("Last seen") { Text(relativeAge(of: lastSeen)) }
            }
            if let release = issue.lastRelease {
                LabeledContent("Release") { Text(verbatim: release).textSelection(.enabled) }
            }
        }
    }

    // MARK: Latest event

    @ViewBuilder
    private func eventSections(_ event: KestrelEvent) -> some View {
        Section("Latest event") {
            if let timestamp = event.timestamp {
                LabeledContent("Time") {
                    Text(timestamp.formatted(date: .abbreviated, time: .shortened))
                }
            }
            LabeledContent("Level") { Text(event.level.label) }
            if let release = event.release {
                LabeledContent("Release") { Text(verbatim: release).textSelection(.enabled) }
            }
            if let environment = event.environment {
                LabeledContent("Environment") { Text(verbatim: environment) }
            }
            if let message = event.message {
                LabeledContent("Message") { Text(verbatim: message).textSelection(.enabled) }
            }
        }

        let stacks = event.exceptions.enumerated().filter { !$0.element.frames.isEmpty || $0.element.heading != nil }
        if stacks.isEmpty {
            Section("Stack trace") {
                Text("No stack trace was sent with this event.")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(stacks, id: \.offset) { item in
            let exception = item.element
            Section {
                if let heading = exception.heading {
                    Text(verbatim: heading)
                        .font(.system(.footnote, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                }
                ForEach(Array(exception.frames.enumerated()), id: \.offset) { entry in
                    StackFrameRow(frame: entry.element)
                }
            } header: {
                // The first one is the exception that was raised; the others led to it.
                if item.offset == 0 {
                    Text("Stack trace")
                } else {
                    Text("Earlier exception")
                }
            }
        }

        if !event.tags.isEmpty {
            Section("Tags") {
                ForEach(event.tags, id: \.key) { tag in
                    LabeledContent {
                        Text(verbatim: tag.value)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    } label: {
                        Text(verbatim: tag.key)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            }
        }
    }
}

/// One line of a stack trace, in monospaced plain text. A frame of the app itself is highlighted
/// with a bar, a tinted row and the words "In app" (colour is never the only signal).
private struct StackFrameRow: View {
    let frame: KestrelStackFrame

    var body: some View {
        let tint: Color? = frame.inApp ? Color.accentColor.opacity(0.12) : nil
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(frame.inApp ? Color.accentColor : Color.clear)
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if frame.inApp {
                    Text("In app")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
                function
                    .font(.system(.footnote, design: .monospaced).weight(frame.inApp ? .semibold : .regular))
                    .foregroundStyle(frame.inApp ? Color.primary : Color.secondary)
                if let location = frame.location {
                    Text(verbatim: location)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
        .listRowBackground(tint)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var function: some View {
        if let function = frame.function {
            Text(verbatim: function)
        } else {
            Text("Unknown function")
        }
    }
}
