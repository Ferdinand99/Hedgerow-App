import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HedgerowCore

@MainActor @Suite struct ConnectionStoreTests {
    private let secret = "vv_SECRET_token_123"
    private let base = URL(string: "https://vole.example.com")!

    /// A throwaway directory with the file the store writes to.
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgerow-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("connections.json")
    }

    private func cleanUp(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// Like a real vole-kit server: the OpenAPI document and the viewer endpoint both need a
    /// signed-in user, so everything answers 401 unless the `Authorization: Bearer` header carries
    /// `accepted`. With it, the OpenAPI document is `product` and the viewer endpoint answers
    /// `viewerStatus` / `viewerBody`.
    private func stub(
        product: String = "openapi-vole.json", viewerStatus: Int = 200, viewerBody: String = "[]",
        accepted: String? = nil
    ) throws -> StubTransport {
        let document = try fixture(product)
        let viewer = Data(viewerBody.utf8)
        let accepted = accepted ?? secret
        return StubTransport { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(accepted)" else {
                return (Data(#"{"error":"unauthorized"}"#.utf8), 401)
            }
            if request.url?.path == "/api/v1/openapi.json" { return (document, 200) }
            return (viewer, viewerStatus)
        }
    }

    private func makeStore(
        file: URL, vault: InMemoryVault, transport: StubTransport
    ) throws -> ConnectionStore {
        try ConnectionStore(fileURL: file, vault: vault) { token in
            HedgerowHTTP(token: token, transport: transport)
        }
    }

    @Test func addDetectsKindAndStoresTokenSeparately() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let transport = try stub()
        let store = try makeStore(file: file, vault: vault, transport: transport)

        let added = try await store.add(url: base, token: secret, name: "Home Vole")

        #expect(added.kind == .vole)
        #expect(added.name == "Home Vole")
        #expect(added.baseURL == base)
        #expect(store.connections.map(\.id) == [added.id])
        #expect(try vault.token(for: added.id) == secret)

        // The token is only in the vault, never in the file.
        let bytes = try Data(contentsOf: file)
        #expect(!bytes.isEmpty)
        #expect(bytes.range(of: Data(secret.utf8)) == nil)

        // Both the detection and the viewer call carry the token (the server needs it for both).
        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/api/v1/openapi.json")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)")
        #expect(requests[1].url?.path == "/api/v1/monitors")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)")

        // A fresh store reads the connection back from disk.
        let reloaded = try makeStore(file: file, vault: vault, transport: transport)
        #expect(reloaded.connections.map(\.id) == [added.id])
        #expect(reloaded.connections.first?.kind == .vole)
    }

    @Test func removeDeletesToken() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let store = try makeStore(file: file, vault: vault, transport: try stub())
        let added = try await store.add(url: base, token: secret, name: nil)
        #expect(try vault.token(for: added.id) == secret)

        try store.remove(added.id)

        #expect(store.connections.isEmpty)
        #expect(try vault.token(for: added.id) == nil)
        let reloaded = try makeStore(file: file, vault: vault, transport: try stub())
        #expect(reloaded.connections.isEmpty)
    }

    @Test func addRefusesInsecureURL() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let transport = try stub()
        let store = try makeStore(file: file, vault: vault, transport: transport)

        await #expect(throws: HedgerowError.insecureURL) {
            try await store.add(url: URL(string: "http://vole.example.com")!, token: secret, name: nil)
        }

        #expect(transport.requests.isEmpty)
        #expect(store.connections.isEmpty)
        #expect(vault.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: [(401, HedgerowError.unauthorized), (403, HedgerowError.forbidden)])
    func addRejectsUnauthorizedToken(status: Int, expected: HedgerowError) async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let store = try makeStore(file: file, vault: vault, transport: try stub(viewerStatus: status))

        await #expect(throws: expected) {
            try await store.add(url: base, token: secret, name: nil)
        }

        #expect(store.connections.isEmpty)
        #expect(vault.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func addWithAWrongTokenIsUnauthorizedAtDetection() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let transport = try stub(accepted: "some-other-token")
        let store = try makeStore(file: file, vault: vault, transport: transport)

        await #expect(throws: HedgerowError.unauthorized) {
            try await store.add(url: base, token: secret, name: nil)
        }

        // Detection already said no; the viewer call was never made.
        #expect(transport.requests.map { $0.url?.path } == ["/api/v1/openapi.json"])
        #expect(store.connections.isEmpty)
        #expect(vault.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func addWithATokenThatMayNotReadTheApiIsForbiddenAtDetection() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let transport = StubTransport(status: 403, body: Data(#"{"error":"forbidden"}"#.utf8))
        let store = try makeStore(file: file, vault: vault, transport: transport)

        await #expect(throws: HedgerowError.forbidden) {
            try await store.add(url: base, token: secret, name: nil)
        }
        #expect(store.connections.isEmpty)
        #expect(vault.isEmpty)
    }

    @Test func addThatIsCancelledStoresNothing() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let store = try makeStore(file: file, vault: vault, transport: try stub())
        let url = base, token = secret

        let task = Task { @MainActor in
            try await store.add(url: url, token: token, name: nil)
        }
        task.cancel()
        _ = try? await task.value

        #expect(store.connections.isEmpty)
        #expect(vault.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: [
        ("openapi-vole.json", "/api/v1/monitors", ServiceKind.vole),
        ("openapi-kestrel.json", "/api/v1/projects", .kestrel),
        ("openapi-wren.json", "/api/v1/servers", .wren),
    ])
    func validatesWithTheViewerEndpointOfEachKind(
        product: String, path: String, kind: ServiceKind
    ) async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let transport = try stub(product: product)
        let store = try makeStore(file: file, vault: InMemoryVault(), transport: transport)

        let added = try await store.add(url: base, token: secret, name: nil)

        #expect(added.kind == kind)
        #expect(transport.requests.last?.url?.path == path)
    }

    @Test func nonJSONAnswerToTheViewerCallIsNotHedgerow() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let store = try makeStore(
            file: file, vault: vault, transport: try stub(viewerBody: "<html>Please sign in</html>")
        )

        await #expect(throws: HedgerowError.notHedgerow) {
            try await store.add(url: base, token: secret, name: nil)
        }
        #expect(store.connections.isEmpty)
        #expect(vault.isEmpty)
    }

    @Test func addToAnAddressThatIsNotHedgerowStoresNothing() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let store = try makeStore(
            file: file, vault: vault, transport: try stub(product: "pangolin-login.html")
        )

        await #expect(throws: HedgerowError.notHedgerow) {
            try await store.add(url: base, token: secret, name: nil)
        }
        #expect(store.connections.isEmpty)
        #expect(vault.isEmpty)
    }

    @Test func blankTokenIsRejectedWithoutSendingAnything() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let transport = try stub()
        let store = try makeStore(file: file, vault: InMemoryVault(), transport: transport)

        await #expect(throws: HedgerowError.unauthorized) {
            try await store.add(url: base, token: "  \n", name: nil)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func pastedTokenIsTrimmed() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let transport = try stub()
        let store = try makeStore(file: file, vault: vault, transport: transport)

        let added = try await store.add(url: base, token: " \(secret)\n", name: nil)

        #expect(try vault.token(for: added.id) == secret)
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)")
    }

    @Test func nameDefaultsToTheProductNameThenAddsTheHost() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let store = try makeStore(file: file, vault: InMemoryVault(), transport: try stub())

        let unnamed = try await store.add(url: base, token: secret, name: nil)
        let blank = try await store.add(url: base, token: secret, name: "   ")

        #expect(unnamed.name == "Vigilant Vole")
        #expect(blank.name == "Vigilant Vole (vole.example.com)")
    }

    @Test func aNameTheUserTypedIsKept() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let store = try makeStore(file: file, vault: InMemoryVault(), transport: try stub())

        let named = try await store.add(url: base, token: secret, name: "  Home  ")
        #expect(named.name == "Home")
    }

    @Test func defaultNameRule() {
        let wren = URL(string: "https://wren.example.com")!
        let other = URL(string: "https://wren2.example.com")!
        #expect(Connection.defaultName(kind: .wren, url: wren, existing: []) == "Wise Wren")
        // Another kind with its name does not matter.
        let vole = Connection(name: "Vigilant Vole", baseURL: URL(string: "https://v.example.com")!, kind: .vole)
        #expect(Connection.defaultName(kind: .wren, url: wren, existing: [vole]) == "Wise Wren")
        // A second one of the same product gets the host.
        let first = Connection(name: "Wise Wren", baseURL: wren, kind: .wren)
        #expect(Connection.defaultName(kind: .wren, url: other, existing: [first]) == "Wise Wren (wren2.example.com)")
        // An old connection named after its host shows the product name, so it counts as taken.
        let legacy = Connection(name: "wren.example.com", baseURL: wren, kind: .wren)
        #expect(Connection.defaultName(kind: .wren, url: other, existing: [legacy]) == "Wise Wren (wren2.example.com)")
    }

    @Test func displayNameShowsTheProductWhenTheNameIsTheHost() {
        let url = URL(string: "https://Wren.example.com")!
        #expect(Connection(name: "wren.example.com", baseURL: url, kind: .wren).displayName == "Wise Wren")
        #expect(Connection(name: "Tower Wren", baseURL: url, kind: .wren).displayName == "Tower Wren")
        #expect(Connection(name: "Wise Wren", baseURL: url, kind: .wren).displayName == "Wise Wren")
    }

    @Test func replaceTokenOverwritesOnlyTheVaultEntry() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let store = try makeStore(file: file, vault: vault, transport: try stub())
        let added = try await store.add(url: base, token: secret, name: nil)
        let before = try Data(contentsOf: file)

        try store.replaceToken(added.id, token: " vv_new_token\n")

        #expect(try vault.token(for: added.id) == "vv_new_token")
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func tokenChangesCountsSavesAndRemovalsButNotReads() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let store = try makeStore(file: file, vault: vault, transport: try stub())
        #expect(store.tokenChanges == 0)

        // Saving a token with a new connection counts.
        let added = try await store.add(url: base, token: secret, name: nil)
        let afterAdd = store.tokenChanges
        #expect(afterAdd > 0)

        // Reading, listing and checking a token change nothing.
        _ = try store.token(for: added.id)
        _ = try store.token(for: UUID())
        _ = store.connections
        try await store.verifyToken(secret, for: added.id)
        #expect(store.tokenChanges == afterAdd)

        // Replacing the token counts, also with the same token again.
        try store.replaceToken(added.id, token: "vv_new_token")
        let afterReplace = store.tokenChanges
        #expect(afterReplace > afterAdd)
        try store.replaceToken(added.id, token: "vv_new_token")
        #expect(store.tokenChanges > afterReplace)

        // A replacement that fails changes nothing.
        let beforeFailures = store.tokenChanges
        #expect(throws: HedgerowError.unauthorized) { try store.replaceToken(added.id, token: " ") }
        #expect(throws: ConnectionStoreError.unknownConnection) { try store.replaceToken(UUID(), token: "vv_x") }
        #expect(store.tokenChanges == beforeFailures)

        // Removing the connection removes the token, which counts.
        try store.remove(added.id)
        #expect(store.tokenChanges > beforeFailures)
    }

    @Test func tokenChangesDoesNotCountAnAddThatNeverSavedAToken() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let store = try makeStore(file: file, vault: InMemoryVault(), transport: try stub(accepted: "other"))

        await #expect(throws: (any Error).self) {
            try await store.add(url: base, token: secret, name: nil)
        }
        #expect(store.tokenChanges == 0)
    }

    @Test func verifyTokenChecksTheSavedConnectionAndStoresNothing() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let first = try makeStore(file: file, vault: vault, transport: try stub())
        let added = try await first.add(url: base, token: secret, name: nil)
        let before = try Data(contentsOf: file)

        // The server now knows the new token.
        let transport = try stub(accepted: "vv_new_token")
        let store = try makeStore(file: file, vault: vault, transport: transport)
        try await store.verifyToken(" vv_new_token\n", for: added.id)

        let last = try #require(transport.requests.last)
        #expect(last.url?.path == "/api/v1/monitors")
        #expect(last.value(forHTTPHeaderField: "Authorization") == "Bearer vv_new_token")
        #expect(try vault.token(for: added.id) == secret)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func verifyTokenRejectsATokenTheServerRefuses() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let ok = try makeStore(file: file, vault: vault, transport: try stub())
        let added = try await ok.add(url: base, token: secret, name: nil)

        for (status, expected) in [(401, HedgerowError.unauthorized), (403, .forbidden)] {
            let refusing = try makeStore(
                file: file, vault: vault, transport: try stub(viewerStatus: status, accepted: "vv_bad")
            )
            await #expect(throws: expected) {
                try await refusing.verifyToken("vv_bad", for: added.id)
            }
        }
        #expect(try vault.token(for: added.id) == secret)
    }

    @Test func verifyTokenForUnknownConnectionOrBlankTokenThrows() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let store = try makeStore(file: file, vault: InMemoryVault(), transport: try stub())
        let added = try await store.add(url: base, token: secret, name: nil)

        await #expect(throws: ConnectionStoreError.unknownConnection) {
            try await store.verifyToken("vv_x", for: UUID())
        }
        await #expect(throws: HedgerowError.unauthorized) {
            try await store.verifyToken("  ", for: added.id)
        }
    }

    @Test func replaceTokenWithBlankKeepsTheOldOne() async throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let store = try makeStore(file: file, vault: vault, transport: try stub())
        let added = try await store.add(url: base, token: secret, name: nil)

        #expect(throws: HedgerowError.unauthorized) {
            try store.replaceToken(added.id, token: " ")
        }
        #expect(try vault.token(for: added.id) == secret)
    }

    @Test func replaceTokenForUnknownConnectionThrows() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let vault = InMemoryVault()
        let store = try makeStore(file: file, vault: vault, transport: try stub())
        let id = UUID()

        #expect(throws: ConnectionStoreError.unknownConnection) {
            try store.replaceToken(id, token: "vv_x")
        }
        #expect(vault.isEmpty)
    }

    @Test func failedSaveToDiskLeavesNoTokenBehind() async throws {
        // The "directory" is really a file, so the connections file cannot be written.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgerow-tests-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let vault = InMemoryVault()
        let store = try makeStore(
            file: blocker.appendingPathComponent("connections.json"), vault: vault, transport: try stub()
        )

        await #expect(throws: (any Error).self) {
            try await store.add(url: base, token: secret, name: nil)
        }
        #expect(store.connections.isEmpty)
        #expect(vault.isEmpty)
    }

    @Test func corruptFileIsReportedNotOverwritten() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: file)

        #expect(throws: (any Error).self) {
            try makeStore(file: file, vault: InMemoryVault(), transport: try stub())
        }
        #expect(try Data(contentsOf: file) == Data("not json".utf8))
    }
}

#if canImport(Security)
@Suite struct KeychainVaultTests {
    @Test func savesReadsOverwritesAndDeletes() throws {
        let vault = KeychainVault(service: "tools.hedgerow.app.tests.\(UUID().uuidString)")
        let id = UUID()
        defer { try? vault.delete(for: id) }

        #expect(try vault.token(for: id) == nil)
        try vault.save("first", for: id)
        #expect(try vault.token(for: id) == "first")
        try vault.save("second", for: id)
        #expect(try vault.token(for: id) == "second")
        try vault.delete(for: id)
        #expect(try vault.token(for: id) == nil)
        try vault.delete(for: id) // deleting nothing is not an error
    }
}
#endif
