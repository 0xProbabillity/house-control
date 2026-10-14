import Foundation

/// Any JSON value, for the parts of a plan that are passed through rather than read
/// (a scene's settings, a device's links).
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// The value as `JSONSerialization` gives it.
    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    public init?(any value: Any) {
        switch value {
        case is NSNull: self = .null
        // A JSONSerialization boolean is an NSNumber too: tell them apart by its type.
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let b as Bool: self = .bool(b)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.compactMap(JSONValue.init(any:)))
        case let o as [String: Any]: self = .object(o.compactMapValues(JSONValue.init(any:)))
        default: return nil
        }
    }

    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var number: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var isNull: Bool { self == .null }
}
