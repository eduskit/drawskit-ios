import UIKit

struct CoursewareStatusEvent {
    let url: String
    let status: String
    let reason: String?
    let quality: String?
}

struct CoursewarePerformanceEvent {
    let url: String
    let phase: String
    let durationMs: Double
    let width: UInt32
    let height: UInt32
    let quality: String
}

struct CoursewareRasterSize {
    let width: UInt32
    let height: UInt32
    let capped: Bool
}

final class ImageCache {
    static let coursewareRasterMaxEdge: CGFloat = 3072
    static let coursewareRasterPreviewMaxEdge: CGFloat = 1024
    static let coursewareRasterDprCap: CGFloat = 3
    static let coursewareRerasterDebounceMs: TimeInterval = 0.18
    private static let bitmapLruLimit = 16
    private static let svgBytesLruLimit = 32
    private static let fetchRequestTimeout: TimeInterval =
        TimeInterval(SyncPolicy.coursewareRefreshHttpTimeoutMs) / 1_000

    private let onLoaded: () -> Void
    private let onError: (String, String) -> Void
    private let onWaitingForSignedUrl: (String) -> Void
    private let onCoursewareStatus: (CoursewareStatusEvent) -> Void
    private let onPerformance: (CoursewarePerformanceEvent) -> Void
    private let authHeaders: (String) -> [String: String]
    private var cache: [String: UIImage] = [:]
    private var cacheOrder: [String] = []
    private var svgBytes: [String: Data] = [:]
    private var svgOrder: [String] = []
    private var loading = Set<String>()
    private var readyQuality: [String: String] = [:]
    private var loadingUrls = Set<String>()
    /** A signed URL that returned 401/403 cannot recover; wait for a freshly signed URL. */
    private var failedUrls: [String: String] = [:]
    private var waitingNotified = Set<String>()
    private let queue = DispatchQueue(label: "io.drawskit.image-cache", qos: .utility, attributes: .concurrent)
    private let rasterQueue = DispatchQueue(label: "io.drawskit.image-cache.raster", qos: .userInitiated)
    private let callbackQueue = DispatchQueue(label: "io.drawskit.image-cache.callbacks", qos: .utility)
    /// Same QoS as `rasterQueue` / `get()` callers so `sync` never inverts to Default.
    private let stateQueue = DispatchQueue(label: "io.drawskit.image-cache.state", qos: .userInitiated)
    private var pendingJobs: [RasterJob] = []
    private var rasterActive = false

    private struct RasterJob {
        let url: String
        let key: String
        let width: UInt32
        let height: UInt32
        let priority: Int
        let quality: String
        let order: Int
        let notifyStatus: Bool
    }

    private var jobOrder = 0

    init(
        onLoaded: @escaping () -> Void,
        onError: @escaping (String, String) -> Void = { _, _ in },
        onWaitingForSignedUrl: @escaping (String) -> Void = { _ in },
        onCoursewareStatus: @escaping (CoursewareStatusEvent) -> Void = { _ in },
        onPerformance: @escaping (CoursewarePerformanceEvent) -> Void = { _ in },
        authHeaders: @escaping (String) -> [String: String] = { _ in [:] }
    ) {
        self.onLoaded = onLoaded
        self.onError = onError
        self.onWaitingForSignedUrl = onWaitingForSignedUrl
        self.onCoursewareStatus = onCoursewareStatus
        self.onPerformance = onPerformance
        self.authHeaders = authHeaders
    }

    func get(_ url: String, width: UInt32 = 0, height: UInt32 = 0) -> UIImage? {
        let key = Self.cacheKey(url, width: width, height: height)
        return stateQueue.sync {
            guard let image = cache[key] else { return nil }
            touchOrder(&cacheOrder, key: key)
            return image
        }
    }

    func getBest(
        _ url: String,
        fullW: UInt32,
        fullH: UInt32,
        previewW: UInt32,
        previewH: UInt32,
        allowPreview: Bool = true
    ) -> UIImage? {
        if let full = get(url, width: fullW, height: fullH) { return full }
        if let covering = findCovering(url, minW: fullW, minH: fullH) { return covering }
        if allowPreview { return get(url, width: previewW, height: previewH) }
        return nil
    }

