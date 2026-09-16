import UIKit

/// Renderer visual defaults (selection, laser, arrow, rough).
/// Keep in sync with Web `renderDefaults.ts` and Android `RenderDefaults`.
enum RenderDefaults {
    /// Matches Rust `defaults::DEFAULT_STROKE_COLOR` / Excalidraw black.
    static let defaultStrokeColor = "#1e1e1e"
    static let defaultStrokeWidth: CGFloat = 2
    static let laserGlowStopMidOffset: CGFloat = 0.45
    static let previewAlphaFactor: CGFloat = 0.65
    static let selectionBoxStrokeColor = "#0066ff"
    static let selectionBoxLineWidth: CGFloat = 1
    static let selectionBoxDash: [CGFloat] = [4, 4]
    static let defaultLaserRadius: CGFloat = 6
    static let laserGlowRadiusFactor: CGFloat = 2.2
    static let laserCoreColor = "#ff3333"
    static let laserGlowA0: CGFloat = 242.0 / 255.0
    static let laserGlowA1: CGFloat = 89.0 / 255.0
    static let laserGlowA2: CGFloat = 0
    static let laserGlowR: CGFloat = 255.0 / 255.0
    static let laserGlowG: CGFloat = 60.0 / 255.0
    static let laserGlowB: CGFloat = 60.0 / 255.0
    static let arrowHeadLenFactor: CGFloat = 3
    static let arrowHeadMinLen: CGFloat = 8
    static let arrowHeadAngle = CGFloat.pi / 6
    static let defaultPageWidth: CGFloat = 1280
    static let defaultPageHeight: CGFloat = 720
    static let defaultFontSizePx: CGFloat = 16
    static let roughCornerRadiusFactor: Float = 0.25
    static let hachureGapFactor: CGFloat = 4
    static let dottedDashThreshold: CGFloat = 3
    static let overlayTypeSelectionBox = "selection_box"
    static let overlayTypeLaserPointer = "laser_pointer"
    /// `RenderMessage.render_message_type` carrying no document change.
    static let renderMessageTransient = "transient"
    static let renderLayerCourseware = "courseware"
    static let renderLayerShapes = "shapes"
    static let renderLayerPreview = "preview"
    static let renderLayerOverlay = "overlay"
    static let pressureWidthBase: CGFloat = 0.35
    static let pressureWidthSpan: CGFloat = 0.65
    static let minPressureWidthFactor: CGFloat = 0.5

    static var selectionBoxStrokeUIColor: UIColor {
        UIColor(hex: selectionBoxStrokeColor) ?? UIColor(red: 0, green: 0.4, blue: 1, alpha: 1)
    }

    static var laserCoreUIColor: UIColor {
        UIColor(hex: laserCoreColor) ?? UIColor(red: laserGlowR, green: laserGlowG, blue: laserGlowB, alpha: 1)
    }
}

private extension UIColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let raw = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((raw >> 16) & 0xFF) / 255,
            green: CGFloat((raw >> 8) & 0xFF) / 255,
            blue: CGFloat(raw & 0xFF) / 255,
            alpha: 1
        )
    }
}
