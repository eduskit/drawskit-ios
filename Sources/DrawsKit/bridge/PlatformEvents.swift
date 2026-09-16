import Foundation

/// Maps input-event uptime timestamps to epoch milliseconds using one fixed offset per gesture.
/// Keeping the offset stable preserves sample intervals even if the wall clock changes mid-stroke.
final class GestureTimestampMapper {
    private var epochOffsetMilliseconds: Int?

    var isActive: Bool {
        epochOffsetMilliseconds != nil
    }

    func begin(epochNowMilliseconds: Int, monotonicNowMilliseconds: Int) {
        epochOffsetMilliseconds = epochNowMilliseconds - monotonicNowMilliseconds
    }

    func toEpoch(monotonicTimestampMilliseconds: Int) -> Int {
        guard let epochOffsetMilliseconds else {
            preconditionFailure("Gesture timestamp mapper must be started before mapping events")
        }
        return monotonicTimestampMilliseconds + epochOffsetMilliseconds
    }

    func reset() {
        epochOffsetMilliseconds = nil
    }
}

enum PlatformEvents {
    static func viewportResize(width: Int, height: Int, dpr: Float = 1) -> String {
        JSONCodec.stringify([
            "type": PlatformEventType.viewportResize,
            "width": width,
            "height": height,
            "dpr": Double(dpr),
        ]) ?? "{}"
    }

    static func pointerDown(
        pointerId: Int,
        x: Float,
        y: Float,
        pressure: Float = 1,
        timestamp: Int
    ) -> String {
        JSONCodec.stringify([
            "type": PlatformEventType.pointerDown,
            "pointer_id": pointerId,
            "x": Double(x),
            "y": Double(y),
            "pressure": Double(pressure),
            "timestamp": timestamp,
        ]) ?? "{}"
    }

    static func pointerMove(
        pointerId: Int,
        x: Float,
        y: Float,
        pressure: Float = 1,
        timestamp: Int
    ) -> String {
        JSONCodec.stringify([
            "type": PlatformEventType.pointerMove,
            "pointer_id": pointerId,
            "x": Double(x),
            "y": Double(y),
            "pressure": Double(pressure),
            "timestamp": timestamp,
        ]) ?? "{}"
    }

    static func pointerMoveBatch(pointerId: Int, samples: [[String: Any]]) -> String {
        JSONCodec.stringify([
            "type": PlatformEventType.pointerMoveBatch,
            "pointer_id": pointerId,
            "samples": samples,
        ]) ?? "{}"
    }

    static func pointerUp(pointerId: Int, x: Float, y: Float, timestamp: Int) -> String {
        JSONCodec.stringify([
            "type": PlatformEventType.pointerUp,
            "pointer_id": pointerId,
            "x": Double(x),
            "y": Double(y),
            "timestamp": timestamp,
        ]) ?? "{}"
    }

    static func screenPointerDown(pointerId: Int, x: Float, y: Float, timestamp: Int) -> String {
        JSONCodec.stringify([
            "type": PlatformEventType.screenPointerDown,
            "pointer_id": pointerId,
            "x": Double(x),
            "y": Double(y),
            "timestamp": timestamp,
        ]) ?? "{}"
    }

    static func screenPointerMove(pointerId: Int, x: Float, y: Float, timestamp: Int) -> String {
        JSONCodec.stringify([
            "type": PlatformEventType.screenPointerMove,
            "pointer_id": pointerId,
            "x": Double(x),
            "y": Double(y),
            "timestamp": timestamp,
        ]) ?? "{}"
    }

    static func screenPointerUp(pointerId: Int, x: Float, y: Float, timestamp: Int) -> String {
        JSONCodec.stringify([
            "type": PlatformEventType.screenPointerUp,
            "pointer_id": pointerId,
            "x": Double(x),
            "y": Double(y),
            "timestamp": timestamp,
        ]) ?? "{}"
    }

    static func simple(_ type: String) -> String {
        JSONCodec.stringify(["type": type]) ?? #"{"type":"\#(type)"}"#
    }

