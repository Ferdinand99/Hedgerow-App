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

// MARK: - Client

/// A Keen Kestrel client for a connection, or the problem that stops one: no token readable, or
/// none saved (the same to the user as a token that does not work).
@MainActor
func kestrelClient(for connection: Connection, store: ConnectionStore) -> Result<KestrelClient, CardProblem> {
    let token: String?
    do {
        token = try store.token(for: connection.id)
    } catch {
        return .failure(.tokenUnreadable)
    }
    guard let token else { return .failure(.tokenRejected) }
    return .success(KestrelClient(baseURL: connection.baseURL, http: HedgerowHTTP(token: token)))
}

// MARK: - Projects model

/// Loads the projects of one connection, and then how many unresolved issues each has.
@MainActor @Observable
final class IssueProjectsModel {
    /// Counts are fetched for this many projects at most, four at a time.
    private static let maxCounted = 60
    private static let countConcurrency = 4

    private(set) var projects: [KestrelProject] = []
    /// Unresolved issues per project id; a project missing here has no count (yet).
    private(set) var counts: [Int: Int] = [:]
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

        let client: KestrelClient
        switch kestrelClient(for: connection, store: store) {
        case .failure(let failure):
            problem = failure
            isLoading = false
            return
        case .success(let made):
            client = made
        }

        do {
            let loaded = try await client.projects()
            guard mine == generation else { return }
            projects = loaded
            problem = nil
            lastLoaded = Date()
            isLoading = false
        } catch is CancellationError {
            if mine == generation { isLoading = false }
            return
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            problem = CardProblem(error)
            isLoading = false
            return
        }
        await loadCounts(client: client, projects: projects, generation: mine)
    }

    /// The counts arrive one by one, so the rows fill in while the list is already usable. A project
    /// whose count fails simply has none: the list itself loaded.
    private func loadCounts(client: KestrelClient, projects: [KestrelProject], generation mine: Int) async {
        let ids = projects.prefix(Self.maxCounted).map(\.id)
        await withTaskGroup(of: (Int, Int?).self) { group in
            var index = 0
            while index < min(Self.countConcurrency, ids.count) {
                let id = ids[index]
                index += 1
                group.addTask { (id, try? await client.unresolvedCount(projectId: id)) }
            }
            while let (id, count) = await group.next() {
                if mine == generation, let count { counts[id] = count }
                if index < ids.count, mine == generation, !Task.isCancelled {
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
final class ProjectIssuesModel {
    /// The next page is asked for when one of this many last rows shows up.
    private static let prefetchDistance = 15

    private(set) var list = KestrelIssueList()
    /// True until the first page has arrived, and while a reload runs.
    private(set) var isLoading = true
    private(set) var isLoadingMore = false
    /// Why the first page (or a reload) failed; the issues from before stay on screen next to it.
    private(set) var problem: CardProblem?
    /// Why a later page failed. Nothing more is asked for until the person taps "Try again".
    private(set) var moreProblem: CardProblem?
    private(set) var lastLoaded: Date?

    @ObservationIgnored private let projectId: Int
    @ObservationIgnored private let connection: Connection
    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private var generation = 0

    init(projectId: Int, connection: Connection, store: ConnectionStore) {
        self.projectId = projectId
        self.connection = connection
        self.store = store
    }

    /// The first page; also a reload. The list from before stays until the new page is there.
    func load() async {
        generation += 1
        let mine = generation
        isLoading = true
        isLoadingMore = false
        defer { if mine == generation { isLoading = false } }

        let client: KestrelClient
        switch kestrelClient(for: connection, store: store) {
        case .failure(let failure):
            problem = failure
            return
        case .success(let made):
            client = made
        }
        do {
            let page = try await client.issuesPage(projectId: projectId)
            guard mine == generation else { return }
            var fresh = KestrelIssueList()
            try fresh.append(page)
            list = fresh
            problem = nil
            moreProblem = nil
            lastLoaded = Date()
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            problem = CardProblem(error)
        }
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
        let mine = generation
        let client: KestrelClient
        switch kestrelClient(for: connection, store: store) {
        case .failure(let failure):
            moreProblem = failure
            return
        case .success(let made):
            client = made
        }
        isLoadingMore = true
        defer { if mine == generation { isLoadingMore = false } }
        do {
            let page = try await client.issuesPage(projectId: projectId, cursor: cursor)
            guard mine == generation else { return }
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
            guard mine == generation, !Task.isCancelled else { return }
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
                Label("No open issues", systemImage: "checkmark.circle")
            } description: {
                Text("Nothing is unresolved in this project.")
            }
        }
    }

    private var list: some View {
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
        }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private var footer: some View {
        if let problem = model.moreProblem {
            VStack(alignment: .leading, spacing: 8) {
                Label(problem.message(lastSeen: nil), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if model.list.hasMore {
                    Button("Try again") { Task { await model.retryMore() } }
                }
            }
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
