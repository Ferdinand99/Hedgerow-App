import Foundation

/// How a service is doing, for the colour of its card.
public enum Health: Sendable, Equatable {
    case ok, warning, critical, unknown
}

/// One argument of a `SummaryLine`.
public enum SummaryArgument: Sendable, Equatable {
    case number(Int)
    case text(String)

    var rendered: String {
        switch self {
        case .number(let value): String(value)
        case .text(let value): value
        }
    }
}

/// A line of text on a card, kept as a String Catalog key plus arguments so the app
/// can translate it without parsing English.
///
/// `key` is the English text with printf placeholders (`%lld` for `.number`, `%@` for
/// `.text`, positional `%1$@` when a line has several). The app looks the key up in its
/// String Catalog and formats it with `arguments`; `text` is the English rendering, used
/// as the fallback and in tests.
public struct SummaryLine: Sendable, Equatable {
    public let key: String
    public let arguments: [SummaryArgument]

    public init(_ key: String, _ arguments: SummaryArgument...) {
        self.key = key
        self.arguments = arguments
    }

    /// The English rendering of `key` with `arguments` filled in.
    public var text: String {
        var output = ""
        var nextIndex = 0
        var iterator = key.makeIterator()
        var pending = iterator.next()
        while let character = pending {
            guard character == "%" else {
                output.append(character)
                pending = iterator.next()
                continue
            }
            // %% | %lld | %@ | %n$lld | %n$@
            var digits = ""
            var next = iterator.next()
            while let digit = next, digit.isASCII, digit.isNumber {
                digits.append(digit)
                next = iterator.next()
            }
            if !digits.isEmpty, next == "$" {
                next = iterator.next()
            } else if !digits.isEmpty {
                // Digits without `$`: not a placeholder; keep them as written.
                output.append("%" + digits)
                pending = next
                continue
            }
            let position = Int(digits).map { $0 - 1 }
            if next == "%" {
                output.append("%")
                pending = iterator.next()
            } else if next == "@" {
                output.append(argument(at: position ?? nextIndex))
                if position == nil { nextIndex += 1 }
                pending = iterator.next()
            } else if next == "l" {
                // `lld`
                _ = iterator.next()
                _ = iterator.next()
                output.append(argument(at: position ?? nextIndex))
                if position == nil { nextIndex += 1 }
                pending = iterator.next()
            } else {
                output.append("%" + digits)
                pending = next
            }
        }
        return output
    }

    /// The arguments as C varargs, for `String(format:)` with the translated key.
    public var formatArguments: [CVarArg] {
        arguments.map { argument in
            switch argument {
            case .number(let value): value as CVarArg
            case .text(let value): value as NSString
            }
        }
    }

    private func argument(at index: Int) -> String {
        arguments.indices.contains(index) ? arguments[index].rendered : ""
    }
}

/// What one card on the Overview shows.
public struct ServiceSummary: Sendable, Equatable {
    public let kind: ServiceKind
    public let health: Health
    public let headline: SummaryLine
    /// At most `ServiceSummary.maxDetails` lines, however large the installation is.
    public let details: [SummaryLine]
    public let fetchedAt: Date

    /// Review Focus 4: a big installation is summarised, never listed.
    public static let maxDetails = 5

    public init(kind: ServiceKind, health: Health, headline: SummaryLine, details: [SummaryLine], fetchedAt: Date) {
        self.kind = kind
        self.health = health
        self.headline = headline
        self.details = Array(details.prefix(Self.maxDetails))
        self.fetchedAt = fetchedAt
    }
}

public protocol ServiceClient: Sendable {
    func summary() async throws -> ServiceSummary
}

/// The client for a saved connection.
public func makeClient(for connection: Connection, token: String?) -> any ServiceClient {
    let http = HedgerowHTTP(token: token)
    switch connection.kind {
    case .vole: return VoleClient(baseURL: connection.baseURL, http: http)
    case .kestrel: return KestrelClient(baseURL: connection.baseURL, http: http)
    case .wren: return WrenClient(baseURL: connection.baseURL, http: http)
    }
}

// MARK: - Shared helpers

extension HedgerowHTTP {
    /// GET and decode, where a body that does not fit the expected shape is
    /// `HedgerowError.unexpectedResponse` (a 200 with the wrong content), not a crash.
    func getDecoded<T: Decodable>(_ type: T.Type, _ path: String, from base: URL) async throws -> T {
        let data = try await getData(path, from: base)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HedgerowError.unexpectedResponse
        }
    }
}

/// Server timestamps: `YYYY-MM-DD HH:MM:SS` in UTC (all three products), or RFC 3339.
func parseServerTimestamp(_ string: String?) -> Date? {
    guard let string else { return nil }
    let values = string.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
    if values.count == 6, !string.contains("T") {
        var components = DateComponents()
        components.year = values[0]
        components.month = values[1]
        components.day = values[2]
        components.hour = values[3]
        components.minute = values[4]
        components.second = values[5]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: string) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string)
}

/// Runs `transform` on every item with at most `limit` in flight; results keep the input order.
func boundedMap<Item: Sendable, Result: Sendable>(
    _ items: [Item], limit: Int, _ transform: @escaping @Sendable (Item) async throws -> Result
) async throws -> [Result] {
    try await withThrowingTaskGroup(of: (Int, Result).self) { group in
        var results = [Result?](repeating: nil, count: items.count)
        var next = 0
        func addNext() {
            guard next < items.count else { return }
            let index = next
            let item = items[index]
            next += 1
            group.addTask { (index, try await transform(item)) }
        }
        for _ in 0..<min(limit, items.count) { addNext() }
        while let (index, result) = try await group.next() {
            results[index] = result
            addNext()
        }
        return results.compactMap { $0 }
    }
}
