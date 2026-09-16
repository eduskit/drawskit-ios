import CoreGraphics
import UIKit

/// Scene-aligned dot grid geometry (matches web `@drawskit/renderer` / Android `DotGrid`).
enum DotGrid {
    static let baseSize: CGFloat = 20
    static let radiusPx: CGFloat = 0.9
    static let bgColor = UIColor(red: 0xFA / 255, green: 0xFA / 255, blue: 0xFA / 255, alpha: 1)
    static let dotColor = UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.14)

    static func effectiveStep(boardScale: CGFloat) -> CGFloat {
        let scale = boardScale > 0 ? boardScale : 1
        let screenSpacing = baseSize * scale
        if screenSpacing >= 12 { return baseSize }
        return baseSize * ceil(12 / screenSpacing)
    }

    static func forEachScreenPoint(
        width: CGFloat,
        height: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat,
        boardScale: CGFloat,
        visit: (_ sx: CGFloat, _ sy: CGFloat) -> Void
    ) {
        let scale = boardScale > 0 ? boardScale : 1
        let step = effectiveStep(boardScale: scale)
        let inv = 1 / scale
        let left = -offsetX * inv
        let top = -offsetY * inv
        let right = (width - offsetX) * inv
        let bottom = (height - offsetY) * inv
        let startX = floor(left / step) * step
        let startY = floor(top / step) * step
        var x = startX
        while x <= right + 1e-6 {
            var y = startY
            while y <= bottom + 1e-6 {
                visit(x * scale + offsetX, y * scale + offsetY)
                y += step
            }
            x += step
        }
    }
}