    static func withType(_ type: String, _ block: (inout [String: Any]) -> Void) -> String {
        var payload: [String: Any] = ["type": type]
        block(&payload)
        return JSONCodec.stringify(payload) ?? "{}"
    }

    static func loadCourseware(_ payload: CoursewarePayload) -> String {
        PlatformEvents.withType(PlatformEventType.loadCourseware) { event in
            event["resource_id"] = payload.fileId
            event["render_mode"] = EngineDefaults.coursewareRenderModeStaticImage
            event["source_type"] = payload.sourceType
            event["webview_url"] = NSNull()
            event["pages"] = payload.pages.map(coursewarePage)
            event["title"] = payload.title ?? NSNull()
        }
    }

    static func loadH5Courseware(resourceId: String, url: String, title: String?) -> String {
        PlatformEvents.withType(PlatformEventType.loadCourseware) { payload in
            payload["resource_id"] = resourceId
            payload["render_mode"] = EngineDefaults.coursewareRenderModeWebview
            payload["source_type"] = "h5"
            payload["webview_url"] = url
            payload["pages"] = [Any]()
            payload["title"] = title ?? NSNull()
        }
    }

    static func addAudioElement(
        id: String,
        url: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        global: Bool
    ) -> String {
        PlatformEvents.withType(PlatformEventType.addAudioElement) { payload in
            payload["id"] = id
            payload["url"] = url
            payload["x"] = x
            payload["y"] = y
            payload["width"] = width
            payload["height"] = height
            payload["global"] = global
            payload["timestamp"] = Int(Date().timeIntervalSince1970 * 1000)
        }
    }

    static func clearFileDraws(resourceId: String?) -> String {
        PlatformEvents.withType(PlatformEventType.clearFileDraws) { payload in
            payload["resource_id"] = resourceId ?? NSNull()
        }
    }

    private static func coursewarePage(_ page: CoursewarePage) -> [String: Any] {
        [
            "url": page.url,
            "format": page.format,
            "width": page.width,
            "height": page.height,
            "source_page": page.sourcePage,
            "step": page.step,
            "remarks": page.remarks ?? NSNull(),
            "media": page.media.map(mediaSlot),
        ]
    }

    private static func mediaSlot(_ slot: MediaSlot) -> [String: Any] {
        [
            "media_id": slot.mediaId,
            "type": slot.type,
            "url": slot.url,
            "rect": slot.rect,
            "poster": slot.poster ?? NSNull(),
        ]
    }

    static func coursewareReady(resourceId: String) -> String {
        JSONCodec.stringify([
            "type": PlatformEventType.coursewareReady,
            "resource_id": resourceId,
        ]) ?? "{}"
    }

    static func h5CoursewareMessage(payload: [String: Any]) -> String {
        JSONCodec.stringify([
            "type": PlatformEventType.h5CoursewareMessage,
            "payload": payload,
        ]) ?? "{}"
    }

    static func removeCourseware(resourceId: String) -> String {
        JSONCodec.stringify([
            "type": PlatformEventType.removeCourseware,
            "resource_id": resourceId,
        ]) ?? "{}"
    }

    static func zoomAtPoint(screenX: Float, screenY: Float, scaleFactor: Float) -> String {
        JSONCodec.stringify([
            "type": PlatformEventType.zoomAtPoint,
            "screen_x": Double(screenX),
            "screen_y": Double(screenY),
            "scale_factor": Double(scaleFactor),
        ]) ?? "{}"
    }

    static func screenToWorld(
        screenX: Float,
        screenY: Float,
        offsetX: Float,
        offsetY: Float,
        scalePercent: Int
    ) -> (Float, Float) {
        let s = Float(scalePercent) / 100
        return ((screenX - offsetX) / s, (screenY - offsetY) / s)
    }

    static func worldToScreen(
        worldX: Float,
        worldY: Float,
        offsetX: Float,
        offsetY: Float,
        scalePercent: Int
    ) -> (Float, Float) {
        let s = Float(scalePercent) / 100
        return (worldX * s + offsetX, worldY * s + offsetY)
    }
}
