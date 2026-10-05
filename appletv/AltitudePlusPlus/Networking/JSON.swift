import Foundation

/// Loosely-typed JSON for ViewLift responses whose shape varies by content
/// type and entitlement state.
enum JSON: Codable, Equatable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    /// The string value, or nil if missing or blank. ViewLift fills unused
    /// fields with " " rather than omitting them.
    var string: String? {
        guard case .string(let value) = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var array: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: JSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Depth-first search for the first value stored under `key`.
    func first(_ key: String) -> JSON? {
        switch self {
        case .object(let dict):
            if let hit = dict[key], hit != .null { return hit }
            for value in dict.values {
                if let hit = value.first(key) { return hit }
            }
            return nil
        case .array(let items):
            for item in items {
                if let hit = item.first(key) { return hit }
            }
            return nil
        default:
            return nil
        }
    }

    /// Pretty-printed JSON with secrets shortened, for the diagnostics screen.
    func redactedDescription() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(redacted()),
              let text = String(data: data, encoding: .utf8) else { return "<unencodable>" }
        return text
    }

    private static let secretKeys: Set<String> = [
        "licenseToken", "authorizationToken", "refreshToken", "token", "adbTempToken",
    ]

    private func redacted() -> JSON {
        switch self {
        case .object(let dict):
            var out: [String: JSON] = [:]
            for (key, value) in dict {
                if Self.secretKeys.contains(key), case .string(let secret) = value {
                    out[key] = .string(String(secret.prefix(8)) + "…(\(secret.count) chars)")
                } else if key == "plans" {
                    out[key] = .string("<omitted>")
                } else {
                    out[key] = value.redacted()
                }
            }
            return .object(out)
        case .array(let items):
            return .array(items.map { $0.redacted() })
        default:
            return self
        }
    }
}
