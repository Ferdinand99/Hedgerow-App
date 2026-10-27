import Foundation
import HedgerowCore
import SwiftUI

extension SummaryLine {
    /// The line in the person's language. `key` is looked up in the String Catalog (plural
    /// variants included) and filled with the arguments; a key missing from the catalog falls
    /// back to the key itself, which is the English text.
    var localized: String {
        String(format: NSLocalizedString(key, comment: "Card line from a Hedgerow service"),
               locale: .current, arguments: formatArguments)
    }
}

/// "2 min. ago" / "for 2 min. siden": always in the past (a time ahead of `now`, from clock skew,
/// counts as now), in the person's language.
func relativeAge(of date: Date, now: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    formatter.dateTimeStyle = .numeric
    return formatter.localizedString(for: min(date, now), relativeTo: now)
}

extension Health {
    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .critical: .red
        case .unknown: .gray
        }
    }

    /// Colour is never the only signal: each state also has its own symbol and spoken label.
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .ok: "OK"
        case .warning: "Needs attention"
        case .critical: "Problem"
        case .unknown: "Unknown"
        }
    }
}

extension ServiceKind {
    /// Product names are names, not words: not translated.
    var displayName: String {
        switch self {
        case .vole: "Vigilant Vole"
        case .kestrel: "Keen Kestrel"
        case .wren: "Wise Wren"
        }
    }
}

extension CardProblem {
    func message(lastSeen: Date?) -> String {
        switch self {
        case .unreachable:
            if let lastSeen {
                let when = relativeAge(of: lastSeen)
                return String(localized: "Can't reach it (last seen \(when))")
            }
            return String(localized: "Can't reach it")
        case .tokenRejected:
            return String(localized: "The token doesn't work")
        case .tokenUnreadable:
            return String(localized: "Can't read the token (device locked?)")
        case .notHedgerow:
            return String(localized: "No Hedgerow app found here")
        case .unexpectedAnswer:
            return String(localized: "Unexpected answer from the server")
        case .insecure:
            return String(localized: "This address isn't allowed (http outside your own network)")
        }
    }
}

/// What a person reads when adding a connection, replacing a token or removing one fails.
func userMessage(for error: any Error) -> String {
    switch error {
    case let error as HedgerowError:
        switch error {
        case .notHedgerow:
            return String(localized: "No Hedgerow app found here")
        case .unauthorized, .forbidden:
            return String(localized: "The token doesn't work")
        case .unreachable:
            return String(localized: "Can't reach this address. Check the address and your network.")
        case .insecureURL:
            return String(localized: "This address isn't allowed. Use https, or http only for addresses on your own network.")
        case .badResponse(let status):
            return String(localized: "The server answered with an error (\(status)).")
        case .tooLarge, .unexpectedResponse:
            return String(localized: "Unexpected answer from the server")
        }
    case is KeychainError:
        return String(localized: "Couldn't save the token in the Keychain.")
    case let error as ConnectionStoreError where error == .unknownConnection:
        return String(localized: "That connection no longer exists.")
    default:
        return String(localized: "Something went wrong.")
    }
}
