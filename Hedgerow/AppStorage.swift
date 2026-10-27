import Foundation
import HedgerowCore

/// Where the app keeps its data. The connection list (no tokens) goes in the App Group
/// container and the tokens in a Keychain access group, so the phase 5 widgets can read both.
enum AppStorageLocation {
    static let appGroup = "group.tools.hedgerow.app"
    static let keychainGroupSuffix = ".tools.hedgerow.app"

    static var connectionsFile: URL {
        directory.appendingPathComponent("connections.json")
    }

    /// Where a damaged connections file is moved by "Reset connections".
    static var damagedConnectionsFile: URL {
        directory.appendingPathComponent("connections.damaged.json")
    }

    private static var directory: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            // Builds without code signing (CI, plain simulator runs) have no App Group container;
            // the app's own Application Support folder keeps them working. Signed builds never get here.
            ?? URL.applicationSupportDirectory
        return base.appendingPathComponent("Hedgerow", isDirectory: true)
    }

    static func makeVault() -> KeychainVault {
        KeychainVault(accessGroup: keychainAccessGroup)
    }

    /// The Postal Pigeon registration (device id and manage key): same access group, own item,
    /// this device only.
    static func makePigeonStore() -> KeychainPigeonStore {
        KeychainPigeonStore(accessGroup: keychainAccessGroup)
    }

    /// The Keychain access group with the team prefix resolved, read from the Info.plist value
    /// `$(AppIdentifierPrefix)tools.hedgerow.app`. `nil` without a team prefix (unsigned builds),
    /// where naming a group would make every Keychain call fail; the default group is used then.
    private static var keychainAccessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HedgerowKeychainAccessGroup") as? String,
              group.hasSuffix(keychainGroupSuffix),
              group.count > keychainGroupSuffix.count,
              !group.contains("$")
        else { return nil }
        return group
    }
}
