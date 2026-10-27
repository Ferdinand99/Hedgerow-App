import Foundation

/// Finds out which Hedgerow product, if any, answers at an address.
///
/// Every Hedgerow server (all built on vole-kit) requires a signed-in user for its OpenAPI
/// document, so the `HedgerowHTTP` given here must carry the token. 401 and 403 are therefore
/// answers about the token (`.unauthorized`, `.forbidden`); a 200 that is not a Hedgerow
/// document, a 404, or a refused redirect to a gateway's sign-in page is `.notHedgerow`.
public struct ServiceDetector: Sendable {
    /// Where every Hedgerow product serves its OpenAPI document (set by the shared vole-kit).
    public static let openAPIPath = "/api/v1/openapi.json"

    private let http: HedgerowHTTP

    /// - Parameter http: a client carrying the token to try. Only use it for an address that
    ///   passed `isAllowedBaseURL`.
    public init(http: HedgerowHTTP) {
        self.http = http
    }

    public func detect(_ base: URL) async throws -> ServiceKind {
        let data: Data
        do {
            data = try await http.getData(Self.openAPIPath, from: base)
        } catch HedgerowError.unreachable(let reason) {
            throw HedgerowError.unreachable(reason)
        } catch HedgerowError.insecureURL {
            throw HedgerowError.insecureURL
        } catch HedgerowError.unauthorized {
            throw HedgerowError.unauthorized
        } catch HedgerowError.forbidden {
            throw HedgerowError.forbidden
        } catch HedgerowError.badResponse(let status) where status >= 500 {
            throw HedgerowError.badResponse(status)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A refused redirect (a gateway's sign-in page), 404, other 4xx, too large:
            // whatever answers here is not a Hedgerow product.
            throw HedgerowError.notHedgerow
        }
        guard let document = try? JSONDecoder().decode(OpenAPIDocument.self, from: data),
              let kind = Self.kind(forTitle: document.info.title)
        else { throw HedgerowError.notHedgerow }
        return kind
    }

    /// The kit titles its documents "<Product> API"; accept the bare product name too.
    static func kind(forTitle title: String) -> ServiceKind? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ServiceKind.allCases.first { kind in
            let name = kind.productName.lowercased()
            return title == name || title.hasPrefix(name + " ")
        }
    }
}

private struct OpenAPIDocument: Decodable {
    struct Info: Decodable {
        let title: String
    }

    let openapi: String
    let info: Info
}
