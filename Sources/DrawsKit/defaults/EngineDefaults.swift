import UIKit

/// Engine / SDK defaults.
/// Engine literals come from `EngineDefaultsGenerated` (Rust `defaults.rs`).
/// UI-only fields below are platform-local.
enum EngineDefaults {
    static let industryUnitMax = EngineDefaultsGenerated.industryUnitMax
    static let defaultStrokeColor = EngineDefaultsGenerated.defaultStrokeColor
    static let defaultBrushColor = EngineDefaultsGenerated.defaultBrushColor
    static let defaultHighlighterColor = EngineDefaultsGenerated.defaultHighlighterColor
    static let defaultGraphColor = EngineDefaultsGenerated.defaultGraphColor
    static let defaultFontFamily = EngineDefaultsGenerated.defaultFontFamily
    static let defaultBoardRatio = EngineDefaultsGenerated.defaultBoardRatio
    static let defaultStrokeWidth = EngineDefaultsGenerated.defaultStrokeWidth
    static let defaultEraserSize = Double(EngineDefaultsGenerated.defaultEraserSize)
    static let defaultLaserSize = Double(EngineDefaultsGenerated.defaultLaserSize)
    static let defaultGraphThin = Double(EngineDefaultsGenerated.defaultGraphThin)
    static let defaultBrushThin = Int(EngineDefaultsGenerated.defaultBrushThin)
    static let defaultTextIndustrySize = EngineDefaultsGenerated.defaultTextIndustrySize
    static let textSizeToPxDivisor = EngineDefaultsGenerated.textSizeToPxDivisor
    static let minFontSizePx = EngineDefaultsGenerated.minFontSizePx
    static let maxFontSizePx = EngineDefaultsGenerated.maxFontSizePx
    static let textCharWidthFactor = EngineDefaultsGenerated.textCharWidthFactor
    static let textLineHeightExtra = EngineDefaultsGenerated.textLineHeightExtra
    static let defaultTextLineHeight = EngineDefaultsGenerated.defaultTextLineHeight
    static let defaultBoardScale = EngineDefaultsGenerated.defaultBoardScale
    static let defaultScaleMin = EngineDefaultsGenerated.defaultScaleMin
    static let defaultScaleMax = EngineDefaultsGenerated.defaultScaleMax
    static let defaultPageWidth = CGFloat(EngineDefaultsGenerated.defaultPageWidth)
    static let defaultPageHeight = CGFloat(EngineDefaultsGenerated.defaultPageHeight)
    static let coursewareRenderModeStaticImage =
        EngineDefaultsGenerated.coursewareRenderModeStaticImage
    static let coursewareRenderModeWebview = EngineDefaultsGenerated.coursewareRenderModeWebview
    static let coursewareSourceTypeImage = EngineDefaultsGenerated.coursewareSourceTypeImage

    /// Platform-only until board background is engine-backed.
    static let defaultBackgroundColor = "#ffffff"
    /// Includes cloud session + history bootstrap HTTP.
    static let engineBootstrapTimeoutMs: Int64 = 30_000
    static var engineBootstrapTimeout: TimeInterval {
        TimeInterval(engineBootstrapTimeoutMs) / 1000
    }

    // Text edit — matches Web rgba(255,255,255,0.92) / Android argb(235,255,255,255)
    static let textEditBgColor = UIColor(white: 1, alpha: 235.0 / 255.0)
    static let textEditMinWidth: CGFloat = 120
    static let textEditBaseWidth: CGFloat = 200
    static let textEditMinHeightBase: CGFloat = 32
    static let textEditMinHeightFactor: CGFloat = 1.5

    // Courseware loading — matches Web rgba(15, 23, 42, 0.35)
    static let coursewareLoadingDimColor = UIColor(
        red: 15.0 / 255.0,
        green: 23.0 / 255.0,
        blue: 42.0 / 255.0,
        alpha: 0.35
    )
    static let coursewareLoadingFontSize: CGFloat = 14

    // Cloud bootstrap loading — matches Web BOOTSTRAP_LOADING_*
    static let bootstrapLoadingDimColor = coursewareLoadingDimColor
    static let bootstrapLoadingFontSize: CGFloat = coursewareLoadingFontSize
    static let bootstrapLoadingMessage = "白板加载中…"

    // Bootstrap error overlay — matches Android EngineDefaults.BOOTSTRAP_ERROR_*
    static let bootstrapErrorDimColor = UIColor(
        red: 15.0 / 255.0,
        green: 23.0 / 255.0,
        blue: 42.0 / 255.0,
        alpha: 240.0 / 255.0
    )
    static let bootstrapErrorMessageColor = UIColor(
        red: 226.0 / 255.0,
        green: 232.0 / 255.0,
        blue: 240.0 / 255.0,
        alpha: 1
    )
    static let bootstrapErrorTitleFontSize: CGFloat = 16
    static let bootstrapErrorMessageFontSize: CGFloat = 13
    static let bootstrapErrorTitle = "白板初始化失败"
    static let bootstrapErrorFallbackMessage = "请稍后重试"
}
