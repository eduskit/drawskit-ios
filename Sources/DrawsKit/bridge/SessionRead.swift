import Foundation

enum SessionRead {
    private static func tool(_ frame: [String: Any]?) -> [String: Any]? {
        frame?.dict("session")?.dict("tool")
    }

    private static func workspace(_ frame: [String: Any]?) -> [String: Any]? {
        frame?.dict("session")?.dict("workspace")
    }

    static func getToolType(_ frame: [String: Any]?) -> Int {
        let kind = tool(frame)?.string("active_tool", default: "pen") ?? "pen"
        return ToolMap.kindToToolType(kind)
    }

    static func getBrushThin(_ frame: [String: Any]?) -> Int {
        tool(frame)?.int("brush_thin", default: EngineDefaults.defaultBrushThin)
            ?? EngineDefaults.defaultBrushThin
    }

    static func getBrushColor(_ frame: [String: Any]?) -> String {
        tool(frame)?.string("brush_color", default: EngineDefaults.defaultBrushColor)
            ?? EngineDefaults.defaultBrushColor
    }

    static func getHighlighterColor(_ frame: [String: Any]?) -> String {
        tool(frame)?.string("highlighter_color", default: EngineDefaults.defaultHighlighterColor)
            ?? EngineDefaults.defaultHighlighterColor
    }

    static func getLineStyle(_ frame: [String: Any]?) -> Int {
        switch tool(frame)?.int("line_style") ?? 0 {
        case 1: return DrawsKitConstants.DrawsKitLineType.DRAWSKIT_LINE_TYPE_DASH
        case 2: return DrawsKitConstants.DrawsKitLineType.DRAWSKIT_LINE_TYPE_DOT
        default: return DrawsKitConstants.DrawsKitLineType.DRAWSKIT_LINE_TYPE_SOLID
        }
    }

    static func getEraserSize(_ frame: [String: Any]?) -> Int {
        tool(frame)?.int("eraser_size", default: Int(EngineDefaults.defaultEraserSize))
            ?? Int(EngineDefaults.defaultEraserSize)
    }

    static func isPiecewiseErasure(_ frame: [String: Any]?) -> Bool {
        tool(frame)?.bool("piecewise_erasure", default: true) ?? true
    }

    static func getLaserSize(_ frame: [String: Any]?) -> Int {
        tool(frame)?.int("laser_size", default: Int(EngineDefaults.defaultLaserSize))
            ?? Int(EngineDefaults.defaultLaserSize)
    }

    static func getGraphStyle(_ frame: [String: Any]?) -> [String: Any?] {
        let t = tool(frame)
        let fillRaw = t?["graph_fill_color"]
        let fillColor: String?
        if fillRaw == nil || fillRaw is NSNull {
            fillColor = nil
        } else {
            let value = String(describing: fillRaw!)
            fillColor = value.isEmpty || value == "null" ? nil : value
        }
        return [
            "color": t?.string("graph_color", default: EngineDefaults.defaultGraphColor)
                ?? EngineDefaults.defaultGraphColor,
            "thin": t?.int("graph_thin", default: Int(EngineDefaults.defaultGraphThin))
                ?? Int(EngineDefaults.defaultGraphThin),
            "fillColor": fillColor,
            "fillEnabled": t?.bool("graph_fill_enabled") ?? false,
            "lineStyle": t?.int("graph_line_style") ?? 0,
            "fillStyle": t?.int("graph_fill_style", default: 2) ?? 2,
            "roughness": t?.int("graph_roughness", default: 1) ?? 1,
            "roundness": t?.int("graph_roundness") ?? 0,
            "arrowEnd": t?.bool("graph_arrow_end") ?? false,
        ]
    }

    static func getOvalDrawMode(_ frame: [String: Any]?) -> Int {
        tool(frame)?.int("oval_draw_mode") ?? 0
    }

    static func getTextColor(_ frame: [String: Any]?) -> String {
        tool(frame)?.string("text_color", default: EngineDefaults.defaultStrokeColor)
            ?? EngineDefaults.defaultStrokeColor
    }

