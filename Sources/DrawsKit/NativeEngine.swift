import Foundation

typealias WbDrawCallback = @convention(c) (UnsafePointer<CChar>?, Int) -> Void
typealias WbSyncCallback = @convention(c) (UnsafePointer<CChar>?, Int) -> Void
/// Volatile in-progress ink; fan out over IM only, never persist or retry.
typealias WbLiveStrokeCallback = @convention(c) (UnsafePointer<CChar>?, Int) -> Void

@_silgen_name("wb_engine_get_version")
private func wb_engine_get_version() -> UnsafePointer<CChar>?

@_silgen_name("wb_engine_create")
private func wb_engine_create(_ documentId: UnsafePointer<CChar>?, _ callback: WbDrawCallback?) -> OpaquePointer?

@_silgen_name("wb_engine_create_with_sync")
private func wb_engine_create_with_sync(
    _ documentId: UnsafePointer<CChar>?,
    _ drawCallback: WbDrawCallback?,
    _ syncCallback: WbSyncCallback?,
    _ liveStrokeCallback: WbLiveStrokeCallback?
) -> OpaquePointer?

@_silgen_name("wb_engine_destroy")
private func wb_engine_destroy(_ handle: OpaquePointer?)

@_silgen_name("wb_engine_on_data_json")
private func wb_engine_on_data_json(_ handle: OpaquePointer?, _ json: UnsafePointer<CChar>?, _ len: Int) -> Int32