    func hasSharp(_ url: String, fullW: UInt32, fullH: UInt32) -> Bool {
        guard let image = get(url, width: fullW, height: fullH) ?? findCovering(url, minW: fullW, minH: fullH)
        else { return false }
        let (w, h) = Self.pixelSize(image)
        return Self.isSharpEnough(bitmapW: w, bitmapH: h, targetW: fullW, targetH: fullH)
    }

    private func findCovering(_ url: String, minW: UInt32, minH: UInt32) -> UIImage? {
        stateQueue.sync {
            cache
                .filter { $0.key == url || $0.key.hasPrefix("\(url)#") }
                .map(\.value)
                .filter {
                    let (w, h) = Self.pixelSize($0)
                    return Self.isSharpEnough(bitmapW: w, bitmapH: h, targetW: minW, targetH: minH)
                }
                .min { lhs, rhs in
                    let (lw, lh) = Self.pixelSize(lhs)
                    let (rw, rh) = Self.pixelSize(rhs)
                    return lw * lh < rw * rh
                }
        }
    }

    private static func pixelSize(_ image: UIImage) -> (UInt32, UInt32) {
        let w = UInt32(max(1, (image.size.width * image.scale).rounded()))
        let h = UInt32(max(1, (image.size.height * image.scale).rounded()))
        return (w, h)
    }

    /// Starts loading `url`. Pass `svg: true` for courseware SVG pages.
    func load(
        _ url: String,
        svg: Bool = false,
        width: UInt32 = 0,
        height: UInt32 = 0,
        priority: Int = 10,
        quality: String = "full",
        notifyStatus: Bool = true
    ) {
        let hasCredential = SyncPolicy.coursewareAssetUrlHasAccessCredential(url)
        if !hasCredential {
            if notifyStatus {
                let firstWait = stateQueue.sync { waitingNotified.insert(url).inserted }
                if firstWait { onWaitingForSignedUrl(url) }
            }
            return
        }
        let key = Self.cacheKey(url, width: svg ? width : 0, height: svg ? height : 0)
        let shouldStart: Bool = stateQueue.sync {
            if failedUrls[url] != nil || cache[key] != nil || loading.contains(key) { return false }
            loading.insert(key)
            return true
        }
        guard shouldStart else { return }

        if !svg {
            guard let remote = URL(string: url) else {
                _ = stateQueue.sync { loading.remove(key) }
                report(url, "malformed url")
                return
            }
            queue.async { [weak self] in
                guard let self else { return }
                defer { self.stateQueue.sync { _ = self.loading.remove(key) } }
                let data: Data
                do {
                    data = try self.fetchData(remote)
                } catch {
                    if self.rememberRefreshWait(url, error: error, notifyStatus: true) { return }
                    let reason = error.localizedDescription
                    self.rememberTerminalFailure(url, reason: reason)
                    self.report(url, reason)
                    self.emitError(url, reason)
                    return
                }
                guard let image = UIImage(data: data) else {
                    self.report(url, "image could not be decoded")
                    return
                }
                self.stateQueue.sync { self.setBitmap(key, image) }
                DispatchQueue.main.async { self.onLoaded() }
            }
            return
        }

        stateQueue.sync {
            jobOrder += 1
            pendingJobs.append(
                RasterJob(
                    url: url,
                    key: key,
                    width: width,
                    height: height,
                    priority: priority,
                    quality: quality,
                    order: jobOrder,
                    notifyStatus: notifyStatus
                )
            )
            pendingJobs.sort {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.order < $1.order
            }
        }
        pumpRaster()
    }

