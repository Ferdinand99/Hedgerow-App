import HedgerowCore
import Observation
import SwiftUI

// Titles, culprits, project and group names come from the server (and from the apps that crashed):
// they are shown with `Text(verbatim:)`: plain text, never Markdown, never turned into a link.

// MARK: - Level look

extension KestrelLevel {
    /// Colour is never the only signal: every level also has its own symbol and its own word.
    var symbol: String {
        switch self {
        case .fatal: "xmark.octagon.fill"
        case .error: "exclamationmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .debug: "ant.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .fatal, .error: .red
        case .warning: .orange
        case .info: .blue
        case .debug, .unknown: .gray
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .fatal: "Fatal"
        case .error: "Error"
        case .warning: "Warning"
        case .info: "Info"
        case .debug: "Debug"
        case .unknown: "Unknown"
        }
    }
}

/// The title of an issue, or a placeholder when the server had none.
struct IssueTitle: View {
    let issue: KestrelIssue

    var body: some View {
        if issue.title.isEmpty {
            Text("Untitled issue")
        } else {
            Text(verbatim: issue.title)
        }
    }
}

// MARK: - Projects model

/// Loads the projects of one connection, and then how many unresolved issues each has.
/// `load()` ends with the project list; the counts follow in a task of their own, so a pull to refresh
/// does not wait for up to sixty more requests.
@MainActor @Observable
final class IssueProjectsModel: ScreenModel {
    /// Counts are fetched for this many projects at most, four at a time.
    static let maxCounted = 60
    private static let countConcurrency = 4

    private(set) var projects: [KestrelProject] = []
    /// Unresolved issues per project id; a project missing here has no count (yet).
    private(set) var counts: [Int: Int] = [:]
    let loader = LoadTracker()

    @ObservationIgnored private let connection: Connection
    @ObservationIgnored private let store: ConnectionStore
    /// The counting that follows the last project list; a new load cancels it, and so does the
    /// screen going away (`pauseCounts`).
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    /// True while the screen is away: nothing is counted then.
    @ObservationIgnored private var countsPaused = false
    /// True when counting was cut short (the screen went away) and some projects may still lack a count.
    @ObservationIgnored private var countsInterrupted = false

    init(connection: Connection, store: ConnectionStore) {
        self.connection = connection
        self.store = store
    }

    /// How many projects get a count, when there are more projects than that; `nil` when all do.
    var countCap: Int? { projects.count > Self.maxCounted ? Self.maxCounted : nil }

    func fetch(_ ticket: LoadTracker.Ticket) async throws {
        countsTask?.cancel()
        countsTask = nil

        let client = try kestrelClient(for: connection, store: store).get()
        let loaded = try await client.projects()
        guard ticket.isCurrent else { return }
        projects = loaded
        // A new list: the old counts belong to the old list's counting, which was cancelled above.
        countsInterrupted = false
        startCounts(client: client, ids: loaded.prefix(Self.maxCounted).map(\.id), ticket: ticket)
    }

    /// The screen is going away (or the connection is being switched, which replaces the screen):
    /// stop counting at once, so no request goes on for a list nobody looks at.
    func pauseCounts() {
        countsPaused = true
        guard let task = countsTask else { return }
        task.cancel()
        countsTask = nil
        countsInterrupted = true
    }

    /// The screen is back. If the counting was cut short, it carries on with the projects that still
    /// have no count.
    func resumeCounts() {
        countsPaused = false
        guard countsInterrupted, countsTask == nil else { return }
        countsInterrupted = false
        let missing = projects.prefix(Self.maxCounted).map(\.id).filter { counts[$0] == nil }
        guard !missing.isEmpty, let client = try? kestrelClient(for: connection, store: store).get() else { return }
        startCounts(client: client, ids: missing, ticket: loader.ticket)
    }

    /// Counts `ids` in a task of its own, unless the screen is away: then it waits for `resumeCounts`.
    private func startCounts(client: KestrelClient, ids: [Int], ticket: LoadTracker.Ticket) {
        if countsPaused {
            countsInterrupted = true
            return
        }
        countsTask = Task { [weak self] in
            await self?.loadCounts(client: client, ids: ids, ticket: ticket)
            // Done on its own (a cancelled one has already been replaced or dropped): nothing is
            // left to resume, a project whose count failed is not asked again just for coming back.
            if !Task.isCancelled { self?.countsTask = nil }
        }
    }

