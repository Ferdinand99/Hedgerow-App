import Foundation

/// Turns what a person typed into a base URL for a service: surrounding spaces are dropped
/// and a missing scheme becomes `https://`. Returns `nil` for anything that cannot be a service
/// address (no host, a query or fragment, or a scheme other than http/https).
/// Whether the address is *allowed* (https, or http on a LAN) is `isAllowedBaseURL`'s call.
public func parseServiceAddress(_ input: String) -> URL? {
    var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
    if !text.contains("://") { text = "https://" + text }
    while text.hasSuffix("/") { text.removeLast() }
    guard let url = URL(string: text),
          let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
          let host = url.host, !host.isEmpty,
          url.query == nil, url.fragment == nil
    else { return nil }
    return url
}
