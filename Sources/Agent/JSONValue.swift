import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Decimal), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let b = try? value.decode(Bool.self) { self = .bool(b) }
        else if let s = try? value.decode(String.self) { self = .string(s) }
        else if let n = try? value.decode(Decimal.self) { self = .number(n) }
        else if let o = try? value.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let o): try value.encode(o); case .array(let a): try value.encode(a)
        case .string(let s): try value.encode(s); case .number(let n): try value.encode(n)
        case .bool(let b): try value.encode(b); case .null: try value.encodeNil()
        }
    }
    subscript(_ key: String) -> JSONValue { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var decimal: Decimal? { if case .number(let n) = self { return n }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}

enum AgentError: Error, Equatable {
    case invalidConfiguration, invalidMessage, unavailable, timeout, closed, busy, cancelled, provider(Int)
}
