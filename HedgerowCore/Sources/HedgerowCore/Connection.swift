import Foundation

/// The Hedgerow products the app can talk to.
public enum ServiceKind: String, Codable, Sendable, CaseIterable {
    case vole
    case kestrel
    case wren

    /// The product name as it appears in the `info.title` of its OpenAPI document.
    var productName: String {
        switch self {
        case .vole: "Vigilant Vole"
        case .kestrel: "Keen Kestrel"
        case .wren: "Wise Wren"
        }
    }
}

/// One saved service: a name, where it lives and which product it is.
/// The token is never part of this value; it lives in the Keychain.
public struct Connection: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: URL
    public var kind: ServiceKind

    public init(id: UUID = UUID(), name: String, baseURL: URL, kind: ServiceKind) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.kind = kind
    }
}