    /// The counts arrive one by one, so the rows fill in while the list is already usable. A project
    /// whose count fails simply has none: the list itself loaded.
    private func loadCounts(client: KestrelClient, ids: [Int], ticket: LoadTracker.Ticket) async {
        await withTaskGroup(of: (Int, Int?).self) { group in
            var index = 0
            while index < min(Self.countConcurrency, ids.count) {
                let id = ids[index]
                index += 1
                group.addTask { (id, try? await client.unresolvedCount(projectId: id)) }
            }
            while let (id, count) = await group.next() {
                if ticket.isCurrent, let count { counts[id] = count }
                if index < ids.count, ticket.isCurrent, !Task.isCancelled {
                    let next = ids[index]
                    index += 1
                    group.addTask { (next, try? await client.unresolvedCount(projectId: next)) }
                }
            }
        }
    }
}

// MARK: - Issues tab

/// The content of the Issues tab: the projects of one Keen Kestrel, in sections per project group.
/// A project opens its issues.
struct IssuesView: View {
    let context: ServiceContext
    let store: ConnectionStore

    @State private var model: IssueProjectsModel

    init(context: ServiceContext, store: ConnectionStore) {
        self.context = context
        self.store = store
        _model = State(initialValue: IssueProjectsModel(connection: context.connection, store: store))
    }

    var body: some View {
        Group {
            if model.projects.isEmpty {
                emptyContent
            } else {
                list
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
        // Counting is for a screen somebody looks at: it stops when the list goes away (a pushed
        // project, another tab, a switched connection) and carries on when it comes back.
        .onAppear { model.resumeCounts() }
        .onDisappear { model.pauseCounts() }
    }

    private var emptyContent: some View {
        ServiceEmptyState(model: model, replaceToken: context.replaceToken) {
            ContentUnavailableView {
                Label("No projects", systemImage: "ladybug")
            } description: {
                Text("Create a project in Keen Kestrel to see its issues here.")
            }
        }
    }

    private var list: some View {
        let sections = kestrelSections(model.projects)
        let hasGroups = sections.contains { $0.group != nil }
        return List {
            if let problem = model.problem {
                ServiceProblemBanner(problem: problem, lastSeen: model.lastLoaded, replaceToken: context.replaceToken)
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.projects) { project in
                        NavigationLink {
                            ProjectIssuesView(project: project, context: context, store: store)
                        } label: {
                            ProjectRow(project: project, unresolved: model.counts[project.id])
                        }
                    }
                } header: {
                    if let title = section.title {
                        Text(verbatim: title).textCase(nil)
                    } else if hasGroups {
                        Text("Not in a group").textCase(nil)
                    }
                }
            }
            if let cap = model.countCap {
                Section {
                } footer: {
                    Text("Only the first \(cap) projects are counted")
                }
            }
        }
        .refreshable { await model.load() }
    }
}

