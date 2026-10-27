import HedgerowCore
import SwiftUI

struct OverviewView: View {
    let store: ConnectionStore
    let model: OverviewModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAdd = false
    @State private var replacingTokenFor: Connection?

    var body: some View {
        Group {
            if store.connections.isEmpty {
                ContentUnavailableView {
                    Label("No services yet", systemImage: "leaf")
                } description: {
                    Text("Connect Vigilant Vole, Keen Kestrel or Wise Wren to see how they are doing.")
                } actions: {
                    Button("Add a service") { showingAdd = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        OverallStatusView(health: model.overallHealth)
                        ForEach(model.cards) { card in
                            ServiceCardView(card: card) {
                                replacingTokenFor = card.connection
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
                .refreshable { await model.refresh() }
            }
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    ConnectionsView(store: store, model: model)
                } label: {
                    Label("Connections", systemImage: "list.bullet")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: {
                    Label("Add a service", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddConnectionView(store: store)
        }
        .sheet(item: $replacingTokenFor) { connection in
            ReplaceTokenView(store: store, connection: connection)
        }
        // First appearance, a changed list (add/remove) and coming back to the app all refresh.
        .task { await model.refresh() }
        .onChange(of: store.connections) {
            Task { await model.refresh() }
        }
        .onChange(of: replacingTokenFor) { _, new in
            if new == nil { Task { await model.refresh() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }
}

/// The red/yellow/green line above the cards.
private struct OverallStatusView: View {
    let health: Health

    var body: some View {
        if health != .unknown {
            HStack(spacing: 8) {
                Image(systemName: health.symbol)
                    .foregroundStyle(health.color)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var title: LocalizedStringKey {
        switch health {
        case .ok: "Everything looks fine"
        case .warning: "Something needs attention"
        case .critical: "Something is down"
        case .unknown: ""
        }
    }
}

struct ServiceCardView: View {
    let card: ServiceCard
    let replaceToken: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: card.health.symbol)
                .font(.title2)
                .foregroundStyle(card.health.color)
                .accessibilityLabel(card.health.label)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.connection.name)
                    .font(.headline)
                Text(verbatim: "\(card.connection.kind.displayName) · \(card.connection.baseURL.host() ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                content
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card.health.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14)
                .fill(card.health.color)
                .frame(width: 5)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch card.phase {
        case .loading:
            ProgressView()
        case .loaded(let summary):
            summaryLines(summary)
            Text("Updated \(relative(summary.fetchedAt))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed(let problem, let lastGood):
            Text(problem.message(lastSeen: problem == .unreachable ? lastGood?.fetchedAt : nil))
                .font(.subheadline.weight(.semibold))
            if problem == .tokenRejected {
                Button("Replace token", action: replaceToken)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let lastGood {
                // What was true when it last answered, shown quietly.
                summaryLines(lastGood)
                    .opacity(0.6)
            }
        }
    }

    @ViewBuilder
    private func summaryLines(_ summary: ServiceSummary) -> some View {
        Text(summary.headline.localized)
            .font(.title3.weight(.semibold))
        ForEach(Array(summary.details.enumerated()), id: \.offset) { _, line in
            Text(line.localized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
