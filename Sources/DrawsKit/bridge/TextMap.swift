import Foundation

/// Parsed Rust `TextEditHit` (snake_case JSON).
struct TextEditHit {
    let id: String
    let content: String
    let x: Float
    let y: Float
    let fontSize: Float
    let fontFamily: String
    let color: String?
    let bold: Bool
    let italic: Bool
    let lineHeight: Float
}

enum TextMap {
    /// Overlay sizing for new text; hit-edit uses Rust `font_size`.
    static func textSizeToFontSize(_ size: Int) -> Float {
        Float(max(
            EngineDefaults.minFontSizePx,
            min(Float(size) / EngineDefaults.textSizeToPxDivisor, EngineDefaults.maxFontSizePx)
        ))
    }

    static func textStyleFlags(_ style: Int) -> (Bool, Bool) {
        switch style {
        case 1: return (true, false)
        case 2: return (false, true)
        case 3: return (true, true)
        default: return (false, false)
        }
    }

    static func parseTextEditHit(_ json: String?) -> TextEditHit? {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let id = obj["id"] as? String ?? ""
        guard !id.isEmpty else { return nil }
        return TextEditHit(
            id: id,
            content: obj["content"] as? String ?? "",
            x: Float((obj["x"] as? NSNumber)?.doubleValue ?? 0),
            y: Float((obj["y"] as? NSNumber)?.doubleValue ?? 0),
            fontSize: Float((obj["font_size"] as? NSNumber)?.doubleValue ?? 16),
            fontFamily: obj["font_family"] as? String ?? EngineDefaults.defaultFontFamily,
            color: obj["color"] as? String,
            bold: (obj["bold"] as? Bool) ?? false,
            italic: (obj["italic"] as? Bool) ?? false,
            lineHeight: Float((obj["line_height"] as? NSNumber)?.doubleValue ?? 1)
        )
    }
}
