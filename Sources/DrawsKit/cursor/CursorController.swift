import UIKit

#if targetEnvironment(macCatalyst)
import AppKit
#endif

/// Local host cursor resolver (platform I/O).
/// - Mac Catalyst: custom / system `NSCursor`
/// - iPadOS pointer: `UIPointerInteraction` styles (no arbitrary PNG mouse cursor)
final class CursorController: NSObject {
    struct IconSpec {
        var image: UIImage?
        var hotspot: CGPoint
    }

    private var toolType: Int = DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_PEN
    private var drawEnabled = true
    private var panDragging = false
    private var systemCursorEnable = true
    private var customByTool: [Int: IconSpec] = [:]
    private var zoomCursorIcon: IconSpec?
    private var defaultImages: [String: (UIImage, CGPoint)] = [:]
    private weak var hostView: DrawsKitView?
    private var pointerInteraction: AnyObject?

    override init() {
        super.init()
        loadDefaults()
    }

    func attach(to view: DrawsKitView) {
        hostView = view
        if #available(iOS 13.4, *) {
            let interaction = UIPointerInteraction(delegate: self)
            view.addInteraction(interaction)
            pointerInteraction = interaction
        }
        apply()
    }

    func detach() {
        if #available(iOS 13.4, *),
           let interaction = pointerInteraction as? UIPointerInteraction,
           let view = hostView {
            view.removeInteraction(interaction)
        }
        pointerInteraction = nil
        hostView = nil
        #if targetEnvironment(macCatalyst)
        NSCursor.arrow.set()
        #endif
    }

    func setToolType(_ toolType: Int) {
        self.toolType = toolType
        apply()
    }

    func setDrawEnabled(_ enable: Bool) {
        drawEnabled = enable
        apply()
    }

    func setPanDragging(_ dragging: Bool) {
        panDragging = dragging
        apply()
    }

    func setSystemCursorEnable(_ enable: Bool) {
        systemCursorEnable = enable
        apply()
    }

    func setCursorIcon(toolType: Int, icon: Any?) {
        if icon == nil {
            customByTool.removeValue(forKey: toolType)
        } else if let spec = parseIcon(icon) {
            customByTool[toolType] = spec
        }
        apply()
    }

    func setZoomCursorIcon(_ icon: Any?) {
        zoomCursorIcon = icon == nil ? nil : parseIcon(icon)
        apply()
    }

    func apply() {
        #if targetEnvironment(macCatalyst)
        applyMacCursor()
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private func applyMacCursor() {
        guard systemCursorEnable else {
            NSCursor.arrow.set()
            return
        }
        if !drawEnabled {
            NSCursor.operationNotAllowed.set()
            return
        }
        let kind = ToolMap.toolTypeToKind(toolType)
        if kind == "pan" && panDragging {
            NSCursor.closedHand.set()
            return
        }
        if kind == "pan", let zoom = zoomCursorIcon, let image = zoom.image {
            NSCursor(image: image, hotSpot: zoom.hotspot).set()
            return
        }
        if let custom = customByTool[toolType], let image = custom.image {
            NSCursor(image: image, hotSpot: custom.hotspot).set()
            return
        }
        if let key = assetKey(for: kind), let def = defaultImages[key] {
            NSCursor(image: def.0, hotSpot: def.1).set()
            return
        }
        switch kind {
        case "text": NSCursor.iBeam.set()
        case "laser": NSCursor.pointingHand.set()
        case "pan": NSCursor.openHand.set()
        case "select": NSCursor.arrow.set()
        default: NSCursor.crosshair.set()
        }
    }
    #endif

    private func assetKey(for kind: String?) -> String? {
        switch kind {
        case "pen": return "pen"
        case "highlighter": return "highlighter"
        case "eraser": return "eraser"
        case "pan": return "pan"
        case "text": return "text"
        default: return nil
        }
    }

    private func loadDefaults() {
        let mapping: [(String, String)] = [
            ("pen", "cursor-pen.png"),
            ("highlighter", "cursor-hightlight.png"),
            ("eraser", "cursor-eraser.png"),
            ("pan", "cursor-move.png"),
            ("text", "cursor-txt.png"),
        ]
        let hotspots = loadHotspots()
        for (key, file) in mapping {
            guard let image = loadImage(named: file) else { continue }
            let hs = hotspots[key] ?? CGPoint(x: image.size.width / 2, y: image.size.height / 2)
            defaultImages[key] = (image, hs)
        }
    }

    private func loadHotspots() -> [String: CGPoint] {
        guard let url = resourceURL(named: "hotspots", ext: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: CGPoint] = [:]
        for (key, value) in obj {
            guard let meta = value as? [String: Any],
                  let arr = meta["hotspot"] as? [Any],
                  arr.count >= 2
            else { continue }
            let x = (arr[0] as? NSNumber)?.doubleValue ?? 0
            let y = (arr[1] as? NSNumber)?.doubleValue ?? 0
            out[key] = CGPoint(x: x, y: y)
        }
        return out
    }

    private func loadImage(named file: String) -> UIImage? {
        let base = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        if let url = resourceURL(named: base, ext: ext),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            return image
        }
        return UIImage(named: base)
    }

    private func resourceURL(named name: String, ext: String) -> URL? {
        let bundle = Bundle(for: CursorController.self)
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Cursors") {
            return url
        }
        if let resourceBundleURL = bundle.url(forResource: "DrawsKitCursors", withExtension: "bundle"),
           let resourceBundle = Bundle(url: resourceBundleURL) {
            return resourceBundle.url(forResource: name, withExtension: ext, subdirectory: "Cursors")
                ?? resourceBundle.url(forResource: name, withExtension: ext)
        }
        return bundle.url(forResource: name, withExtension: ext)
    }

    private func parseIcon(_ icon: Any?) -> IconSpec? {
        guard let icon else { return nil }
        if let image = icon as? UIImage {
            return IconSpec(image: image, hotspot: CGPoint(x: image.size.width / 2, y: image.size.height / 2))
        }
        if let dict = icon as? [String: Any] {
            var hotspot = CGPoint.zero
            if let arr = dict["hotspot"] as? [Any], arr.count >= 2 {
                let x = (arr[0] as? NSNumber)?.doubleValue ?? 0
                let y = (arr[1] as? NSNumber)?.doubleValue ?? 0
                hotspot = CGPoint(x: x, y: y)
            }
            if let image = dict["image"] as? UIImage {
                return IconSpec(image: image, hotspot: hotspot)
            }
            if let name = dict["name"] as? String, let image = UIImage(named: name) {
                return IconSpec(image: image, hotspot: hotspot)
            }
        }
        return nil
    }
}

@available(iOS 13.4, *)
extension CursorController: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        if !systemCursorEnable || !drawEnabled {
            return .hidden()
        }
        let kind = ToolMap.toolTypeToKind(toolType)
        if kind == "text" {
            return UIPointerStyle(shape: .verticalBeam(length: 24), constrainedAxes: [])
        }
        if kind == "select" {
            return nil
        }
        // Drawing / pan / laser: request a precise pointer (crosshair-like).
        let path = UIBezierPath(ovalIn: CGRect(x: -1, y: -8, width: 2, height: 16))
        path.append(UIBezierPath(ovalIn: CGRect(x: -8, y: -1, width: 16, height: 2)))
        return UIPointerStyle(shape: .path(path), constrainedAxes: [])
    }
}
