import HedgerowCore
import SwiftUI

/// Shown in a service tab when there is no connection of that product (Review Focus 2):
/// an invitation to add one, never an empty list.
struct ServiceEmptyView: View {
    let kind: ServiceKind
    let add: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("\(kind.displayName) isn't connected")
            } icon: {
                Image(systemName: kind.tabSymbol)
            }
        } description: {
            Text("Connect it to see its data in this tab.")
        } actions: {
            Button("Add \(kind.displayName)", action: add)
                .buttonStyle(.borderedProminent)
        }
    }
}

struct ServiceLoadingView: View {
    var body: some View {
        ProgressView("Loading…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Can't reach it" / "The token doesn't work", the same words as on the Overview card
/// (Review Focus 5). A rejected token comes with a way to replace it.
struct ServiceProblemView: View {
    let problem: CardProblem
    let lastSeen: Date?
    let replaceToken: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(problem.message(lastSeen: problem == .unreachable ? lastSeen : nil), systemImage: symbol)
        } description: {
            if let hint {
                Text(hint)
            }
        } actions: {
            if problem == .tokenRejected {
                Button("Replace token", action: replaceToken)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var symbol: String {
        switch problem {
        case .unreachable: "wifi.slash"
        case .tokenRejected, .tokenUnreadable: "lock.slash"
        case .notHedgerow, .unexpectedAnswer, .insecure: "exclamationmark.triangle"
        }
    }

    private var hint: LocalizedStringKey? {
        switch problem {
        case .unreachable: "Check your network and that the service is running."
        case .tokenRejected: "The server refused the saved token. Replace it with one that works."
        default: nil
        }
    }
}

extension ServiceKind {
    /// The symbol of the tab that shows this product.
    var tabSymbol: String {
        switch self {
        case .vole: "waveform.path.ecg"
        case .kestrel: "ladybug"
        case .wren: "arrow.triangle.2.circlepath"
        }
    }
}
