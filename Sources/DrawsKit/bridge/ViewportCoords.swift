import UIKit

@_silgen_name("wb_contain_viewport")
private func wb_contain_viewport(
    _ sourceWidth: Float,
    _ sourceHeight: Float,
    _ destWidth: Float,
    _ destHeight: Float,
    _ outX: UnsafeMutablePointer<Float>?,
    _ outY: UnsafeMutablePointer<Float>?,
    _ outWidth: UnsafeMutablePointer<Float>?,
    _ outHeight: UnsafeMutablePointer<Float>?
)

/// Placement returned by Core. Callers apply this rect; they do not recompute the scale.
struct ContainedViewport {
    var x: Float
    var y: Float
    var width: Float
    var height: Float
}

enum ViewportPlacement {
    static func contain(
        sourceWidth: Float,
        sourceHeight: Float,
        destWidth: Float,
        destHeight: Float
    ) -> ContainedViewport {
        var x: Float = 0
        var y: Float = 0
        var width: Float = 0
        var height: Float = 0
        wb_contain_viewport(
            sourceWidth,
            sourceHeight,
            destWidth,
            destHeight,
            &x,
            &y,
            &width,
            &height
        )
        return ContainedViewport(x: x, y: y, width: width, height: height)
    }

    static func viewPointToSource(
        viewX: Float,
        viewY: Float,
        placed: ContainedViewport,
        sourceWidth: Float,
        sourceHeight: Float
    ) -> (Float, Float) {
        guard placed.width > 0, placed.height > 0, sourceWidth > 0, sourceHeight > 0 else {
            return (viewX, viewY)
        }
        return (
            (viewX - placed.x) / placed.width * sourceWidth,
            (viewY - placed.y) / placed.height * sourceHeight
        )
    }

    static func sourcePointToView(
        sourceX: Float,
        sourceY: Float,
        placed: ContainedViewport,
        sourceWidth: Float,
        sourceHeight: Float
    ) -> (Float, Float) {
        guard placed.width > 0, placed.height > 0, sourceWidth > 0, sourceHeight > 0 else {
            return (sourceX, sourceY)
        }
        return (
            placed.x + sourceX / sourceWidth * placed.width,
            placed.y + sourceY / sourceHeight * placed.height
        )
    }
}

enum ViewportCoords {
    struct Transform {
        let offsetX: Float
        let offsetY: Float
        let scale: Int
        let contentOffsetX: Float
        let contentOffsetY: Float
        let contentScale: Float
    }

    struct ContentTransform {
        let offsetX: Float
        let offsetY: Float
        let scale: Float
    }

    /// UIKit `draw(_:)` uses point coordinates (≈ Web CSS px). Unlike Android physical px / density,
    /// logical canvas size equals view bounds in points; viewport `dpr` is 1 for stroke width alignment.
    static func density(view: UIView?) -> Float {
        _ = view
        return 1
    }

    static func touchToScreen(view: UIView?, x: CGFloat, y: CGFloat) -> (Float, Float) {
        _ = view
        return (Float(x), Float(y))
    }

    static func logicalSize(view: UIView?) -> (Int, Int) {
        guard let view else { return (1, 1) }
        let w = max(Int(view.bounds.width), 1)
        let h = max(Int(view.bounds.height), 1)
        return (w, h)
    }

    static func transform(frame: [String: Any]?) -> Transform {
        let vp = frame?.dict("viewport")
        let content = contentTransform(frame: frame)
        return Transform(
            offsetX: Float(vp?.double("offset_x") ?? 0),
            offsetY: Float(vp?.double("offset_y") ?? 0),
            scale: vp?.int("scale", default: 100) ?? 100,
            contentOffsetX: content?.offsetX ?? 0,
            contentOffsetY: content?.offsetY ?? 0,
            contentScale: content?.scale ?? 1
        )
    }

    /// Core-emitted contain-fit. Platforms must not recompute page fit.
    static func contentTransform(frame: [String: Any]?) -> ContentTransform? {
        guard let content = frame?.dict("content") else { return nil }
        let scale = Float(content.double("scale"))
        let width = Float(content.double("width"))
        let height = Float(content.double("height"))
        guard scale > 0, width > 0, height > 0 else { return nil }
        return ContentTransform(
            offsetX: Float(content.double("offset_x")),
            offsetY: Float(content.double("offset_y")),
            scale: scale
        )
    }

    static func screenToWorld(screenX: Float, screenY: Float, transform: Transform) -> (Float, Float) {
        let fitted = PlatformEvents.screenToWorld(
            screenX: screenX,
            screenY: screenY,
            offsetX: transform.offsetX,
            offsetY: transform.offsetY,
            scalePercent: transform.scale
        )
        return (
            (fitted.0 - transform.contentOffsetX) / transform.contentScale,
            (fitted.1 - transform.contentOffsetY) / transform.contentScale
        )
    }

    static func worldToScreen(worldX: Float, worldY: Float, transform: Transform) -> (Float, Float) {
        PlatformEvents.worldToScreen(
            worldX: worldX * transform.contentScale + transform.contentOffsetX,
            worldY: worldY * transform.contentScale + transform.contentOffsetY,
            offsetX: transform.offsetX,
            offsetY: transform.offsetY,
            scalePercent: transform.scale
        )
    }

    static func screenToViewPixels(view: UIView?, screenX: Float, screenY: Float) -> (CGFloat, CGFloat) {
        _ = view
        return (CGFloat(screenX), CGFloat(screenY))
    }

    struct ScreenRect {
        let x: Float
        let y: Float
        let width: Float
        let height: Float
    }

    static func mediaSlotToScreen(
        frame: [String: Any]?,
        slot: [String: Any],
        layer: [String: Any]?
    ) -> ScreenRect? {
        let transform = transform(frame: frame)
        let layerTf = layer?.dict("transform")
        let translateX = Float(layerTf?.double("translate_x") ?? 0)
        let translateY = Float(layerTf?.double("translate_y") ?? 0)
        let layerScale = Float(layerTf?.double("scale") ?? 1)
        let pageX = translateX + Float(slot.double("x")) * layerScale
        let pageY = translateY + Float(slot.double("y")) * layerScale
        let pageW = Float(slot.double("width")) * layerScale
        let pageH = Float(slot.double("height")) * layerScale
        let origin = worldToScreen(worldX: pageX, worldY: pageY, transform: transform)
        let corner = worldToScreen(worldX: pageX + pageW, worldY: pageY + pageH, transform: transform)
        return ScreenRect(x: origin.0, y: origin.1, width: corner.0 - origin.0, height: corner.1 - origin.1)
    }

    static func sceneRectToScreen(
        frame: [String: Any]?,
        x: Float,
        y: Float,
        width: Float,
        height: Float
    ) -> ScreenRect {
        let transform = transform(frame: frame)
        let origin = worldToScreen(worldX: x, worldY: y, transform: transform)
        let corner = worldToScreen(worldX: x + width, worldY: y + height, transform: transform)
        return ScreenRect(x: origin.0, y: origin.1, width: corner.0 - origin.0, height: corner.1 - origin.1)
    }
}
