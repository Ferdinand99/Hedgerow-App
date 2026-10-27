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
            let store = try ConnectionStore(
                fileURL: AppStorageLocation.connectionsFile, vault: AppStorageLocation.makeVault()
            )
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
