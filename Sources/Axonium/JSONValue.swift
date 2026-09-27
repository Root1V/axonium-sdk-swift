import Foundation

/// A decoded JSON value.
///
/// Exists because the public error type has to carry the response body verbatim — a field this
/// SDK does not model must stay reachable, which is the whole reason the other three SDKs keep a
/// `raw` — and `[String: Any]` cannot be `Sendable` or `Hashable`. Under Swift 6 strict
/// concurrency that is not a style preference: an `Any` in a public error would make the error
/// unsendable and unusable across an actor boundary, which is exactly where errors travel.
///
/// It also removes an `Any?` from the public surface. `error.backendError?["detail"]` reads
/// better than a cast.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Wraps the output of `JSONSerialization`, which is where every body in this SDK comes from.
    public init(_ value: Any) {
        switch value {
        case let v as String: self = .string(v)
        case let v as Bool where type(of: value) == type(of: true): self = .bool(v)
        case let v as NSNumber:
            // NSNumber does not distinguish a JSON `true` from a JSON `1` by type alone; its
            // objCType does. Getting this wrong would turn every boolean in a body into 1 or 0.
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else {
                self = .number(v.doubleValue)
            }
        case let v as [Any]: self = .array(v.map(JSONValue.init))
        case let v as [String: Any]: self = .object(v.mapValues(JSONValue.init))
        default: self = .null
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var intValue: Int? {
        if case .number(let v) = self { return Int(v) }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let v) = self { return v }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
}
