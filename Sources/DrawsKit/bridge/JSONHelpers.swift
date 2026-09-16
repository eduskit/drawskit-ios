import Foundation

enum JSONCodec {
    static func stringify(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parseObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String, default defaultValue: String = "") -> String {
        (self[key] as? String) ?? defaultValue
    }

    func double(_ key: String, default defaultValue: Double = 0) -> Double {
        if let v = self[key] as? Double { return v }
        if let v = self[key] as? Int { return Double(v) }
        if let v = self[key] as? NSNumber { return v.doubleValue }
        return defaultValue
    }

    func int(_ key: String, default defaultValue: Int = 0) -> Int {
        if let v = self[key] as? Int { return v }
        if let v = self[key] as? Double { return Int(v) }
        if let v = self[key] as? NSNumber { return v.intValue }
        return defaultValue
    }

    func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        if let v = self[key] as? Bool { return v }
        if let v = self[key] as? NSNumber { return v.boolValue }
        return defaultValue
    }

    func dict(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func array(_ key: String) -> [Any]? {
        self[key] as? [Any]
    }

    func isNull(_ key: String) -> Bool {
        self[key] is NSNull || self[key] == nil
    }
}

/// Coerce JSON-like `Any` values from Swift dictionaries (Int) or JSON (NSNumber).
enum JSONCoerce {
    static func int(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let v = value as? Int { return v }
        if let v = value as? NSNumber { return v.intValue }
        if let v = value as? Double { return Int(v) }
        if let v = value as? Float { return Int(v) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let v = value as? Bool { return v }
        if let v = value as? NSNumber { return v.boolValue }
        return nil
    }
}

extension Array where Element == Any {
    func dict(at index: Int) -> [String: Any]? {
        guard index >= 0, index < count else { return nil }
        return self[index] as? [String: Any]
    }

    func string(at index: Int, default defaultValue: String = "") -> String {
        guard index >= 0, index < count else { return defaultValue }
        return (self[index] as? String) ?? defaultValue
    }
}
