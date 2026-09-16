import UIKit

@_silgen_name("wb_scene_retention_create")
private func wb_scene_retention_create() -> OpaquePointer?

@_silgen_name("wb_scene_retention_destroy")
private func wb_scene_retention_destroy(_ handle: OpaquePointer?)

@_silgen_name("wb_scene_retention_materialize_json")
private func wb_scene_retention_materialize_json(
    _ handle: OpaquePointer?,
    _ frameJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_engine_free_string")
private func wb_scene_retention_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

final class SharedRasterRenderer {
    private weak var host: UIView?
    private let imageCache: ImageCache
    private let onSceneGap: (_ expectedVersion: Int, _ receivedBaseVersion: Int) -> Void
    private let preloadDepth: Int
    private var dpr: CGFloat = 1
    private var retentionHandle: OpaquePointer? = wb_scene_retention_create()
    private var acknowledgedCoursewareUrls = Set<String>()
    private var coursewareTargetKeys: [String: String] = [:]
    private var rerasterWorkItem: DispatchWorkItem?
    private var pendingReraster: (url: String, full: CoursewareRasterSize, preview: CoursewareRasterSize)?
    private struct RenderPacket {
        let generation: UInt64
        let image: CGImage
        let bounds: CGRect
        let displayScale: CGFloat
    }
    private var preparedPacket: RenderPacket?
    private var transientPacket: RenderPacket?
    private let vectorRasterQueue = DispatchQueue(label: "io.drawskit.vector-raster", qos: .userInitiated)
    private var vectorRasterGeneration: UInt64 = 0
    private let vectorRasterGenerationLock = NSLock()
    private let prepareLock = NSLock()
    private var pendingFrame: [String: Any]?
    private var prepareRunning = false
    private var destroyed = false
    private var didLogRasterDiagnostic = false
    /// 最近一次 `materialize` 是否因 scene_delta 版本缺口提前返回（layers 可能为空）。
    private(set) var lastMaterializeWasGap = false

    init(
        host: UIView,
        imageCache: ImageCache,
        onSceneGap: @escaping (_ expectedVersion: Int, _ receivedBaseVersion: Int) -> Void = { _, _ in },
        preloadDepth: Int = 2
    ) {
        self.host = host
        self.imageCache = imageCache
        self.onSceneGap = onSceneGap
        self.preloadDepth = max(0, min(preloadDepth, 2))
    }

    /// Physical scale for courseware rasters (Retina). Stroke viewport.dpr stays 1.
    private var coursewareDeviceScale: CGFloat {
        preparedPacket?.displayScale ?? 1
    }

    /// Rebuilds the committed scene from an incremental frame using the shared
    /// Core retention, so no platform reimplements delta bookkeeping.
    ///
    /// Transient frames carry no document change and pass straight through,
    /// which keeps a pointer move independent of how much the board holds.
    /// Runs on the engine callback queue, never on the render thread.
    func materialize(_ source: [String: Any]) -> [String: Any] {
        lastMaterializeWasGap = false
        if source.string("render_message_type") == RenderDefaults.renderMessageTransient {
            return source
        }
        guard let retentionHandle,
              let data = try? JSONSerialization.data(withJSONObject: source),
              let json = String(data: data, encoding: .utf8)
        else { return source }
        return json.withCString { cstr -> [String: Any] in
            guard let out = wb_scene_retention_materialize_json(retentionHandle, cstr) else {
                return source
            }
            defer { wb_scene_retention_free_string(out) }
            guard let bytes = String(cString: out).data(using: .utf8),
                  let outcome = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { return source }
            if let gap = outcome["gap"] as? [String: Any] {
                lastMaterializeWasGap = true
                onSceneGap(gap.int("retained_version"), gap.int("received_base_version"))
            }
            return outcome["frame"] as? [String: Any] ?? source
        }
    }

    private func compileFrame(
        in context: CGContext,
        frame: [String: Any],
        vectorImage: CGImage?,
        bounds: CGRect
    ) {
        let webViewCourseware = CoursewareRead.hasWebViewCourseware(frame)
        guard let viewport = frame.dict("viewport") else {
            if !webViewCourseware {
                context.setFillColor(UIColor.white.cgColor)
                context.fill(bounds)
            }
            return
        }

        let width = CGFloat(viewport.double("width", default: Double(bounds.width)))
        let height = CGFloat(viewport.double("height", default: Double(bounds.height)))
        dpr = max(CGFloat(viewport.double("dpr", default: 1)), 1)

        context.saveGState()
        context.scaleBy(x: dpr, y: dpr)
        if !webViewCourseware {
            context.setFillColor(DotGrid.bgColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let boardScale = CGFloat(viewport.double("scale", default: 100) / 100)
            let offsetX = CGFloat(viewport.double("offset_x"))
            let offsetY = CGFloat(viewport.double("offset_y"))
            context.setFillColor(DotGrid.dotColor.cgColor)
            DotGrid.forEachScreenPoint(
                width: width,
                height: height,
                offsetX: offsetX,
                offsetY: offsetY,
                boardScale: boardScale
            ) { sx, sy in
                let r = DotGrid.radiusPx
                context.fillEllipse(in: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2))
            }
        }

        context.saveGState()
        let boardScale = CGFloat(viewport.double("scale", default: 100) / 100)
        let offsetX = CGFloat(viewport.double("offset_x"))
        let offsetY = CGFloat(viewport.double("offset_y"))
        let safeScale = max(boardScale, .leastNonzeroMagnitude)
        let content = ViewportCoords.contentTransform(frame: frame)
        let contentScale = CGFloat(content?.scale ?? 1)
        let contentOffsetX = CGFloat(content?.offsetX ?? 0)
        let contentOffsetY = CGFloat(content?.offsetY ?? 0)
        let visibleWorld = CGRect(
            x: (-offsetX / safeScale - contentOffsetX) / contentScale,
            y: (-offsetY / safeScale - contentOffsetY) / contentScale,
            width: width / safeScale / contentScale,
            height: height / safeScale / contentScale
        )
        context.translateBy(x: offsetX, y: offsetY)
        context.scaleBy(x: boardScale, y: boardScale)
        if let content {
            context.translateBy(x: CGFloat(content.offsetX), y: CGFloat(content.offsetY))
            context.scaleBy(x: CGFloat(content.scale), y: CGFloat(content.scale))
        }

        if let layers = frame["layers"] as? [Any] {
            for item in layers {
                guard let layer = item as? [String: Any] else { continue }
                switch layer.string("type") {
                case "courseware":
                    drawCourseware(
                        in: context,
                        layer: layer.dict("data"),
                        viewportWidth: width,
                        viewportHeight: height,
                        boardScale: boardScale,
                        frame: frame
                    )
                case "shapes":
                    if let shapes = layer["shapes"] as? [Any] {
                        for shapeItem in shapes {
                            guard let shape = shapeItem as? [String: Any] else { continue }
                            // Network-backed images stay platform-owned. Rust
                            // paints all deterministic vector geometry.
                            if shape.string("type") == "image", shapeIntersects(shape, visible: visibleWorld) {
                                drawImageShape(in: context, shape: shape)
                            }
                        }
                    }
                case "preview", "overlay":
                    break
                default:
                    break
                }
            }
        }

        context.restoreGState()
        context.restoreGState()
        if let vectorImage {
            // The context is physical-pixel sized and its DPR transform has
            // just been restored. The Rust packet is physical too, so composite
            // it 1:1 here. Drawing into logical `bounds` would shrink it into
            // the top-left 1/DPR corner of the final 16:9 packet.
            context.draw(
                vectorImage,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: vectorImage.width,
                    height: vectorImage.height
                )
            )
        }
    }

    /// Rasterizes deterministic vectors away from UIKit's draw callback. The
    /// render thread always consumes the last complete image and never waits.
    func prepareSharedVectorLayer(frame: [String: Any]) {
        prepareLock.lock()
        guard !destroyed else {
            prepareLock.unlock()
            return
        }
        // Keep at most one not-yet-started frame. The in-flight frame may still
        // publish, preventing continuous pointer input from starving rendering.
        pendingFrame = frame
        let shouldStart = !prepareRunning
        if shouldStart { prepareRunning = true }
        prepareLock.unlock()
        guard shouldStart else { return }

        vectorRasterQueue.async { [weak self] in self?.drainPreparedFrames() }
    }

    private func drainPreparedFrames() {
        while true {
            prepareLock.lock()
            let frame = pendingFrame
            pendingFrame = nil
            if frame == nil || destroyed {
                prepareRunning = false
                prepareLock.unlock()
                return
            }
            prepareLock.unlock()
            compileAndPublish(frame: frame!)
        }
    }

    private func compileAndPublish(frame: [String: Any]) {
        guard let viewport = frame["viewport"] as? [String: Any] else { return }
        let scale = max(CGFloat(viewport.double("dpr", default: 1)), 1)
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: max(CGFloat(viewport.double("width", default: 1)), 1),
            height: max(CGFloat(viewport.double("height", default: 1)), 1)
        )
        let width = max(Int((bounds.width * scale).rounded()), 1)
        let height = max(Int((bounds.height * scale).rounded()), 1)
        let generation = currentVectorRasterGeneration()
        guard let raster = NativeEngine.rasterizeVectorPacket(
            frame,
            width: UInt32(width),
            height: UInt32(height)
        ), let provider = CGDataProvider(data: raster.pixels as CFData),
              let image = CGImage(
                width: raster.width,
                height: raster.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: raster.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue:
                    CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return }
        if raster.transient {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.prepareLock.lock()
                let stillActive = !self.destroyed && generation == self.currentVectorRasterGeneration()
                self.prepareLock.unlock()
                guard stillActive else { return }
                self.transientPacket = RenderPacket(
                    generation: generation,
                    image: image,
                    bounds: bounds,
                    displayScale: scale
                )
                self.host?.setNeedsDisplay()
            }
            return
        }
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        // `compileFrame` owns the single logical-point -> physical-pixel DPR
        // transform. Scaling here as well zooms the 16:9 board by DPR twice
        // and leaves only its top-left corner visible on Retina displays.
        compileFrame(in: context, frame: frame, vectorImage: image, bounds: bounds)
        guard let compiled = context.makeImage() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.prepareLock.lock()
            let stillActive = !self.destroyed && generation == self.currentVectorRasterGeneration()
            self.prepareLock.unlock()
            guard stillActive else { return }
            self.preparedPacket = RenderPacket(
                generation: generation,
                image: compiled,
                bounds: bounds,
                displayScale: scale
            )
            self.transientPacket = nil
            self.host?.setNeedsDisplay()
        }
    }

    func render(in context: CGContext) {
        // Always compose into the visible surface. `packet.bounds` is the
        // logical viewport used to compile the frame (default 1280×720, or a
        // stale reparent size). Drawing that rect 1:1 on a phone 16:9 slot
        // (≈402×226) makes the courseware larger than the whiteboard and
        // clips the right edge. Android already dest-rects to host size.
        let surface = host?.bounds
        let dest: CGRect
        if let surface, surface.width > 0, surface.height > 0 {
            dest = surface
        } else {
            dest = preparedPacket?.bounds ?? transientPacket?.bounds ?? .zero
        }
        guard dest.width > 0, dest.height > 0 else { return }
        for packet in [preparedPacket, transientPacket].compactMap({ $0 }) {
            // UIView.draw(_:) supplies a UIKit context whose CTM already owns
            // device scale and Y-axis conversion. A second manual translate /
            // flip makes packet placement depend on the Retina CTM and crops
            // phone layouts. UIImage performs the one canonical CGImage ->
            // UIKit conversion; this callback remains a non-blocking compose.
            UIImage(
                cgImage: packet.image,
                scale: packet.displayScale,
                orientation: .up
            ).draw(in: dest)
        }
    }

    func destroy() {
        prepareLock.lock()
        destroyed = true
        pendingFrame = nil
        _ = nextVectorRasterGeneration()
        prepareLock.unlock()
        preparedPacket = nil
        transientPacket = nil
        wb_scene_retention_destroy(retentionHandle)
        retentionHandle = nil
    }

    private func nextVectorRasterGeneration() -> UInt64 {
        vectorRasterGenerationLock.lock()
        defer { vectorRasterGenerationLock.unlock() }
        vectorRasterGeneration &+= 1
        return vectorRasterGeneration
    }

    private func currentVectorRasterGeneration() -> UInt64 {
        vectorRasterGenerationLock.lock()
        defer { vectorRasterGenerationLock.unlock() }
        return vectorRasterGeneration
    }

    private func shapeIntersects(_ shape: [String: Any], visible: CGRect) -> Bool {
        guard let bounds = shapeBounds(shape) else { return true }
        return bounds.intersects(visible)
    }

    private func shapeBounds(_ shape: [String: Any]) -> CGRect? {
        switch shape.string("type") {
        case "path":
            let points: [Any]?
            if shape.bool("stroke_taper"), let outline = shape["outline"] as? [Any], !outline.isEmpty {
                points = outline
            } else {
                points = shape["points"] as? [Any]
            }
            return pointsBounds(points, extraPad: CGFloat(shape.dict("style")?.double("width") ?? 1))
        case "rect", "ellipse", "image":
            guard let bounds = shape.dict("bounds") else { return nil }
            let pad = CGFloat(shape.dict("style")?.dict("stroke")?.double("width") ?? 0) / 2 + 8
            return CGRect(
                x: CGFloat(bounds.double("x")) - pad,
                y: CGFloat(bounds.double("y")) - pad,
                width: CGFloat(bounds.double("width")) + pad * 2,
                height: CGFloat(bounds.double("height")) + pad * 2
            )
        case "line":
            guard let start = shape.dict("start"), let end = shape.dict("end") else { return nil }
            let width = CGFloat(shape.dict("style")?.double("width") ?? 1)
            let pad = max(width * 4, 12)
            let startX = CGFloat(start.double("x"))
            let startY = CGFloat(start.double("y"))
            let endX = CGFloat(end.double("x"))
            let endY = CGFloat(end.double("y"))
            return CGRect(
                x: min(startX, endX) - pad,
                y: min(startY, endY) - pad,
                width: abs(endX - startX) + pad * 2,
                height: abs(endY - startY) + pad * 2
            )
        case "text":
            guard let position = shape.dict("position"), let style = shape.dict("style") else { return nil }
            let size = CGFloat(style.double("font_size", default: 16))
            let lines = shape.string("content").split(separator: "\n", omittingEmptySubsequences: false)
            let longest = max(1, lines.map(\.count).max() ?? 1)
            let lineHeight = CGFloat(style.double("line_height", default: 1))
            return CGRect(
                x: CGFloat(position.double("x")),
                y: CGFloat(position.double("y")),
                width: CGFloat(longest) * size * 0.65,
                height: CGFloat(max(1, lines.count)) * size * lineHeight
            )
        default:
            return nil
        }
    }

    private func pointsBounds(_ values: [Any]?, extraPad: CGFloat) -> CGRect? {
        guard let points = values?.compactMap({ $0 as? [String: Any] }),
              let first = points.first else { return nil }
        var minX = CGFloat(first.double("x"))
        var minY = CGFloat(first.double("y"))
        var maxX = minX
        var maxY = minY
        for point in points.dropFirst() {
            let x = CGFloat(point.double("x"))
            let y = CGFloat(point.double("y"))
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        let pad = extraPad / 2 + 8
        return CGRect(
            x: minX - pad,
            y: minY - pad,
            width: maxX - minX + pad * 2,
            height: maxY - minY + pad * 2
        )
    }

    private func drawCourseware(
        in context: CGContext,
        layer: [String: Any]?,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        boardScale: CGFloat,
        frame: [String: Any]
    ) {
        guard let layer else { return }
        if CoursewareRead.isWebViewRenderMode(layer.string("render_mode")) { return }
        let url = layer.string("image_url")
        guard !url.isEmpty else { return }

        let page = layer.dict("page")
        let pageWidth = CGFloat(page?.double("width") ?? 0)
        let pageHeight = CGFloat(page?.double("height") ?? 0)
        let isSvg = page?.string("format") == "svg" || url.lowercased().contains(".svg")
        // Use Retina displayScale for rasters; viewport.dpr stays 1 for strokes.
        let deviceScale = coursewareDeviceScale
        let full: CoursewareRasterSize = isSvg
            ? ImageCache.coursewareRasterSize(
                pageWidth: pageWidth,
                pageHeight: pageHeight,
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                deviceScale: deviceScale,
                boardScale: boardScale,
                maxEdge: ImageCache.coursewareRasterMaxEdge
            )
            : CoursewareRasterSize(width: 0, height: 0, capped: false)
        let preview: CoursewareRasterSize = isSvg
            ? ImageCache.coursewareRasterSize(
                pageWidth: pageWidth,
                pageHeight: pageHeight,
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                deviceScale: deviceScale,
                boardScale: boardScale,
                maxEdge: ImageCache.coursewareRasterPreviewMaxEdge
            )
            : CoursewareRasterSize(width: 0, height: 0, capped: false)

        let reraster: RerasterPlan = isSvg
            ? scheduleCoursewareReraster(url: url, full: full, preview: preview)
            : .unchanged

        let image: UIImage? = isSvg
            ? imageCache.getBest(
                url,
                fullW: full.width,
                fullH: full.height,
                previewW: preview.width,
                previewH: preview.height,
                allowPreview: true
            )
            : imageCache.get(url)
        guard let image else {
            if isSvg {
                if reraster != .deferred {
                    imageCache.loadCoursewareProgressive(
                        url: url,
                        fullW: full.width,
                        fullH: full.height,
                        previewW: preview.width,
                        previewH: preview.height,
                        priority: 0,
                        capped: full.capped
                    )
                }
            } else {
                imageCache.load(url)
            }
            return
        }

        let pixelW = UInt32(max(1, (image.size.width * image.scale).rounded()))
        let pixelH = UInt32(max(1, (image.size.height * image.scale).rounded()))
        let sharp = isSvg && ImageCache.isSharpEnough(
            bitmapW: pixelW, bitmapH: pixelH, targetW: full.width, targetH: full.height
        )
        let quality: String
        if !isSvg {
            quality = "full"
        } else if sharp {
            quality = full.capped ? "capped" : "full"
        } else {
            quality = "preview"
        }
        let ackKey = "\(url)|\(quality)|\(full.width)x\(full.height)"
        if acknowledgedCoursewareUrls.insert(ackKey).inserted {
            imageCache.acknowledgeDrawable(url, quality: quality)
        }

        let layoutW = pageWidth > 0 ? pageWidth : RenderDefaults.defaultPageWidth
        let layoutH = pageHeight > 0
            ? pageHeight
            : layoutW * RenderDefaults.defaultPageHeight / RenderDefaults.defaultPageWidth
        let transform = layer.dict("transform")
        let translateX = CGFloat(transform?.double("translate_x") ?? 0)
        let translateY = CGFloat(transform?.double("translate_y") ?? 0)
        let scale = CGFloat(transform?.double("scale", default: 1) ?? 1)

        let rect = CGRect(
            x: translateX,
            y: translateY,
            width: layoutW * scale,
            height: layoutH * scale
        )
        context.interpolationQuality = sharp ? .default : .none
        // Frame compilation owns this offscreen context; `UIImage.draw(in:)`
        // would target the thread's current UIKit context, which is nil here.
        // Packet replay applies the UIKit/CGImage coordinate conversion once.
        guard let cgImage = image.cgImage else { return }
        context.draw(cgImage, in: rect)
        punchCoursewareMediaSlots(in: context, page: page, translateX: translateX, translateY: translateY, scale: scale)
        if isSvg {
            if sharp {
                prefetchNeighborPages(frame: frame, layer: layer, full: full, preview: preview)
            } else if reraster != .deferred {
                imageCache.loadCoursewareProgressive(
                    url: url,
                    fullW: full.width,
                    fullH: full.height,
                    previewW: preview.width,
                    previewH: preview.height,
                    priority: 0,
                    capped: full.capped
                )
            }
        }
    }

    private enum RerasterPlan {
        case unchanged, first, deferred, shrink
    }

    /// Growth waits for viewport settle (~180ms) before re-raster (courseware-manifest §3.5).
    private func scheduleCoursewareReraster(
        url: String,
        full: CoursewareRasterSize,
        preview: CoursewareRasterSize
    ) -> RerasterPlan {
        let key = "\(full.width)x\(full.height)"
        let prev = coursewareTargetKeys[url]
        if prev == key { return .unchanged }
        coursewareTargetKeys[url] = key
        guard let prev else { return .first }
        let parts = prev.split(separator: "x")
        let pw = UInt32(parts.first.flatMap { UInt32($0) } ?? 0)
        let ph = UInt32(parts.dropFirst().first.flatMap { UInt32($0) } ?? 0)
        let grew = full.width > pw || full.height > ph
        guard grew else { return .shrink }
        pendingReraster = (url, full, preview)
        rerasterWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let job = self.pendingReraster else { return }
            self.pendingReraster = nil
            self.imageCache.invalidateReady(job.url)
            self.imageCache.loadCoursewareProgressive(
                url: job.url,
                fullW: job.full.width,
                fullH: job.full.height,
                previewW: job.preview.width,
                previewH: job.preview.height,
                priority: 0,
                capped: job.full.capped
            )
        }
        rerasterWorkItem = work
        vectorRasterQueue.asyncAfter(
            deadline: .now() + ImageCache.coursewareRerasterDebounceMs,
            execute: work
        )
        return .deferred
    }


    private func prefetchNeighborPages(
        frame: [String: Any],
        layer: [String: Any],
        full: CoursewareRasterSize,
        preview: CoursewareRasterSize
    ) {
        guard preloadDepth > 0 else { return }
        let fileId = layer.string("resource_id")
        guard !fileId.isEmpty else { return }
        let urls = CoursewareRead.getThumbnailImages(frame, fileId: fileId)
        guard !urls.isEmpty else { return }
        let index = layer.int("page_index")
        let current = layer.string("image_url")
        let offsets = preloadDepth == 1 ? [1] : [1, -1, 2]
        var neighbors: [String] = []
        for offset in offsets {
            let neighborIndex = index + offset
            guard urls.indices.contains(neighborIndex) else { continue }
            let neighbor = urls[neighborIndex]
            if !neighbor.isEmpty && neighbor != current {
                neighbors.append(neighbor)
            }
        }
        imageCache.prefetchCoursewarePages(
            neighborUrls: neighbors,
            fullW: full.width,
            fullH: full.height,
            previewW: preview.width,
            previewH: preview.height,
            capped: full.capped
        )
    }

    private func drawImageShape(in context: CGContext, shape: [String: Any]) {
        let url = shape.string("url")
        guard !url.isEmpty, let bounds = shape.dict("bounds"),
              let image = imageCache.get(url), let cgImage = image.cgImage else {
            if !url.isEmpty { imageCache.load(url) }
            return
        }
        let rect = CGRect(
            x: bounds.double("x"),
            y: bounds.double("y"),
            width: bounds.double("width"),
            height: bounds.double("height")
        )
        context.draw(cgImage, in: rect)
    }

    private func punchCoursewareMediaSlots(
        in context: CGContext,
        page: [String: Any]?,
        translateX: CGFloat,
        translateY: CGFloat,
        scale: CGFloat
    ) {
        let media = page?["media"] as? [[String: Any]] ?? []
        guard !media.isEmpty else { return }
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.setFillColor(UIColor.black.cgColor)
        for slot in media {
            let x = translateX + CGFloat(slot.double("x")) * scale
            let y = translateY + CGFloat(slot.double("y")) * scale
            let w = CGFloat(slot.double("width")) * scale
            let h = CGFloat(slot.double("height")) * scale
            context.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        context.restoreGState()
    }
}