    func loadCoursewareProgressive(
        url: String,
        fullW: UInt32,
        fullH: UInt32,
        previewW: UInt32,
        previewH: UInt32,
        priority: Int = 0,
        capped: Bool = false
    ) {
        if stateQueue.sync(execute: { failedUrls[url] != nil }) { return }
        let notify = priority == 0
        if notify { promoteVisiblePage(url) }
        let fullQuality = capped ? "capped" : "full"
        if hasSharp(url, fullW: fullW, fullH: fullH) {
            if notify { emitReady(url, quality: fullQuality) }
            return
        }
        stateQueue.sync {
            if let prev = readyQuality[url], prev == "full" || prev == "capped" {
                readyQuality.removeValue(forKey: url)
            }
        }
        let sameSize = fullW == previewW && fullH == previewH
        let hasPreview = get(url, width: previewW, height: previewH) != nil
        if hasPreview {
            if notify { emitReady(url, quality: "preview") }
        } else {
            if notify { emitLoading(url) }
            if !sameSize {
                load(
                    url, svg: true, width: previewW, height: previewH,
                    priority: priority, quality: "preview", notifyStatus: notify
                )
            }
        }
        load(
            url,
            svg: true,
            width: fullW,
            height: fullH,
            priority: hasPreview || sameSize ? priority : priority + 1,
            quality: fullQuality,
            notifyStatus: notify
        )
    }

    func acknowledgeDrawable(_ url: String, quality: String = "full") {
        _ = stateQueue.sync { loadingUrls.remove(url) }
        emitReady(url, quality: quality)
    }

    func invalidateReady(_ url: String) {
        stateQueue.sync {
            readyQuality.removeValue(forKey: url)
            loadingUrls.remove(url)
        }
    }

