import Foundation
import HedgerowCore

extension AppStorageLocation {
    /// The Postal Pigeon registration (device id and manage key): same access group, own item,
    /// this device only. App only: the notification extension does not compile this file, so nothing
    /// in it asks for the manage key.
    static func makePigeonStore() -> KeychainPigeonStore {
        KeychainPigeonStore(accessGroup: keychainAccessGroup)
    }
}
