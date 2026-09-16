import Foundation

typealias ToolKind = String

enum ToolMap {
    private static let toolTypeToKind: [Int: ToolKind] = [
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_MOUSE: "select",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_PEN: "pen",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_ERASER: "eraser",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_LASER: "laser",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_TEXT: "text",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_RECT_SELECT: "select",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_ZOOM_DRAG: "pan",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_HIGHLIGHTER: "highlighter",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_LINE: "shape",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_OVAL: "shape",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_RECT: "shape",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_OVAL_SOLID: "shape",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_RECT_SOLID: "shape",
    ]

    private static let toolTypeToShapeSub: [Int: String] = [
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_LINE: "line",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_OVAL: "oval",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_RECT: "rect",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_OVAL_SOLID: "oval_solid",
        DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_RECT_SOLID: "rect_solid",
    ]

    private static let kindToToolType: [ToolKind: Int] = [
        "select": DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_MOUSE,
        "pen": DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_PEN,
        "highlighter": DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_HIGHLIGHTER,
        "eraser": DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_ERASER,
        "laser": DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_LASER,
        "text": DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_TEXT,
        "pan": DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_ZOOM_DRAG,
        "shape": DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_RECT,
    ]

    static func toolTypeToKind(_ toolType: Int) -> ToolKind? {
        toolTypeToKind[toolType]
    }

    static func toolTypeToShapeSubTool(_ toolType: Int) -> String? {
        toolTypeToShapeSub[toolType]
    }

    static func kindToToolType(_ kind: ToolKind) -> Int {
        kindToToolType[kind] ?? DrawsKitConstants.ToolType.DRAWSKIT_TOOL_TYPE_PEN
    }
}