    func prefetchSvgBytes(_ url: String) {
        guard SyncPolicy.coursewareAssetUrlHasAccessCredential(url) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let cached: Bool = self.stateQueue.sync {
                self.svgBytes[url] != nil || self.failedUrls[url] != nil
            }
            if cached { return }
            guard let remote = URL(string: url) else { return }
            let data: Data
            do {
                data = try self.fetchData(remote)
            } catch {
                self.rememberTerminalFailure(url, reason: error.localizedDescription)
                return
            }
            self.stateQueue.sync { self.setSvgBytes(url, data) }
        }
    }

    func prefetchCoursewarePages(
        neighborUrls: [String],
        fullW: UInt32,
        fullH: UInt32,
        previewW: UInt32,
        previewH: UInt32,
        capped: Bool = false
    ) {
        var priority = 2
        for neighbor in neighborUrls where !neighbor.isEmpty {
            // Neighbors only need a fast first-paint raster. Full-size work is
            // scheduled if/when the page becomes visible.
            load(
                neighbor,
                svg: true,
                width: previewW,
                height: previewH,
                priority: priority,
                quality: "preview",
                notifyStatus: false
            )
            priority += 1
        }
    }

    private func promoteVisiblePage(_ url: String) {
        stateQueue.sync {
            let stale = pendingJobs.filter { $0.url == url && $0.priority > 0 }
            pendingJobs.removeAll { $0.url == url && $0.priority > 0 }
            for job in stale { loading.remove(job.key) }
        }
    }

    func release() {
        let clear = { [self] in
            cache.removeAll()
            cacheOrder.removeAll()
            svgBytes.removeAll()
            svgOrder.removeAll()
            pendingJobs.removeAll()
            failedUrls.removeAll()
            waitingNotified.removeAll()
        }
        // Destroy may run on main (userInteractive). Never sync-wait a lower queue.
        if Thread.isMainThread {
            stateQueue.async(execute: clear)
        } else {
            stateQueue.sync(execute: clear)
        }
    }

    static func isSharpEnough(
        bitmapW: UInt32,
        bitmapH: UInt32,
        targetW: UInt32,
        targetH: UInt32
    ) -> Bool {
        bitmapW + 1 >= targetW && bitmapH + 1 >= targetH
    }

    /// Device-pixel size for a fitted page.
    /// Pass `deviceScale` = `traitCollection.displayScale` on iOS (not viewport.dpr).
    static func coursewareRasterSize(
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        deviceScale: CGFloat,
        boardScale: CGFloat,
        maxEdge: CGFloat = coursewareRasterMaxEdge
    ) -> CoursewareRasterSize {
        let pageW = pageWidth > 0 ? pageWidth : RenderDefaults.defaultPageWidth
        let pageH = pageHeight > 0 ? pageHeight : RenderDefaults.defaultPageHeight
        let fit: CGFloat = (viewportWidth > 0 && viewportHeight > 0)
            ? min(viewportWidth / pageW, viewportHeight / pageH)
            : 1
        let rawScale = max(deviceScale, 1)
        let density = min(rawScale, coursewareRasterDprCap)
        let scaleClamped = rawScale > coursewareRasterDprCap
        let scale = max(fit, 1e-6) * density * max(boardScale, 1e-6)
        var width = max(1, (pageW * scale).rounded())
        var height = max(1, (pageH * scale).rounded())
        let longest = max(width, height)
        var edgeCapped = false
        if longest > maxEdge {
            edgeCapped = true
            let shrink = maxEdge / longest
            width = max(1, (width * shrink).rounded())
            height = max(1, (height * shrink).rounded())
        }
        return CoursewareRasterSize(
            width: UInt32(width),
            height: UInt32(height),
            capped: scaleClamped || edgeCapped
        )
    }

    private func pumpRaster() {
        let job: RasterJob? = stateQueue.sync {
            guard !rasterActive, let next = pendingJobs.first else { return nil }
            pendingJobs.removeFirst()
            rasterActive = true
            return next
        }
        guard let job else { return }
        rasterQueue.async { [weak self] in
            self?.runRasterJob(job)
            self?.stateQueue.sync { self?.rasterActive = false }
            self?.pumpRaster()
        }
    }

    private func runRasterJob(_ job: RasterJob) {
        defer { stateQueue.sync { _ = loading.remove(job.key) } }

        if stateQueue.sync(execute: { cache[job.key] != nil }) {
            if job.notifyStatus { emitReady(job.url, quality: job.quality) }
            return
        }

        guard let remote = URL(string: job.url) else {
            report(job.url, "malformed url")
            if job.notifyStatus { emitError(job.url, "malformed url") }
            return
        }

        let data: Data
        if let cached = stateQueue.sync(execute: { svgBytes[job.url] }) {
            data = cached
        } else {
            do {
                let startedAt = CFAbsoluteTimeGetCurrent()
                let fetched = try fetchData(remote)
                data = fetched
                stateQueue.sync { setSvgBytes(job.url, fetched) }
                emitPerformance(job, phase: "fetch", startedAt: startedAt)
            } catch {
                if rememberRefreshWait(job.url, error: error, notifyStatus: job.notifyStatus) { return }
                let reason = error.localizedDescription
                rememberTerminalFailure(job.url, reason: reason)
                report(job.url, reason)
                if job.notifyStatus { emitError(job.url, reason) }
                return
            }
        }

        let rasterStartedAt = CFAbsoluteTimeGetCurrent()
        guard let png = NativeEngine.rasterizeCoursewareSvg(data, width: job.width, height: job.height) else {
            report(job.url, "page is not renderable SVG")
            if job.notifyStatus { emitError(job.url, "page is not renderable SVG") }
            return
        }
        emitPerformance(job, phase: "raster", startedAt: rasterStartedAt)
        let decodeStartedAt = CFAbsoluteTimeGetCurrent()
        guard let image = UIImage(data: png) else {
            report(job.url, "image could not be decoded")
            if job.notifyStatus { emitError(job.url, "image could not be decoded") }
            return
        }
        emitPerformance(job, phase: "decode", startedAt: decodeStartedAt)
        stateQueue.sync { setBitmap(job.key, image) }
        if job.notifyStatus { emitReady(job.url, quality: job.quality) }
        DispatchQueue.main.async { self.onLoaded() }
    }

    private func emitPerformance(_ job: RasterJob, phase: String, startedAt: CFAbsoluteTime) {
        let event = CoursewarePerformanceEvent(
            url: job.url,
            phase: phase,
            durationMs: (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000,
            width: job.width,
            height: job.height,
            quality: job.quality
        )
        callbackQueue.async { self.onPerformance(event) }
    }

    private func emitLoading(_ url: String) {
        let should: Bool = stateQueue.sync {
            if let q = readyQuality[url], q == "full" || q == "capped" || q == "preview" { return false }
            if loadingUrls.contains(url) { return false }
            loadingUrls.insert(url)
            return true
        }
        guard should else { return }
        callbackQueue.async {
            self.onCoursewareStatus(CoursewareStatusEvent(url: url, status: "loading", reason: nil, quality: nil))
        }
    }

    private func emitReady(_ url: String, quality: String) {
        let should: Bool = stateQueue.sync {
            loadingUrls.remove(url)
            let prev = readyQuality[url]
            if prev == quality { return false }
            if prev == "full" || prev == "capped" { return false }
            if prev == "preview" && quality == "preview" { return false }
            readyQuality[url] = quality
            return true
        }
        guard should else { return }
        callbackQueue.async {
            self.onCoursewareStatus(
                CoursewareStatusEvent(url: url, status: "ready", reason: nil, quality: quality)
            )
        }
    }

    private func emitError(_ url: String, _ reason: String) {
        _ = stateQueue.sync { loadingUrls.remove(url) }
        callbackQueue.async {
            self.onCoursewareStatus(
                CoursewareStatusEvent(url: url, status: "error", reason: reason, quality: nil)
            )
        }
    }

    private static func cacheKey(_ url: String, width: UInt32, height: UInt32) -> String {
        width > 0 || height > 0 ? "\(url)#\(width)x\(height)" : url
    }

    private func report(_ url: String, _ reason: String) {
        callbackQueue.async { self.onError(url, reason) }
    }

    func forgetAssetFailure(_ url: String) {
        stateQueue.sync {
            failedUrls.removeValue(forKey: url)
            waitingNotified.remove(url)
        }
    }

    private func rememberTerminalFailure(_ url: String, reason: String) {
        guard SyncPolicy.isExpiredCoursewareAsset(url: url, reason: reason, status: nil) else {
            return
        }
        stateQueue.sync { failedUrls[url] = reason }
    }

    private func rememberRefreshWait(_ url: String, error: Error, notifyStatus: Bool) -> Bool {
        let reason = error.localizedDescription
        let status = (error as? ImageFetchError)?.status
        guard SyncPolicy.needsCoursewareAssetRefresh(url: url, reason: reason, status: status) else {
            return false
        }
        stateQueue.sync { failedUrls[url] = reason }
        if notifyStatus {
            onWaitingForSignedUrl(url)
        }
        return true
    }

    /** Synchronous fetch used only from background queues; preserves HTTP status for refresh logic. */
    private func fetchData(_ remote: URL) throws -> Data {
        guard remote.scheme == "http" || remote.scheme == "https" else {
            return try Data(contentsOf: remote)
        }
        var request = URLRequest(url: remote)
        request.timeoutInterval = Self.fetchRequestTimeout
        for (key, value) in authHeaders(remote.absoluteString) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try DrawsKitURLSession.syncData(for: request)
        } catch {
            throw ImageFetchError(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ImageFetchError("HTTP \(http.statusCode)", status: http.statusCode)
        }
        return data
    }

    private func setBitmap(_ key: String, _ image: UIImage) {
        cache[key] = image
        touchOrder(&cacheOrder, key: key)
        while cacheOrder.count > Self.bitmapLruLimit {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func setSvgBytes(_ url: String, _ data: Data) {
        svgBytes[url] = data
        touchOrder(&svgOrder, key: url)
        while svgOrder.count > Self.svgBytesLruLimit {
            let oldest = svgOrder.removeFirst()
            svgBytes.removeValue(forKey: oldest)
        }
    }

    private func touchOrder(_ order: inout [String], key: String) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.append(key)
    }
}

private struct ImageFetchError: LocalizedError {
    let message: String
    let status: Int?
    init(_ message: String, status: Int? = nil) {
        self.message = message
        self.status = status
    }
    var errorDescription: String? { message }
}
