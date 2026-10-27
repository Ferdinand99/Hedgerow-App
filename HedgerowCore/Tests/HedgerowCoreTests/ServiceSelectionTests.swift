import Foundation
import Testing
@testable import HedgerowCore

@MainActor @Suite struct ServiceSelectionTests {
    private let vole1 = Connection(name: "Home", baseURL: URL(string: "https://vole1.example.com")!, kind: .vole)
    private let vole2 = Connection(name: "Work", baseURL: URL(string: "https://vole2.example.com")!, kind: .vole)
    private let kestrel = Connection(name: "Kestrel", baseURL: URL(string: "https://kk.example.com")!, kind: .kestrel)

    /// A private defaults database per test, so nothing leaks between tests or into the real one.
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "hedgerow-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func picksTheFirstWhenNothingIsSelected() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let selection = ServiceSelection(defaults: defaults)
        #expect(selection.selected(for: .vole, among: [kestrel, vole1, vole2]) == vole1)
        #expect(selection.selected(for: .kestrel, among: [kestrel, vole1, vole2]) == kestrel)
    }

    @Test func noConnectionOfTheKindIsNil() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let selection = ServiceSelection(defaults: defaults)
        #expect(selection.selected(for: .wren, among: [vole1, kestrel]) == nil)
        #expect(selection.selected(for: .vole, among: []) == nil)
    }

    @Test func remembersTheChoiceAcrossInstances() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        ServiceSelection(defaults: defaults).select(vole2)
        let later = ServiceSelection(defaults: defaults)
        #expect(later.selected(for: .vole, among: [vole1, vole2]) == vole2)
        // The other product is not affected.
        #expect(later.selected(for: .kestrel, among: [kestrel]) == kestrel)
    }

    @Test func fallsBackToTheFirstWhenTheSelectedConnectionIsRemoved() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let selection = ServiceSelection(defaults: defaults)
        selection.select(vole2)
        #expect(selection.selected(for: .vole, among: [vole1]) == vole1)
        // Gone with nothing left: nothing to show, not a stale connection.
        #expect(selection.selected(for: .vole, among: [kestrel]) == nil)
    }

    @Test func ignoresUnreadableOrForeignStoredValues() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let selection = ServiceSelection(defaults: defaults)
        defaults.set("not-a-uuid", forKey: ServiceSelection.key(for: .vole))
        #expect(selection.selected(for: .vole, among: [vole1, vole2]) == vole1)
        // A Kestrel connection's id stored for Vole must not make the Monitors tab show Kestrel.
        defaults.set(kestrel.id.uuidString, forKey: ServiceSelection.key(for: .vole))
        #expect(selection.selected(for: .vole, among: [kestrel, vole1]) == vole1)
    }

    @Test func storesOnlyTheConnectionId() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        ServiceSelection(defaults: defaults).select(vole2)
        let stored = defaults.persistentDomain(forName: name) ?? [:]
        #expect(stored.count == 1)
        #expect(stored[ServiceSelection.key(for: .vole)] as? String == vole2.id.uuidString)
    }

    @Test func listsTheConnectionsOfOneKindInOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgerow-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("connections.json")
        try JSONEncoder().encode([vole1, kestrel, vole2]).write(to: file)
        let store = try ConnectionStore(fileURL: file, vault: InMemoryVault())
        #expect(connections(of: .vole, in: store) == [vole1, vole2])
        #expect(connections(of: .kestrel, in: store) == [kestrel])
        #expect(connections(of: .wren, in: store).isEmpty)
    }
}
