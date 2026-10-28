import Foundation
import HedgerowCore
import Observation

/// Opens the stored connections once at launch. A connections file that cannot be read is
/// shown as an error with a way to reset it; the app never starts with a silently empty list
/// (the next save would overwrite the damaged file and lose it).
@MainActor @Observable
final class AppModel {
    enum State {
        case ready(ConnectionStore, OverviewModel)
        case storageDamaged
    }

    private(set) var state: State
    /// Set when "Reset connections" itself fails.
    var resetFailed = false

    init() {
        state = Self.load()
    }

    private static func load() -> State {
        do {
            let vault = AppStorageLocation.makeVault()
            // Tokens saved by earlier versions could only be read while the phone is unlocked; the
            // notification extension needs them on a locked one. The app is open, so this works now.
            vault.allowAccessAfterFirstUnlock()
            let store = try ConnectionStore(fileURL: AppStorageLocation.connectionsFile, vault: vault)
            // Push handles follow the connections. Only a list that could be read is handed over: a
            // damaged file must not look like "every connection was removed".
            PushController.shared.attach(store)
            return .ready(store, OverviewModel(store: store))
        } catch {
            return .storageDamaged
        }
    }

    /// Moves the damaged file aside, removes every token the app holds (their ids were in the
    /// damaged list, so they can no longer be matched to a connection) and starts empty.
    func resetConnections() {
        do {
            let file = AppStorageLocation.connectionsFile
            let moved = AppStorageLocation.damagedConnectionsFile
            if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: moved)
                try FileManager.default.moveItem(at: file, to: moved)
            }
            try AppStorageLocation.makeVault().deleteAll()
            resetFailed = false
            state = Self.load()
        } catch {
            resetFailed = true
        }
    }
}