private struct ProjectRow: View {
    let project: KestrelProject
    let unresolved: Int?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: project.name)
                    .lineLimit(2)
                Text(verbatim: project.platform)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let unresolved {
                if unresolved == 0 {
                    Label("No open issues", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("\(unresolved) unresolved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Issues of a project

/// Loads a project's unresolved issues page by page; the next page follows as the end comes near.
@MainActor @Observable
final class ProjectIssuesModel: ScreenModel {
    /// The next page is asked for when one of this many last rows shows up.
    private static let prefetchDistance = 15

    private(set) var list = KestrelIssueList()
    private(set) var isLoadingMore = false
    /// Why a later page failed. Nothing more is asked for until the person taps "Try again".
    private(set) var moreProblem: CardProblem?
    /// The first page's load; `problem` is why it (or a reload) failed, and the issues from before
    /// stay on screen next to it.
    let loader = LoadTracker()

    @ObservationIgnored private let projectId: Int
    @ObservationIgnored private let connection: Connection
    @ObservationIgnored private let store: ConnectionStore

    init(projectId: Int, connection: Connection, store: ConnectionStore) {
        self.projectId = projectId
        self.connection = connection
        self.store = store
    }

    /// The first page; also a reload. The list from before stays until the new page is there. A
    /// screen that merely appears again does not get here while its data is fresh (`loadIfStale`), so
    /// a list the person has scrolled into is only started over by a forced reload or old data.
    func fetch(_ ticket: LoadTracker.Ticket) async throws {
        isLoadingMore = false
        let client = try kestrelClient(for: connection, store: store).get()
        let page = try await client.issuesPage(projectId: projectId)
        guard ticket.isCurrent else { return }
        var fresh = KestrelIssueList()
        try fresh.append(page)
        list = fresh
        moreProblem = nil
    }

    /// Called when a row shows up: asks for the next page when the end of the list is near.
    func rowAppeared(_ issue: KestrelIssue) {
        guard list.issues.suffix(Self.prefetchDistance).contains(where: { $0.id == issue.id }) else { return }
        Task { await loadMore() }
    }

    func retryMore() async {
        moreProblem = nil
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, moreProblem == nil, let cursor = list.nextCursor else { return }
        let ticket = loader.ticket
        let client: KestrelClient
        switch kestrelClient(for: connection, store: store) {
        case .failure(let failure):
            moreProblem = failure
            return
        case .success(let made):
            client = made
        }
        isLoadingMore = true
        defer { if ticket.isCurrent { isLoadingMore = false } }
        do {
            let page = try await client.issuesPage(projectId: projectId, cursor: cursor)
            guard ticket.isCurrent else { return }
            var grown = list
            do {
                try grown.append(page)
            } catch {
                // The server went in circles: keep what came, and stop asking.
                list = grown
                moreProblem = CardProblem(error)
                return
            }
            list = grown
        } catch is CancellationError {
            return
        } catch {
            guard ticket.isCurrent, !Task.isCancelled else { return }
            moreProblem = CardProblem(error)
        }
    }
}

/// One project's unresolved issues, most recently active first, with infinite scrolling.
struct ProjectIssuesView: View {
    let project: KestrelProject
    let context: ServiceContext
    let store: ConnectionStore

    @State private var model: ProjectIssuesModel

    init(project: KestrelProject, context: ServiceContext, store: ConnectionStore) {
        self.project = project
        self.context = context
        self.store = store
        _model = State(initialValue: ProjectIssuesModel(
            projectId: project.id, connection: context.connection, store: store
        ))
    }

    var body: some View {
        Group {
            if model.list.issues.isEmpty {
                emptyContent
            } else {
                list
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshPolicy(model)
    }

    private var emptyContent: some View {
        ServiceEmptyState(model: model, replaceToken: context.replaceToken) {
            ContentUnavailableView {
                Label("No open issues", systemImage: "checkmark.circle")
            } description: {
                Text("Nothing is unresolved in this project.")
            }
        }
    }

    private var list: some View {
        List {
            if let problem = model.problem {
                ServiceProblemBanner(problem: problem, lastSeen: model.lastLoaded, replaceToken: context.replaceToken)
            }
            Section {
                ForEach(model.list.issues) { issue in
                    NavigationLink {
                        IssueDetailView(issue: issue, project: project, context: context, store: store)
                    } label: {
                        IssueRow(issue: issue)
                    }
                    .onAppear { model.rowAppeared(issue) }
                }
            } footer: {
                footer
            }
            // A later page that failed: the same note as everywhere, "Replace token" included.
            if let problem = model.moreProblem {
                ServiceProblemBanner(
                    problem: problem, lastSeen: nil, replaceToken: context.replaceToken,
                    retry: retryMore
                )
            }
        }
        .refreshable { await model.load() }
    }

    /// "Try again" for a failed later page, only while there is a later page to ask for.
    private var retryMore: (() -> Void)? {
        guard model.list.hasMore else { return nil }
        return { Task { await model.retryMore() } }
    }

    @ViewBuilder
    private var footer: some View {
        if model.moreProblem != nil {
            EmptyView()
        } else if model.isLoadingMore {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading more…")
            }
        } else if let total = model.list.total {
            Text("\(total) issues")
        }
    }
}

private struct IssueRow: View {
    let issue: KestrelIssue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issue.level.symbol)
                .font(.title3)
                .foregroundStyle(issue.level.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                IssueTitle(issue: issue)
                    .lineLimit(2)
                if let culprit = issue.culprit {
                    Text(verbatim: culprit)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(issue.level.label)
                    Text(verbatim: "·")
                    Text("\(issue.events) events")
                    if issue.users > 0 {
                        Text(verbatim: "·")
                        Text("\(issue.users) users")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let lastSeen = issue.lastSeen {
                    Text("Last seen \(relativeAge(of: lastSeen))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