@_silgen_name("wb_engine_export_json")
private func wb_engine_export_json(_ handle: OpaquePointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_engine_text_at_point_json")
private func wb_engine_text_at_point_json(
    _ handle: OpaquePointer?,
    _ x: Float,
    _ y: Float
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_engine_export_workspace_json")
private func wb_engine_export_workspace_json(
    _ handle: OpaquePointer?,
    _ roomId: UnsafePointer<CChar>?,
    _ checkpointSeq: UInt64
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_engine_import_json")
private func wb_engine_import_json(_ handle: OpaquePointer?, _ json: UnsafePointer<CChar>?) -> Int32

@_silgen_name("wb_engine_import_workspace_json")
private func wb_engine_import_workspace_json(_ handle: OpaquePointer?, _ json: UnsafePointer<CChar>?) -> Int32

@_silgen_name("wb_engine_free_string")
private func wb_engine_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

@_silgen_name("wb_log_set_level")
private func wb_log_set_level(_ level: UInt8)

@_silgen_name("wb_log_set_callback")
private func wb_log_set_callback(_ callback: WbLogCallback?)

@_silgen_name("wb_courseware_rasterize_svg_png")
private func wb_courseware_rasterize_svg_png(
    _ svg: UnsafePointer<UInt8>?,
    _ svgLen: Int,
    _ width: UInt32,
    _ height: UInt32,
    _ outLen: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<UInt8>?

@_silgen_name("wb_courseware_png_free")
private func wb_courseware_png_free(_ bytes: UnsafeMutablePointer<UInt8>?, _ len: Int)

@_silgen_name("wb_render_frame_png")
private func wb_render_frame_png(
    _ frameJson: UnsafePointer<UInt8>?,
    _ frameLen: Int,
    _ width: UInt32,
    _ height: UInt32,
    _ outLen: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<UInt8>?

@_silgen_name("wb_render_frame_png_free")
private func wb_render_frame_png_free(_ bytes: UnsafeMutablePointer<UInt8>?, _ len: Int)

@_silgen_name("wb_render_frame_rgba")
private func wb_render_frame_rgba(
    _ frameJson: UnsafePointer<UInt8>?,
    _ frameLen: Int,
    _ targetWidth: UInt32,
    _ targetHeight: UInt32,
    _ outWidth: UnsafeMutablePointer<UInt32>?,
    _ outHeight: UnsafeMutablePointer<UInt32>?,
    _ outKind: UnsafeMutablePointer<UInt8>?,
    _ outLen: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<UInt8>?

@_silgen_name("wb_render_frame_rgba_free")
private func wb_render_frame_rgba_free(_ bytes: UnsafeMutablePointer<UInt8>?, _ len: Int)

typealias WbLogCallback = @convention(c) (UnsafePointer<CChar>?, Int) -> Void

private enum LogDispatch {
    private static var sink: ((String) -> Void)?
    private static let lock = NSLock()
    private static var installed = false

    static let cCallback: WbLogCallback = { ptr, len in
        guard let ptr, len > 0 else { return }
        let data = Data(bytes: ptr, count: len)
        guard let line = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let handler = sink
        lock.unlock()
        handler?(line)
    }

    static func setSink(_ handler: ((String) -> Void)?) {
        lock.lock()
        sink = handler
        if !installed {
            wb_log_set_callback(cCallback)
            installed = true
        }
        lock.unlock()
    }
}

private enum FrameDispatch {
    private static var handlers: [(String) -> Void] = []
    private static let lock = NSLock()

    static let cCallback: WbDrawCallback = { ptr, len in
        guard let ptr, len > 0 else { return }
        let data = Data(bytes: ptr, count: len)
        guard let json = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let handler = handlers.last
        lock.unlock()
        handler?(json)
    }

    static func push(_ handler: @escaping (String) -> Void) {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
    }

    static func pop() {
        lock.lock()
        if !handlers.isEmpty { _ = handlers.removeLast() }
        lock.unlock()
    }
}

private enum LiveStrokeDispatch {
    private static var handlers: [(String) -> Void] = []
    private static let lock = NSLock()

    static let cCallback: WbLiveStrokeCallback = { ptr, len in
        guard let ptr, len > 0 else { return }
        let data = Data(bytes: ptr, count: len)
        guard let json = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let handler = handlers.last
        lock.unlock()
        handler?(json)
    }

    static func push(_ handler: @escaping (String) -> Void) {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
    }

    static func pop() {
        lock.lock()
        if !handlers.isEmpty { _ = handlers.removeLast() }
        lock.unlock()
    }
}

private enum SyncDispatch {
    private static var handlers: [(String) -> Void] = []
    private static let lock = NSLock()

    static let cCallback: WbSyncCallback = { ptr, len in
        guard let ptr, len > 0 else { return }
        let data = Data(bytes: ptr, count: len)
        guard let json = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let handler = handlers.last
        lock.unlock()
        handler?(json)
    }

    static func push(_ handler: @escaping (String) -> Void) {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
    }

    static func pop() {
        lock.lock()
        if !handlers.isEmpty { _ = handlers.removeLast() }
        lock.unlock()
    }
}

public struct EngineSmokeResult {
    public let ok: Bool
    public let version: String
    public let frameCount: Int
    public let error: String?

    public init(ok: Bool, version: String, frameCount: Int, error: String? = nil) {
        self.ok = ok
        self.version = version
        self.frameCount = frameCount
        self.error = error
    }
}

/// FFI bridge to `libwhiteboard_ffi` (see `pnpm build:ios:ffi`).
public enum NativeEngine {
    public static var isLibLoaded: Bool {
        wb_engine_get_version() != nil
    }

    public static func getVersion() -> String {
        guard let ptr = wb_engine_get_version() else { return "unknown" }
        return String(cString: ptr)
    }

    public static func setLogLevel(_ level: Int) {
        wb_log_set_level(UInt8(clamping: level))
    }

    public static func setEngineLogSink(_ sink: ((String) -> Void)?) {
        LogDispatch.setSink(sink)
    }

    /// Rasterizes an SVG courseware page to PNG in Rust — the same rasterizer
    /// Web and Android call, so a lesson looks identical on every platform. iOS
    /// has no SVG decoder of its own.
    ///
    /// Pass 0 for `width`/`height` to use the page's intrinsic size. Returns nil
    /// when the SVG is not renderable.
    public static func rasterizeCoursewareSvg(
        _ svg: Data,
        width: UInt32 = 0,
        height: UInt32 = 0
    ) -> Data? {
        guard !svg.isEmpty else { return nil }
        var length = 0
        let pointer: UnsafeMutablePointer<UInt8>? = svg.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            return wb_courseware_rasterize_svg_png(base, buffer.count, width, height, &length)
        }
        guard let pointer, length > 0 else { return nil }
        defer { wb_courseware_png_free(pointer, length) }
        return Data(bytes: pointer, count: length)
    }

    /// Shared Rust vector raster; courseware/image resources remain platform-owned.
    public static func rasterizeRenderFrame(
        _ frame: [String: Any],
        width: UInt32,
        height: UInt32
    ) -> Data? {
        guard width > 0, height > 0,
              JSONSerialization.isValidJSONObject(frame),
              let json = try? JSONSerialization.data(withJSONObject: frame) else { return nil }
        var length = 0
        let pointer: UnsafeMutablePointer<UInt8>? = json.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            return wb_render_frame_png(base, buffer.count, width, height, &length)
        }
        guard let pointer, length > 0 else { return nil }
        defer { wb_render_frame_png_free(pointer, length) }
        return Data(bytes: pointer, count: length)
    }

    public struct VectorRasterPacket {
        public let width: Int
        public let height: Int
        public let transient: Bool
        public let pixels: Data
    }

    /// Shared Rust packet planner + RGBA raster. No PNG codec on pointer moves.
    public static func rasterizeVectorPacket(
        _ frame: [String: Any],
        width: UInt32,
        height: UInt32
    ) -> VectorRasterPacket? {
        guard width > 0, height > 0,
              JSONSerialization.isValidJSONObject(frame),
              let json = try? JSONSerialization.data(withJSONObject: frame) else { return nil }
        var outputWidth: UInt32 = 0
        var outputHeight: UInt32 = 0
        var outputKind: UInt8 = 0
        var length = 0
        let pointer: UnsafeMutablePointer<UInt8>? = json.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            return wb_render_frame_rgba(
                base, buffer.count, width, height,
                &outputWidth, &outputHeight, &outputKind, &length
            )
        }
        guard let pointer, length > 0 else { return nil }
        defer { wb_render_frame_rgba_free(pointer, length) }
        return VectorRasterPacket(
            width: Int(outputWidth),
            height: Int(outputHeight),
            transient: outputKind != 0,
            pixels: Data(bytes: pointer, count: length)
        )
    }

    public final class EngineSession {
        private let handle: OpaquePointer
        private let usesSync: Bool
        private let usesLiveStroke: Bool
        private let ffiLock = NSLock()
        private var alive = true

        private func withAliveHandle<T>(_ fallback: T, _ body: (OpaquePointer) -> T) -> T {
            ffiLock.lock()
            defer { ffiLock.unlock() }
            guard alive else { return fallback }
            return body(handle)
        }

        init?(
            documentId: String,
            onFrame: @escaping (String) -> Void,
            onSyncOut: ((String) -> Void)? = nil,
            onLiveStrokeOut: ((String) -> Void)? = nil
        ) {
            FrameDispatch.push(onFrame)
            if onSyncOut != nil || onLiveStrokeOut != nil {
                if let onSyncOut { SyncDispatch.push(onSyncOut) }
                if let onLiveStrokeOut { LiveStrokeDispatch.push(onLiveStrokeOut) }
                usesSync = onSyncOut != nil
                usesLiveStroke = onLiveStrokeOut != nil
                guard let handle = documentId.withCString({
                    wb_engine_create_with_sync(
                        $0,
                        FrameDispatch.cCallback,
                        onSyncOut == nil ? nil : SyncDispatch.cCallback,
                        onLiveStrokeOut == nil ? nil : LiveStrokeDispatch.cCallback
                    )
                }) else {
                    if usesLiveStroke { LiveStrokeDispatch.pop() }
                    if usesSync { SyncDispatch.pop() }
                    FrameDispatch.pop()
                    return nil
                }
                self.handle = handle
            } else {
                usesSync = false
                usesLiveStroke = false
                guard let handle = documentId.withCString({
                    wb_engine_create($0, FrameDispatch.cCallback)
                }) else {
                    FrameDispatch.pop()
                    return nil
                }
                self.handle = handle
            }
        }

        func send(json: String) -> Int32 {
            guard let data = json.data(using: .utf8) else { return -1 }
            return withAliveHandle(-1) { handle in
                data.withUnsafeBytes { buf in
                    guard let base = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return -1 }
                    return wb_engine_on_data_json(handle, base, buf.count)
                }
            }
        }

        func exportJson() -> String? {
            withAliveHandle(nil) { handle in
                guard let ptr = wb_engine_export_json(handle) else { return nil }
                defer { wb_engine_free_string(ptr) }
                return String(cString: ptr)
            }
        }

        /// Sync Rust text hit under scene coords; nil when none.
        func textAtPointJson(x: Float, y: Float) -> String? {
            withAliveHandle(nil) { handle in
                guard let ptr = wb_engine_text_at_point_json(handle, x, y) else { return nil }
                defer { wb_engine_free_string(ptr) }
                return String(cString: ptr)
            }
        }

        func importJson(_ json: String) -> Int32 {
            withAliveHandle(-1) { handle in
                json.withCString { wb_engine_import_json(handle, $0) }
            }
        }

        func exportWorkspaceJson(roomId: String, checkpointSeq: UInt64) -> String? {
            withAliveHandle(nil) { handle in
                guard let ptr = roomId.withCString({
                    wb_engine_export_workspace_json(handle, $0, checkpointSeq)
                }) else { return nil }
                defer { wb_engine_free_string(ptr) }
                return String(cString: ptr)
            }
        }

        func importWorkspaceJson(_ json: String) -> Int32 {
            withAliveHandle(-1) { handle in
                json.withCString { wb_engine_import_workspace_json(handle, $0) }
            }
        }

        func destroy() {
            ffiLock.lock()
            let shouldRelease = alive
            alive = false
            if shouldRelease {
                wb_engine_destroy(handle)
            }
            ffiLock.unlock()
            guard shouldRelease else { return }
            FrameDispatch.pop()
            if usesSync {
                SyncDispatch.pop()
            }
            if usesLiveStroke {
                LiveStrokeDispatch.pop()
            }
        }
    }

    public static func runSmoke(documentId: String = "smoke") -> EngineSmokeResult {
        guard isLibLoaded else {
            return EngineSmokeResult(
                ok: false,
                version: getVersion(),
                frameCount: 0,
                error: "libwhiteboard_ffi not linked (run pnpm build:ios:ffi)"
            )
        }

        var frameCount = 0
        guard let session = EngineSession(documentId: documentId, onFrame: { _ in frameCount += 1 }) else {
            return EngineSmokeResult(ok: false, version: getVersion(), frameCount: 0, error: "engine create failed")
        }

        let json = #"{"type":"viewport_resize","width":800,"height":600,"dpr":1.0}"#
        let rc = session.send(json: json)
        session.destroy()
        let ok = frameCount >= 1 && rc == 0
        return EngineSmokeResult(
            ok: ok,
            version: getVersion(),
            frameCount: frameCount,
            error: ok ? nil : "rc=\(rc) frames=\(frameCount)"
        )
    }
}