    static func getTextSize(_ frame: [String: Any]?) -> Int {
        tool(frame)?.int("text_size", default: EngineDefaults.defaultTextIndustrySize)
            ?? EngineDefaults.defaultTextIndustrySize
    }

    static func getTextStyle(_ frame: [String: Any]?) -> Int {
        tool(frame)?.int("text_style", default: DrawsKitConstants.TextStyle.DRAWSKIT_TEXT_STYLE_NORMAL)
            ?? DrawsKitConstants.TextStyle.DRAWSKIT_TEXT_STYLE_NORMAL
    }

    static func getTextFontFamily(_ frame: [String: Any]?) -> String {
        tool(frame)?.string("text_font_family", default: EngineDefaults.defaultFontFamily)
            ?? EngineDefaults.defaultFontFamily
    }

    static func getTextLineHeight(_ frame: [String: Any]?) -> Float {
        Float(
            tool(frame)?.double("text_line_height", default: Double(EngineDefaults.defaultTextLineHeight))
                ?? Double(EngineDefaults.defaultTextLineHeight)
        )
    }

    static func getMagicPenEnabled(_ frame: [String: Any]?) -> Bool {
        tool(frame)?.bool("magic_pen_enabled") ?? false
    }

    static func getPenAutoFittingMode(_ frame: [String: Any]?) -> Int {
        tool(frame)?.int("pen_auto_fitting_mode", default: 1) ?? 1
    }

    static func getStrokeTaperEnabled(_ frame: [String: Any]?) -> Bool {
        tool(frame)?.bool("stroke_taper_enabled", default: true) ?? true
    }

    static func getBrushThinMode(_ frame: [String: Any]?) -> Int {
        tool(frame)?.int("brush_thin_mode") ?? 0
    }

    static func getBoardScale(_ frame: [String: Any]?) -> Int {
        frame?.dict("viewport")?.int("scale", default: EngineDefaults.defaultBoardScale)
            ?? EngineDefaults.defaultBoardScale
    }

    static func getBoardScroll(_ frame: [String: Any]?) -> (Float, Float) {
        let vp = frame?.dict("viewport")
        return (
            Float(vp?.double("offset_x") ?? 0),
            Float(vp?.double("offset_y") ?? 0)
        )
    }

    static func getBoardList(_ frame: [String: Any]?) -> [String] {
        if let ws = workspace(frame), let arr = ws["board_ids"] as? [Any] {
            return arr.compactMap { $0 as? String }
        }
        if let arr = frame?["board_ids"] as? [Any] {
            return arr.compactMap { $0 as? String }
        }
        return []
    }

    static func getCurrentBoard(_ frame: [String: Any]?) -> String {
        workspace(frame)?.string("current_board_id")
            ?? frame?.string("current_board_id")
            ?? ""
    }

    static func getBoardRemark(_ frame: [String: Any]?, boardId: String) -> String {
        guard let remarks = workspace(frame)?.dict("board_remarks") else { return "" }
        return remarks.string(boardId)
    }

    static func getBoardRatio(_ frame: [String: Any]?) -> String {
        workspace(frame)?.string("ratio", default: EngineDefaults.defaultBoardRatio)
            ?? EngineDefaults.defaultBoardRatio
    }

    static func getScaleRange(_ frame: [String: Any]?) -> (Int, Int) {
        guard let ws = workspace(frame) else {
            return (EngineDefaults.defaultScaleMin, EngineDefaults.defaultScaleMax)
        }
        return (
            ws.int("scale_min", default: EngineDefaults.defaultScaleMin),
            ws.int("scale_max", default: EngineDefaults.defaultScaleMax)
        )
    }

    static func getSelectedIds(_ frame: [String: Any]?) -> [String] {
        guard let arr = frame?["selected_ids"] as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }

    static func getActiveToolKind(_ frame: [String: Any]?) -> String {
        tool(frame)?.string("active_tool", default: "pen") ?? "pen"
    }
}
