import Foundation

public enum DrawsKitConstants {
    public enum EVENT {
        public static let DK_INIT = "DK_INIT"
        public static let DK_ERROR = "DK_ERROR"
        public static let DK_AUTH_EXPIRED = "DK_AUTH_EXPIRED"
        public static let DK_WARNING = "DK_WARNING"
        public static let DK_SYNCDATA = "DK_SYNCDATA"
        public static let DK_HISTROYDATA_SYNCCOMPLETED = "DK_HISTROYDATA_SYNCCOMPLETED"
        public static let DK_OPERATE_CANUNDO_STATUS_CHANGED = "DK_OPERATE_CANUNDO_STATUS_CHANGED"
        public static let DK_OPERATE_CANREDO_STATUS_CHANGED = "DK_OPERATE_CANREDO_STATUS_CHANGED"
        public static let DK_IMAGE_STATUS_CHANGED = "DK_IMAGE_STATUS_CHANGED"
        public static let DK_H5BACKGROUND_STATUS_CHANGED = "DK_H5BACKGROUND_STATUS_CHANGED"
        public static let DK_H5FILE_STATUS_CHANGED = "DK_H5FILE_STATUS_CHANGED"
        public static let DK_COURSEWARE_STATUS_CHANGED = "DK_COURSEWARE_STATUS_CHANGED"
        public static let DK_VIDEO_STATUS_CHANGED = "DK_VIDEO_STATUS_CHANGED"
        public static let DK_AUDIO_STATUS_CHANGED = "DK_AUDIO_STATUS_CHANGED"
        public static let DK_FILEUPLOADSTATUS = "DK_FILEUPLOADSTATUS"
        public static let DK_H5PPT_STATUS_CHANGED = "DK_H5PPT_STATUS_CHANGED"
        public static let DK_ADDBOARD = "DK_ADDBOARD"
        public static let DK_DELETEBOARD = "DK_DELETEBOARD"
        public static let DK_GOTOBOARD = "DK_GOTOBOARD"
        public static let DK_ADDH5PPTFILE = "DK_ADDH5PPTFILE"
        public static let DK_ADDFILE = "DK_ADDFILE"
        public static let DK_DELETEFILE = "DK_DELETEFILE"
        public static let DK_SWITCHFILE = "DK_SWITCHFILE"
        public static let DK_SETBACKGROUNDIMAGE = "DK_SETBACKGROUNDIMAGE"
        public static let DK_FILEUPLOADPROGRESS = "DK_FILEUPLOADPROGRESS"
        public static let DK_ADDTRANSCODEFILE = "DK_ADDTRANSCODEFILE"
        public static let DK_DOMAINSWITCH = "DK_DOMAINSWITCH"
        public static let DK_GOTOSTEP = "DK_GOTOSTEP"
        public static let DK_ADDIMAGEELEMENT = "DK_ADDIMAGEELEMENT"
        public static let DK_ADDIMAGESFILE = "DK_ADDIMAGESFILE"
        public static let DK_ADDELEMENT = "DK_ADDELEMENT"
        public static let DK_REFRESH = "DK_REFRESH"
        public static let DK_SNAPSHOT = "DK_SNAPSHOT"
        public static let DK_REMOVEELEMENT = "DK_REMOVEELEMENT"
        public static let DK_BOARD_SCALE_CHANGE = "DK_BOARD_SCALE_CHANGE"
        public static let DK_TEXT_ELEMENT_STATUS_CHANGED = "DK_TEXT_ELEMENT_STATUS_CHANGED"
        public static let DK_IMAGE_ELEMENT_STATUS_CHANGED = "DK_IMAGE_ELEMENT_STATUS_CHANGED"
        public static let DK_TEXT_ELEMENT_WARNING = "DK_TEXT_ELEMENT_WARNING"
        public static let DK_SELECTED_ELEMENTS = "DK_SELECTED_ELEMENTS"
        public static let DK_MATH_GRAPH_EVENT = "DK_MATH_GRAPH_EVENT"
        public static let DK_ZOOM_DRAG_STATUS = "DK_ZOOM_DRAG_STATUS"
        public static let DK_OFFLINE_WARNING = "DK_OFFLINE_WARNING"
        public static let DK_LICENSE_INVALID = "DK_LICENSE_INVALID"
        public static let DK_LICENSE_OK = "DK_LICENSE_OK"
        public static let DK_BOARD_REMARK_CHANGED = "DK_BOARD_REMARK_CHANGED"
        public static let DK_CLASS_GROUP_STATUS_CHANGED = "DK_CLASS_GROUP_STATUS_CHANGED"
        public static let DK_BOARD_SCROLL_CHANGED = "DK_BOARD_SCROLL_CHANGED"
        public static let DK_BOARD_CURSOR_POSITION = "DK_BOARD_CURSOR_POSITION"
        public static let DK_BOARD_ELEMENT_POSITION_CHANGE = "DK_BOARD_ELEMENT_POSITION_CHANGE"
        public static let DK_BOARD_PERMISSION_DENIED = "DK_BOARD_PERMISSION_DENIED"
        public static let DK_BOARD_PERMISSION_CHANGED = "DK_BOARD_PERMISSION_CHANGED"
        public static let DK_BOARD_IMPORTINLOCALMODE_COMPLETED = "DK_BOARD_IMPORTINLOCALMODE_COMPLETED"
        public static let DK_H5PPT_MEDIA_STATUS_CHANGED = "DK_H5PPT_MEDIA_STATUS_CHANGED"
        public static let DK_BOARD_ELEMENT_LOCKED_CHANGED = "DK_BOARD_ELEMENT_LOCKED_CHANGED"
        public static let DK_DRAW_STATUS_CHANGED = "DK_DRAW_STATUS_CHANGED"
        public static let DK_H5PPT_DOWN_GRADE = "DK_H5PPT_DOWN_GRADE"
        public static let DK_VODEXTPARAM = "DK_VODEXTPARAM"
        public static let DK_DESTROY = "DK_DESTROY"
    }
    public enum ToolType {
        public static let DRAWSKIT_TOOL_TYPE_MOUSE = 0
        public static let DRAWSKIT_TOOL_TYPE_PEN = 1
        public static let DRAWSKIT_TOOL_TYPE_ERASER = 2
        public static let DRAWSKIT_TOOL_TYPE_LASER = 3
        public static let DRAWSKIT_TOOL_TYPE_LINE = 4
        public static let DRAWSKIT_TOOL_TYPE_OVAL = 5
        public static let DRAWSKIT_TOOL_TYPE_RECT = 6
        public static let DRAWSKIT_TOOL_TYPE_OVAL_SOLID = 7
        public static let DRAWSKIT_TOOL_TYPE_RECT_SOLID = 8
        public static let DRAWSKIT_TOOL_TYPE_POINT_SELECT = 9
        public static let DRAWSKIT_TOOL_TYPE_RECT_SELECT = 10
        public static let DRAWSKIT_TOOL_TYPE_TEXT = 11
        public static let DRAWSKIT_TOOL_TYPE_ZOOM_DRAG = 12
        public static let DRAWSKIT_TOOL_TYPE_SQUARE = 13
        public static let DRAWSKIT_TOOL_TYPE_SQUARE_SOLID = 14
        public static let DRAWSKIT_TOOL_TYPE_CIRCLE = 15
        public static let DRAWSKIT_TOOL_TYPE_CIRCLE_SOLID = 16
        public static let DRAWSKIT_TOOL_TYPE_BOARD_CUSTOM_GRAPH = 17
        public static let DRAWSKIT_TOOL_TYPE_HIGHLIGHTER = 19
        public static let DRAWSKIT_TOOL_TYPE_RIGHT_TRIANGLE = 20
        public static let DRAWSKIT_TOOL_TYPE_ISOSCELES_TRIANGLE = 21
        public static let DRAWSKIT_TOOL_TYPE_PARALLELOGRAM = 22
        public static let DRAWSKIT_TOOL_TYPE_CUBE = 23
        public static let DRAWSKIT_TOOL_TYPE_CYLINDER = 24
        public static let DRAWSKIT_TOOL_TYPE_CONE = 25
        public static let DRAWSKIT_TOOL_TYPE_COORDINATE = 26
        public static let DRAWSKIT_TOOL_TYPE_PARABOLA = 27
        public static let DRAWSKIT_TOOL_TYPE_ISOSCELES_TRAPEZOID = 28
        public static let DRAWSKIT_TOOL_TYPE_RIGHT_TRAPEZOID = 29
    }
    public enum DrawsKitLineType {
        public static let DRAWSKIT_LINE_TYPE_SOLID = 0
        public static let DRAWSKIT_LINE_TYPE_DASH = 1
        public static let DRAWSKIT_LINE_TYPE_DOT = 2
    }
    public enum DrawsKitBrushThinMode {
        public static let DRAWSKIT_BRUSH_THIN_MODE_FIXED = 0
        public static let DRAWSKIT_BRUSH_THIN_MODE_PRESSURE = 1
    }
    public enum DrawsKitEraserMode {
        public static let DRAWSKIT_ERASER_MODE_WHOLE = 0
        public static let DRAWSKIT_ERASER_MODE_PIECE = 1
    }
    public enum ElementType {
        public static let DRAWSKIT_ELEMENT_IMAGE = 1
        public static let DRAWSKIT_ELEMENT_H5 = 2
        public static let DRAWSKIT_ELEMENT_CUSTOM_GRAPH = 3
        public static let DRAWSKIT_ELEMENT_AUDIO = 4
        public static let DRAWSKIT_ELEMENT_GLOBAL_AUDIO = 5
        public static let DRAWSKIT_ELEMENT_MATH_BOARD = 6
        public static let DRAWSKIT_ELEMENT_MATH_GRAPH = 7
        public static let DRAWSKIT_ELEMENT_TEXT = 9
        public static let DRAWSKIT_ELEMENT_MAGIC_LINE = 10
        public static let DRAWSKIT_ELEMENT_FORMULA = 11
        public static let DRAWSKIT_ELEMENT_MATH_TOOL = 12
        public static let DRAWSKIT_ELEMENT_GEOMETRY = 13
        public static let DRAWSKIT_ELEMENT_WATERMARK = 100
        public static let DRAWSKIT_ELEMENT_GRAFFITI_LINE = 801
        public static let DRAWSKIT_ELEMENT_GRAFFITI_GRAPH_LINE = 802
        public static let DRAWSKIT_ELEMENT_GRAFFITI_GRAPH_RECT = 803
        public static let DRAWSKIT_ELEMENT_GRAFFITI_GRAPH_OVAL = 804
        public static let DRAWSKIT_ELEMENT_GRAFFITI_GRAPH_HIGHLIGHTER = 812
    }
    public enum ContentFitMode {
        public static let DRAWSKIT_FILE_FIT_MODE_NONE = 0
        public static let DRAWSKIT_FILE_FIT_MODE_CENTER_INSIDE = 1
        public static let DRAWSKIT_FILE_FIT_MODE_CENTER_COVER = 2
    }
    public enum BackgroundType {
        public static let DRAWSKIT_BACKGROUND_IMAGE = 1
        public static let DRAWSKIT_BACKGROUND_H5 = 2
    }
    public enum TextStyle {
        public static let DRAWSKIT_TEXT_STYLE_NORMAL = 0
        public static let DRAWSKIT_TEXT_STYLE_BOLD = 1
        public static let DRAWSKIT_TEXT_STYLE_ITALIC = 2
        public static let DRAWSKIT_TEXT_STYLE_BOLD_ITALIC = 3
    }
    public enum ErrorCode {
        public static let DRAWSKIT_ERROR_INIT = 1
        public static let DRAWSKIT_ERROR_AUTH = 2
        public static let DRAWSKIT_ERROR_NETWORK = 3
        public static let DRAWSKIT_ERROR_LICENSE = 4
    }
    public enum ProductEdition {
        public static let DRAWSKIT_PRODUCT_EDITION_CLOUD = "cloud"
        public static let DRAWSKIT_PRODUCT_EDITION_LOCAL = "local"
    }
    public enum WarningCode {
        public static let DRAWSKIT_WARNING_SYNC_DATA_PARSE_FAILED = 1
        public static let DRAWSKIT_WARNING_H5PPT_ALREADY_EXISTS = 3
        public static let DRAWSKIT_WARNING_ILLEGAL_OPERATION = 5
        public static let DRAWSKIT_WARNING_H5FILE_ALREADY_EXISTS = 6
        public static let DRAWSKIT_WARNING_VIDEO_ALREADY_EXISTS = 7
        public static let DRAWSKIT_WARNING_IMAGESFILE_ALREADY_EXISTS = 8
        public static let DRAWSKIT_WARNING_GRAFFITI_LOST = 9
        public static let DRAWSKIT_WARNING_FILE_NOT_FOUND = 22
        public static let DRAWSKIT_WARNING_DOWNGRADE = 24
        public static let DRAWSKIT_WARNING_SYNC_OUTBOX_WRITE_FAILED = 25
        public static let DRAWSKIT_WARNING_ASSET_LOAD_FAILED = 26
    }
    public enum DrawsKitVideoStatus {
        public static let DRAWSKIT_VIDEO_STATUS_PLAYING = 1
        public static let DRAWSKIT_VIDEO_STATUS_PAUSED = 2
        public static let DRAWSKIT_VIDEO_STATUS_ENDED = 3
        public static let DRAWSKIT_VIDEO_STATUS_ERROR = 4
    }
    public enum DrawsKitAudioStatus {
        public static let DRAWSKIT_AUDIO_STATUS_PLAYING = 1
        public static let DRAWSKIT_AUDIO_STATUS_PAUSED = 2
        public static let DRAWSKIT_AUDIO_STATUS_ENDED = 3
        public static let DRAWSKIT_AUDIO_STATUS_ERROR = 4
    }
    public enum DrawStatusCode {
        public static let START = 1
        public static let END = 0
    }
    public enum MathToolType {
        public static let RULER = 1
        public static let TRIANGLE = 2
        public static let ISOSCELES_TRIANGLE = 3
        public static let PROTRACTOR = 4
        public static let COMPASSES = 5
    }
    public enum SnapshotCode {
        public static let NONE = 0
        public static let IMAGE_LOAD_FAILED = -1
        public static let IMAGE_DIMENSIONS_ABNORMAL = -100
    }
    public enum LogLevel {
        public static let OFF = 0
        public static let ERROR = 1
        public static let WARN = 2
        public static let INFO = 3
        public static let DEBUG = 4
        public static let TRACE = 5
    }
}