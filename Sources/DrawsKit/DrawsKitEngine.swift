import UIKit

/// Rust engine wiring: PlatformEvent JSON → FFI → RenderMessage → [DrawsKitView].
final class DrawsKitEngine {
    let initParams: DrawsKitInitParams
    private let emit: (String, [Any]) -> Void

    private var session: NativeEngine.EngineSession?
    private weak var view: DrawsKitView?
    private var destroyed = false
    private var bootstrapped = false
    private var bootstrapping = false
    private let bootstrapSemaphore = DispatchSemaphore(value: 0)
    private var bootstrapError: Error?

    private var lastFrame: [String: Any]?
    private var drawEnabled = false
    private var serverCanDraw = true
    private var requestedDrawEnabled = true
    /// Cloud: false until `loadInitialHistory` succeeds (Web-aligned). Local sets true in bootstrap.
    private var historyReady = false
    private var initScaleRange = (EngineDefaults.defaultScaleMin, EngineDefaults.defaultScaleMax)
    private var enableScaleTool = true
    private var actionReporter: ActionReporter?
    private let cloudBootstrapQueue = DispatchQueue(label: "io.drawskit.cloud-bootstrap", qos: .userInitiated)
    /// Native callbacks, JSON parsing/materialization and sync policy stay off UIKit's main thread.
    private let engineCallbackQueue = DispatchQueue(label: "io.drawskit.engine-callback", qos: .userInitiated)

    private var lastCanUndo: Bool?
    private var lastCanRedo: Bool?
    private var lastSelectedIds: [String]?
    private var lastBoardIds: [String]?
    private var lastCurrentBoardId: String?
    private var lastViewportScale: Int?
    private var lastViewportScroll: (Float, Float)?
    private var lastViewportSize: (width: Int, height: Int, dpr: CGFloat)?

    private var panDragOrigin: (Float, Float)?
    private let pointerTimestamps = GestureTimestampMapper()
    private var requestedToolKind: String?
    private var pendingTextValue = ""
    private var editingTextId: String?
    private var textOverlay: TextInputOverlay?
    private var coursewareHost: CoursewareHost?
    private var mediaHost: MediaHost?
    private let mediaSync = MediaSync()
    private var coursewareLoading: CoursewareLoadingOverlay?
    private var bootstrapLoading: BootstrapLoadingOverlay?
    private var bootstrapErrorOverlay: BootstrapErrorOverlay?
    private var syncCoordinator: SyncCoordinator?
    private var imBridge: ImBridge?
    private var roomApiClient: RoomApiClient?
    private var activeRecordingId: String?
    private weak var boardContainer: UIView?
    private var currentCoursewareFileId: String?
    private let cursorController = CursorController()
    let operationLogger: OperationLogger

    private lazy var imageCache = ImageCache(
        onLoaded: { [weak self] in
            DispatchQueue.main.async {
                guard let self, let renderer = self.renderer, let frame = self.lastFrame else { return }
                renderer.prepareSharedVectorLayer(frame: frame)
            }
        },
        onError: { [weak self] url, reason in
            self?.emit(DrawsKitConstants.EVENT.DK_WARNING, [[
                "code": DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_ASSET_LOAD_FAILED,
                "message": "\(reason) (\(url))",
            ]])
        },
        onWaitingForSignedUrl: { [weak self] url in
            guard let self else { return }
            let fileId = CoursewareRead.getCoursewareLayer(self.lastFrame)?.string("resource_id")
            let resolved = (fileId?.isEmpty == false ? fileId! : (self.currentCoursewareFileId ?? ""))
            guard !resolved.isEmpty else { return }
            self.syncCoordinator?.onCoursewareAssetFailed(
                fileId: resolved,
                url: url,
                reason: SyncPolicy.coursewareWaitingForSignedUrl
            )
        },
        onCoursewareStatus: { [weak self] event in
            guard let self else { return }
            let layer = CoursewareRead.getCoursewareLayer(self.lastFrame)
            let fileId = layer?.string("resource_id").isEmpty == false
                ? layer!.string("resource_id")
                : (self.currentCoursewareFileId ?? "")
            let pageIndex: Int = {
                if layer?.string("image_url") == event.url {
                    return layer?.int("page_index") ?? 0
                }
                return self.pageIndexForUrl(event.url, fileId: fileId)
            }()
            self.emit(
                DrawsKitConstants.EVENT.DK_COURSEWARE_STATUS_CHANGED,
                [[
                    "id": self.initParams.id,
                    "fileId": fileId,
                    "pageIndex": pageIndex,
                    "status": event.status,
                    "reason": event.reason as Any,
                    "quality": event.quality as Any,
                ]]
            )
            if event.status == "error", !fileId.isEmpty {
                self.syncCoordinator?.onCoursewareAssetFailed(
                    fileId: fileId,
                    url: event.url,
                    reason: event.reason ?? ""
                )
            }
            let layerUrl = layer?.string("image_url")
            let visiblePage = layer?.int("page_index") ?? 0
            let isVisible =
                event.url == layerUrl ||
                pageIndex == visiblePage ||
                ((layerUrl == nil || layerUrl?.isEmpty == true) && pageIndex == 0)
            if event.status == "loading", isVisible {
                self.coursewareLoading?.show(message: "课件加载中…（第 \(pageIndex + 1) 步）")
            } else if event.status == "ready" || event.status == "error" {
                self.coursewareLoading?.hide()
            }
        },
        onPerformance: { [weak self] event in
            self?.operationLogger.action(
                "courseware.asset.\(event.phase)",
                phase: "ok",
                result: "ok",
                detail: [
                    "url": event.url,
                    "duration_ms": event.durationMs.rounded(),
                    "width": event.width,
                    "height": event.height,
                    "quality": event.quality,
                ]
            )
        },
        authHeaders: { [weak self] url in
            self?.roomApiClient?.authorizedHeaders(for: url) ?? [:]
        }
    )
    /// detach 期间为 nil；禁止用 IUO，横竖屏切换时旧 surface 仍可能 draw。
    private var renderer: SharedRasterRenderer?

    init(initParams: DrawsKitInitParams, emit: @escaping (String, [Any]) -> Void) {
        self.initParams = initParams
        self.emit = emit
        self.operationLogger = OperationLogger(
            sid: OperationLogger.createSessionId(),
            boardId: initParams.roomId,
            userId: initParams.userId,
            clientId: initParams.userId
        )
    }

    func attachView(_ drawsKitView: DrawsKitView, boardContainer: UIView? = nil) {
        guard !destroyed else { return }
        let root = boardContainer ?? drawsKitView.superview
        // 同一 surface 被 SwiftUI 重新挂到新 host（横竖屏）：保留 renderer / lastFrame，只刷新容器与尺寸。
        if view === drawsKitView {
            relayoutAttachedSurface(boardContainer: root)
            return
        }
        if view != nil {
            // 已绑定其他 surface：先卸下，保留引擎会话。
            detachView()
        }
        view = drawsKitView
        self.boardContainer = root
        let preloadDepth = (initParams.config?["preloadDepth"] as? Int) ?? 2
        renderer = SharedRasterRenderer(
            host: drawsKitView,
            imageCache: imageCache,
            onSceneGap: { [weak self] _, _ in
                self?.send(PlatformEvents.withType(PlatformEventType.setRenderCapabilities) { payload in
                    payload["scene_delta"] = true
                    payload["scene_delta_version"] = ProtocolVersions.sceneDelta
                })
            },
            preloadDepth: preloadDepth
        )
        drawsKitView.bindEngine(self)
        if let auth = initParams.config?["authConfig"] as? [String: Any] {
            cursorController.setSystemCursorEnable(auth["systemCursorEnable"] as? Bool ?? true)
            requestedDrawEnabled = auth["drawEnable"] as? Bool ?? true
            if auth["progressEnable"] as? Bool == true {
                coursewareLoading?.destroy()
                coursewareLoading = CoursewareLoadingOverlay(host: drawsKitView)
            }
        }
        // Web-aligned: no drawing until historyReady ∩ serverCanDraw ∩ drawEnable.
        applyDrawPermission()
        bootstrapLoading?.destroy()
        bootstrapErrorOverlay?.destroy()
        if let root {
            bootstrapLoading = BootstrapLoadingOverlay(host: root)
            bootstrapErrorOverlay = BootstrapErrorOverlay(host: root)
        }
        cursorController.attach(to: drawsKitView)
        recreateCoursewareHost(boardRoot: root, drawsKitView: drawsKitView)
        if bootstrapped {
            send(PlatformEvents.simple("surface_created"))
        } else {
            bootstrapIfNeeded()
        }
        // Always re-sync after attach: import leaves Core on the default
        // 16:9 page viewport, and a reused surface may still report the
        // previous host's bounds for one turn.
        scheduleResizeAndDisplay(drawsKitView)
    }

    /// 会话级 surface 换父视图后调用：不重建 renderer，避免 scene_delta gap 清空画面。
    private func relayoutAttachedSurface(boardContainer root: UIView?) {
        guard let drawsKitView = view else { return }
        if root !== boardContainer {
            boardContainer = root
            recreateCoursewareHost(boardRoot: root, drawsKitView: drawsKitView)
            // 换父后下一 runloop 再 resize；同容器的 SwiftUI update 只重绘，尺寸走 layoutSubviews。
            scheduleResizeAndDisplay(drawsKitView)
            return
        }
        drawsKitView.setNeedsDisplay()
    }

    private func recreateCoursewareHost(boardRoot: UIView?, drawsKitView: DrawsKitView) {
        coursewareHost?.destroy()
        coursewareHost = nil
        guard let boardRoot else { return }
        coursewareHost = CoursewareHost(
            boardRoot: boardRoot,
            drawsKitView: drawsKitView,
            send: { [weak self] json in self?.send(json) },
            onCoursewareStatus: { [weak self] fileId, status, url in
                guard let self else { return }
                self.emit(
                    DrawsKitConstants.EVENT.DK_H5FILE_STATUS_CHANGED,
                    [[
                        "id": self.initParams.id,
                        "fileId": fileId ?? "",
                        "status": status,
                        "url": url,
                    ]]
                )
            }
        )
        mediaHost = MediaHost(boardRoot: boardRoot, drawsKitView: drawsKitView)
        mediaHost?.onVideoStatus = { [weak self] payload in
            self?.emit(DrawsKitConstants.EVENT.DK_VIDEO_STATUS_CHANGED, [payload])
            self?.mediaSync.onLocalStatus(payload)
        }
        mediaHost?.onAudioStatus = { [weak self] payload in
            self?.emit(DrawsKitConstants.EVENT.DK_AUDIO_STATUS_CHANGED, [payload])
            self?.emit(DrawsKitConstants.EVENT.DK_H5PPT_MEDIA_STATUS_CHANGED, [payload])
            self?.mediaSync.onLocalStatus(payload)
        }
        mediaSync.setSnapshot { [weak self] in self?.mediaHost?.snapshot() ?? [] }
    }

    private func scheduleResizeAndDisplay(_ drawsKitView: DrawsKitView) {
        drawsKitView.setNeedsDisplay()
        DispatchQueue.main.async { [weak self, weak drawsKitView] in
            guard let self, let drawsKitView, self.view === drawsKitView else { return }
            self.resizeToView()
            drawsKitView.setNeedsDisplay()
        }
    }

    /// 当前绑定的 surface；detach 后为 nil。
    var attachedView: DrawsKitView? { view }

    /// 卸下 UI surface，不销毁引擎会话。用于横竖屏切换时 SwiftUI 重建 `DrawsKitView`。
    /// - Parameter onlyIfView: 非 nil 时仅当仍绑定该 view 才 detach，避免旧 dismantle 卸掉新 surface。
    func detachView(onlyIfView expected: DrawsKitView? = nil) {
        guard !destroyed, let current = view else { return }
        if let expected, current !== expected { return }
        closeTextOverlay()
        coursewareHost?.destroy()
        coursewareHost = nil
        mediaHost?.destroy()
        mediaHost = nil
        mediaSync.destroy()
        coursewareLoading?.destroy()
        coursewareLoading = nil
        bootstrapLoading?.destroy()
        bootstrapLoading = nil
        bootstrapErrorOverlay?.destroy()
        bootstrapErrorOverlay = nil
        cursorController.detach()
        send(PlatformEvents.simple("surface_destroyed"))
        // 先解绑再清 renderer：布局过渡期 UIKit 仍可能对旧 view 调 draw。
        current.bindEngine(nil)
        renderer?.destroy()
        renderer = nil
        view = nil
        boardContainer = nil
    }

    func awaitReady(timeout: TimeInterval = EngineDefaults.engineBootstrapTimeout) -> Bool {
        if bootstrapped && bootstrapError == nil { return true }
        if Thread.isMainThread { return false }
        let deadline = DispatchTime.now() + timeout
        _ = bootstrapSemaphore.wait(timeout: deadline)
        return bootstrapped && bootstrapError == nil
    }

    private func applyDrawPermission() {
        drawEnabled = historyReady && serverCanDraw && requestedDrawEnabled
        cursorController.setDrawEnabled(drawEnabled)
    }

    private func bootstrapIfNeeded() {
        guard !bootstrapped, !destroyed, !bootstrapping, view != nil else { return }
        bootstrapping = true

        let productEdition = (initParams.config?["productEdition"] as? String)
            ?? DrawsKitConstants.ProductEdition.DRAWSKIT_PRODUCT_EDITION_CLOUD
        let isLocalEdition =
            productEdition == DrawsKitConstants.ProductEdition.DRAWSKIT_PRODUCT_EDITION_LOCAL

        if isLocalEdition {
            cloudBootstrapQueue.async { [weak self] in
                guard let self else { return }
                do {
                    self.operationLogger.action("sdk.init", phase: "start")
                    try self.verifyLocalLicense()
                    if let auth = self.initParams.config?["authConfig"] as? [String: Any] {
                        self.requestedDrawEnabled = auth["drawEnable"] as? Bool ?? true
                        self.enableScaleTool = auth["enableScaleTool"] as? Bool ?? true
                    }
                    self.serverCanDraw = true
                    self.historyReady = true
                    self.drawEnabled = self.serverCanDraw && self.requestedDrawEnabled
                    try self.createEngineAndSync(isLocalEdition: true, roomApi: nil, dataSyncEnable: false)
                    DispatchQueue.main.async {
                        self.applyDrawPermission()
                        self.finishBootstrapSuccess(hasRoomApi: false)
                        self.bootstrapping = false
                        self.bootstrapSemaphore.signal()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.failBootstrap(error)
                        self.bootstrapping = false
                        self.bootstrapSemaphore.signal()
                    }
                }
            }
            return
        }

        if initParams.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failBootstrap(NSError(
                domain: "DrawsKit",
                code: DrawsKitConstants.ErrorCode.DRAWSKIT_ERROR_AUTH,
                userInfo: [NSLocalizedDescriptionKey: "token is required for cloud productEdition"]
            ))
            bootstrapping = false
            bootstrapSemaphore.signal()
            return
        }

        showBootstrapLoading()

        cloudBootstrapQueue.async { [weak self] in
            guard let self else { return }
            do {
                self.operationLogger.action("sdk.init", phase: "start")
                guard let roomApi = RoomApiClient.fromInitParams(self.initParams) else {
                    throw NSError(
                        domain: "DrawsKit",
                        code: DrawsKitConstants.ErrorCode.DRAWSKIT_ERROR_AUTH,
                        userInfo: [NSLocalizedDescriptionKey: "无法解析 SDK 服务地址"]
                    )
                }
                self.roomApiClient = roomApi
                roomApi.onAuthExpired = { [weak self] in
                    // init 阶段 401 已走 DK_ERROR AUTH；仅运行时过期才回传给宿主换发。
                    guard let self, self.bootstrapped else { return }
                    self.emit(DrawsKitConstants.EVENT.DK_AUTH_EXPIRED, [["id": self.initParams.id]])
                }
                let reporter = ActionReporter(
                    roomApi: roomApi,
                    config: ActionReporterConfig(
                        enabled: false,
                        sdkVersion: DrawsKit.getVersion(),
                        engineVersion: DrawsKit.getEngineVersion()
                    )
                )
                self.actionReporter = reporter
                self.operationLogger.setActionSink { [weak reporter] event in
                    reporter?.enqueue(event)
                }

                let session = try roomApi.fetchSession()
                let mismatched: String? = {
                    if session.appId != self.initParams.appid.trimmingCharacters(in: .whitespacesAndNewlines) {
                        return "appid"
                    }
                    if session.roomId != self.initParams.roomId.trimmingCharacters(in: .whitespacesAndNewlines) {
                        return "roomId"
                    }
                    if session.userId != self.initParams.userId.trimmingCharacters(in: .whitespacesAndNewlines) {
                        return "userId"
                    }
                    return nil
                }()
                if let mismatched {
                    throw NSError(
                        domain: "DrawsKit",
                        code: DrawsKitConstants.ErrorCode.DRAWSKIT_ERROR_AUTH,
                        userInfo: [NSLocalizedDescriptionKey: "\(mismatched) 与 Room Token 不一致"]
                    )
                }
                self.serverCanDraw = session.permissions.canDraw
                let sessionCanSync = session.permissions.canSync
                reporter.configure(
                    enabled: session.permissions.canReportActions &&
                        session.actionReport?.enabled != false,
                    batchSize: session.actionReport?.batchSize,
                    flushIntervalMs: session.actionReport?.flushIntervalMs
                )

                if let auth = self.initParams.config?["authConfig"] as? [String: Any] {
                    self.requestedDrawEnabled = auth["drawEnable"] as? Bool ?? true
                    self.enableScaleTool = auth["enableScaleTool"] as? Bool ?? true
                }
                self.historyReady = false
                self.drawEnabled = false
                let authConfig = self.initParams.config?["authConfig"] as? [String: Any]
                let dataSyncEnable =
                    (authConfig?["dataSyncEnable"] as? Bool ?? true) && sessionCanSync
                try self.createEngineAndSync(
                    isLocalEdition: false,
                    roomApi: roomApi,
                    dataSyncEnable: dataSyncEnable
                )

                guard let coordinator = self.syncCoordinator, coordinator.loadInitialHistory() else {
                    throw NSError(
                        domain: "DrawsKit",
                        code: DrawsKitConstants.ErrorCode.DRAWSKIT_ERROR_INIT,
                        userInfo: [NSLocalizedDescriptionKey: "白板数据加载失败，请稍后重试"]
                    )
                }

                DispatchQueue.main.async {
                    self.historyReady = true
                    self.applyDrawPermission()
                    self.finishBootstrapSuccess(hasRoomApi: true)
                    self.bootstrapping = false
                    self.bootstrapSemaphore.signal()
                }
            } catch {
                DispatchQueue.main.async {
                    self.failBootstrap(error)
                    self.bootstrapping = false
                    self.bootstrapSemaphore.signal()
                }
            }
        }
    }

    private func verifyLocalLicense() throws {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        switch LicenseVerifier.verify(
            license: initParams.license,
            appid: initParams.appid,
            binding: LicenseRuntimeBinding(iosBundleId: bundleId)
        ) {
        case .err(let code, let message):
            emit(DrawsKitConstants.EVENT.DK_LICENSE_INVALID, [[
                "id": initParams.id,
                "code": code,
                "message": message,
            ]])
            throw NSError(domain: "DrawsKit", code: DrawsKitConstants.ErrorCode.DRAWSKIT_ERROR_LICENSE, userInfo: [
                NSLocalizedDescriptionKey: "license invalid: \(code) (\(message))",
            ])
        case .ok(let claims):
            emit(DrawsKitConstants.EVENT.DK_LICENSE_OK, [[
                "id": initParams.id,
                "licenseId": claims["licenseId"] as? String ?? "",
                "appid": claims["appid"] as? String ?? "",
            ]])
        }
    }

    private func createEngineAndSync(
        isLocalEdition: Bool,
        roomApi: RoomApiClient?,
        dataSyncEnable: Bool
    ) throws {
        let documentId = initParams.roomId
        NativeEngine.setEngineLogSink { [weak self] line in
            self?.operationLogger.ingestLine(line)
        }
        guard let session = NativeEngine.EngineSession(
            documentId: documentId,
            onFrame: { [weak self] json in
                self?.engineCallbackQueue.async { [weak self] in self?.onEngineFrame(json) }
            },
            onSyncOut: { [weak self] json in
                self?.engineCallbackQueue.async { [weak self] in self?.onSyncEnvelope(json) }
            },
            onLiveStrokeOut: { [weak self] json in
                self?.engineCallbackQueue.async { [weak self] in
                    self?.syncCoordinator?.onLocalLiveStrokeOut(json)
                }
            }
        ) else {
            throw NSError(domain: "DrawsKit", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create native engine (is libwhiteboard_ffi linked?)",
            ])
        }
        self.session = session
        operationLogger.action("engine.create", phase: "ok", result: "ok", detail: ["document_id": documentId])

        let syncFps = (initParams.config?["syncFps"] as? NSNumber)?.intValue ?? 25
        let imTransport = isLocalEdition ? nil : initParams.imTransport
        let authConfig = initParams.config?["authConfig"] as? [String: Any]
        let checkpointUploadEnable = authConfig?["checkpointUploadEnable"] as? Bool ?? true
        let liveStrokeEnable = initParams.config?["liveStrokeEnable"] as? Bool ?? true
        let liveStrokeBudgetQps = (initParams.config?["liveStrokeBudgetQps"] as? NSNumber)?.intValue
        let liveStrokeSingleShotMaxMs =
            (initParams.config?["liveStrokeSingleShotMaxMs"] as? NSNumber)?.int64Value
        self.syncCoordinator = try SyncCoordinator(
            roomId: initParams.roomId,
            clientId: initParams.userId,
            emitEvent: self.emit,
            warn: { [weak self] code, message in
                guard let self else { return }
                self.emit(DrawsKitConstants.EVENT.DK_WARNING, [[
                    "code": code,
                    "message": message,
                    "id": self.initParams.id,
                ]])
            },
            sendJson: { [weak self] json in self?.send(json) },
            roomApi: roomApi,
            imTransport: imTransport,
            dataSyncEnable: dataSyncEnable,
            syncFps: syncFps,
            checkpointUploadEnable: checkpointUploadEnable,
            liveStrokeEnable: liveStrokeEnable,
            liveStrokeBudgetQps: liveStrokeBudgetQps,
            liveStrokeSingleShotMaxMs: liveStrokeSingleShotMaxMs,
            exportWorkspace: { [weak self] in
                guard let self, let session = self.session else { return nil }
                guard let json = session.exportWorkspaceJson(roomId: self.initParams.roomId, checkpointSeq: 0) else {
                    return nil
                }
                return JSONCodec.parseObject(json)
            },
            importWorkspace: { [weak self] workspace in
                self?.send(PlatformEvents.withType(PlatformEventType.importWorkspace) { payload in
                    payload["workspace"] = workspace
                    payload["bootstrap"] = true
                })
            },
            log: operationLogger,
            prefetchCoursewarePage: { [weak self] url, format in
                guard let self else { return }
                let layerUrl = CoursewareRead.getCoursewareLayer(self.lastFrame)?.string("image_url")
                if let layerUrl, !layerUrl.isEmpty {
                    self.imageCache.forgetAssetFailure(layerUrl)
                }
                self.kickCoursewarePageLoad(url: url, format: format)
            }
        )
        send(PlatformEvents.simple("surface_created"))
        send(PlatformEvents.withType(PlatformEventType.setRenderCapabilities) { payload in
            payload["scene_delta"] = true
            payload["scene_delta_version"] = ProtocolVersions.sceneDelta
        })
        send(PlatformEvents.withType(PlatformEventType.setCollabContext) { payload in
            payload["user_id"] = initParams.userId
            payload["client_id"] = initParams.userId
        })
        syncCoordinator?.sendCollaborationEnabled()
        resizeToView()
        applyInitConfig()
        // A transport may synchronously deliver buffered messages while its
        // callback is registered. Attach only after the native engine has its
        // collaboration identity and gate, or the first committed path can
        // bypass live-stroke playout and appear in full.
        if let transport = imTransport, let coordinator = self.syncCoordinator {
            let bridge = ImBridge(transport: transport, coordinator: coordinator)
            bridge.setMediaInbound { [weak self] payload in
                self?.applyMediaSyncInbound(payload) ?? false
            }
            self.imBridge = bridge
            self.mediaSync.setTransport { [weak self] message in
                self?.initParams.imTransport?.send(message)
            }
            // Keep registration last: onMessage is allowed to replay a buffered
            // payload synchronously.
            bridge.attach()
        }
        operationLogger.action(
            "config.apply",
            phase: "ok",
            result: "ok",
            detail: [
                "draw_enable": drawEnabled,
                "data_sync": dataSyncEnable,
                "has_room_api": roomApi != nil,
            ]
        )
    }

    private func finishBootstrapSuccess(hasRoomApi: Bool) {
        bootstrapped = true
        bootstrapError = nil
        hideBootstrapLoading()
        bootstrapErrorOverlay?.hide()
        if let drawsKitView = view {
            scheduleResizeAndDisplay(drawsKitView)
        }
        emit(DrawsKitConstants.EVENT.DK_INIT, [[
            "id": initParams.id,
            "roomId": initParams.roomId,
            "userId": initParams.userId,
            "sdkVersion": DrawsKit.getVersion(),
            "engineVersion": DrawsKit.getEngineVersion(),
        ]])
        operationLogger.action(
            "sdk.init",
            phase: "ok",
            result: "ok",
            detail: [
                "sdk_version": DrawsKit.getVersion(),
                "engine_version": DrawsKit.getEngineVersion(),
                "has_room_api": hasRoomApi,
            ]
        )
    }

    private func showBootstrapLoading() {
        let show = { [weak self] in
            guard let self else { return }
            let overlay = self.bootstrapLoading
                ?? self.boardContainer.map { BootstrapLoadingOverlay(host: $0) }
                ?? self.view.map { BootstrapLoadingOverlay(host: $0) }
            if let overlay {
                self.bootstrapLoading = overlay
                overlay.show()
            }
        }
        if Thread.isMainThread {
            show()
        } else {
            DispatchQueue.main.async(execute: show)
        }
    }

    private func hideBootstrapLoading() {
        let hide: () -> Void = { [weak self] in
            self?.bootstrapLoading?.hide()
        }
        if Thread.isMainThread {
            hide()
        } else {
            DispatchQueue.main.async(execute: hide)
        }
    }

    private func failBootstrap(_ error: Error) {
        bootstrapError = error
        historyReady = false
        applyDrawPermission()
        let message = error.localizedDescription
        let showOverlay = { [weak self] in
            guard let self else { return }
            self.hideBootstrapLoading()
            let overlay = self.bootstrapErrorOverlay
                ?? self.boardContainer.map { BootstrapErrorOverlay(host: $0) }
                ?? self.view.map { BootstrapErrorOverlay(host: $0) }
            if let overlay {
                self.bootstrapErrorOverlay = overlay
                overlay.show(message: message)
            }
        }
        if Thread.isMainThread {
            showOverlay()
        } else {
            DispatchQueue.main.async(execute: showOverlay)
        }
        operationLogger.action(
            "sdk.init",
            phase: "fail",
            result: "error",
            level: 1,
            detail: ["message": message]
        )
        emit(DrawsKitConstants.EVENT.DK_ERROR, [[
            "code": DrawsKitConstants.ErrorCode.DRAWSKIT_ERROR_INIT,
            "message": message,
        ]])
    }

    private func applyInitConfig() {
        guard let config = initParams.config else { return }
        if let scaleRange = config["scaleRange"] as? [Any], scaleRange.count >= 2 {
            let minV = (scaleRange[0] as? NSNumber)?.intValue ?? EngineDefaults.defaultScaleMin
            let maxV = (scaleRange[1] as? NSNumber)?.intValue ?? EngineDefaults.defaultScaleMax
            initScaleRange = (minV, maxV)
            send(PlatformEvents.withType(PlatformEventType.setScaleRange) { payload in
                payload["min"] = minV
                payload["max"] = maxV
            })
        }
        if let ratio = config["ratio"] as? String {
            send(PlatformEvents.withType(PlatformEventType.setBoardRatio) { $0["ratio"] = ratio })
        }
        if let boardScale = (config["boardScale"] as? NSNumber)?.intValue {
            send(PlatformEvents.withType(PlatformEventType.setBoardScale) { $0["scale"] = boardScale })
        }
        if let styleConfig = config["styleConfig"] as? [String: Any] {
            if let thin = (styleConfig["brushThin"] as? NSNumber)?.intValue {
                send(PlatformEvents.withType(PlatformEventType.setBrushThin) { $0["thin"] = max(0, min(thin, EngineDefaults.industryUnitMax)) })
            }
            if let color = styleConfig["brushColor"] as? String {
                send(PlatformEvents.withType(PlatformEventType.setBrushColor) { $0["color"] = color })
                send(PlatformEvents.withType(PlatformEventType.setGraphColor) { $0["color"] = color })
            }
        }
        if let toolType = (config["toolType"] as? NSNumber)?.intValue {
            setToolType(toolType)
        }
    }

    func onSizeChanged(width: CGFloat, height: CGFloat) {
        guard width > 0, height > 0 else { return }
        let logicalW = max(Int(width), 1)
        let logicalH = max(Int(height), 1)
        let dpr = max(view?.window?.screen.scale ?? UIScreen.main.scale, 1)
        if let lastViewportSize,
           lastViewportSize.width == logicalW,
           lastViewportSize.height == logicalH,
           abs(lastViewportSize.dpr - dpr) < 0.001 {
            return
        }
        lastViewportSize = (logicalW, logicalH, dpr)
        send(PlatformEvents.viewportResize(width: logicalW, height: logicalH, dpr: Float(dpr)))
    }

    private func resizeToView() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.resizeToView() }
            return
        }
        guard let view else { return }
        onSizeChanged(width: max(view.bounds.width, 1), height: max(view.bounds.height, 1))
    }

    private func onEngineFrame(_ json: String) {
        guard !destroyed, let rawFrame = JSONCodec.parseObject(json) else { return }
        syncCoordinator?.onEngineEffects(rawFrame["effects"] as? [[String: Any]])
        // detach 期间无 renderer：跳过绘制与 UI 同步事件。
        guard let renderer else { return }
        let frame = renderer.materialize(rawFrame)
        renderer.prepareSharedVectorLayer(frame: frame)
        if let delta = rawFrame["scene_delta"] as? [String: Any] {
            let upserts = (delta["upserts"] as? [Any])?.count ?? 0
            let fullSnapshot = delta["full_snapshot"] as? Bool ?? false
            if fullSnapshot || upserts > 0 {
                let shapeCount = (frame["layers"] as? [Any])?.reduce(into: 0) { count, item in
                    guard let layer = item as? [String: Any],
                          layer["type"] as? String == "shapes" else { return }
                    count += (layer["shapes"] as? [Any])?.count ?? 0
                } ?? 0
                NSLog(
                    "[DrawsKit/render] frame fullSnapshot=%@ upserts=%d materializedShapes=%d gap=%@",
                    fullSnapshot ? "true" : "false",
                    upserts,
                    shapeCount,
                    renderer.lastMaterializeWasGap ? "true" : "false"
                )
            }
        }
        let materializeWasGap = renderer.lastMaterializeWasGap
        DispatchQueue.main.async { [weak self, weak renderer] in
            guard let self, !self.destroyed, renderer === self.renderer else { return }
            // scene-gap 时 materialize 会交出空 layers；保留上一帧画面，等 full snapshot 再替换。
            if materializeWasGap {
                if self.lastFrame == nil { self.lastFrame = frame }
            } else {
                self.lastFrame = frame
            }
            self.syncViewportEvents(frame)
            if let requested = self.requestedToolKind,
               SessionRead.getActiveToolKind(frame) == requested {
                self.requestedToolKind = nil
            }
            self.coursewareHost?.sync(self.lastFrame ?? frame)
            self.mediaHost?.sync(self.lastFrame ?? frame)
            self.invalidateDirty(frame)
            self.syncHistoryEvents(frame)
            self.syncSelectionEvents(frame)
            self.syncBoardEvents(frame)
        }
    }

    func render(in context: CGContext) {
        guard let renderer, let frame = lastFrame else { return }
        renderer.render(in: context)
    }

    private func invalidateDirty(_ frame: [String: Any]) {
        guard let view else { return }
        guard let viewport = frame.dict("viewport"),
              let dirty = frame["dirty_rects"] as? [[String: Any]] else {
            view.setNeedsDisplay()
            return
        }
        let delta = frame.dict("scene_delta")
        // A snapshot replaces the renderer's complete retained scene. Core's
        // viewport-wide dirty rect is already expressed in local viewport
        // coordinates; applying the canonical board-fit transform to it again
        // clips redraw to the top-left portion on compact iOS surfaces.
        if delta?.bool("full_snapshot") == true {
            view.setNeedsDisplay()
            return
        }
        let deltaChanged = dirty.isEmpty &&
            (!(delta?["upserts"] as? [Any] ?? []).isEmpty ||
                !(delta?["removed_ids"] as? [Any] ?? []).isEmpty)
        if deltaChanged {
            view.setNeedsDisplay()
            return
        }
        guard !dirty.isEmpty else { return }

        let scale = max(CGFloat(viewport.double("scale", default: 100) / 100), 0.0001)
        let offsetX = CGFloat(viewport.double("offset_x"))
        let offsetY = CGFloat(viewport.double("offset_y"))
        let content = ViewportCoords.contentTransform(frame: frame)
        let contentScale = CGFloat(content?.scale ?? 1)
        let contentOffsetX = CGFloat(content?.offsetX ?? 0)
        let contentOffsetY = CGFloat(content?.offsetY ?? 0)
        var union = CGRect.null
        for world in dirty {
            let rect = CGRect(
                x: (CGFloat(world.double("x")) * contentScale + contentOffsetX) * scale + offsetX - 2,
                y: (CGFloat(world.double("y")) * contentScale + contentOffsetY) * scale + offsetY - 2,
                width: CGFloat(world.double("width")) * contentScale * scale + 4,
                height: CGFloat(world.double("height")) * contentScale * scale + 4
            )
            union = union.union(rect)
        }
        let clipped = union.intersection(view.bounds)
        if !clipped.isNull, !clipped.isEmpty { view.setNeedsDisplay(clipped) }
    }

    func send(_ json: String) {
        guard !destroyed else { return }
        engineCallbackQueue.async { [weak self] in
            guard let self, !self.destroyed else { return }
            _ = self.session?.send(json: json)
        }
    }

    private func onSyncEnvelope(_ json: String) {
        syncCoordinator?.onLocalSyncOut(json)
    }

    func addSyncData(_ data: Any) { syncCoordinator?.addSyncData(data) }
    func addAckData(_ data: Any) { syncCoordinator?.addAckData(data) }
    func syncAndReload() { syncCoordinator?.syncAndReload() }
    func renderHistoryData(_ data: Any) { syncCoordinator?.renderHistoryData(data) }
    func getSyncTime() -> Int { syncCoordinator?.getSyncTime() ?? 0 }
    func setSyncFps(_ fps: Int) { syncCoordinator?.setSyncFps(fps) }
    func isDataSyncEnable() -> Bool { syncCoordinator?.isDataSyncEnable() ?? true }
    func setDataSyncEnable(_ enable: Bool) { syncCoordinator?.setDataSyncEnable(enable) }

    func getPendingSyncOpsCount() -> Int { syncCoordinator?.getPendingSyncOpsCount() ?? 0 }

    func clearLocalSyncOutbox() { syncCoordinator?.clearLocalSyncOutbox() }

    func updateCredentials(_ token: String) throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw NSError(
                domain: "DrawsKit",
                code: 39,
                userInfo: [NSLocalizedDescriptionKey: "Room Token is required"]
            )
        }
        guard let api = roomApiClient else {
            throw NSError(
                domain: "DrawsKit",
                code: 40,
                userInfo: [NSLocalizedDescriptionKey: "Room API unavailable; cannot update credentials"]
            )
        }
        api.updateToken(normalized)
        syncCoordinator?.onCredentialsUpdated()
    }

    func getActiveRecordingId() -> String? { activeRecordingId }

    func startRecording(externalRef: String? = nil) throws -> RecordingSession {
        guard let api = roomApiClient else {
            throw NSError(
                domain: "DrawsKit",
                code: 37,
                userInfo: [NSLocalizedDescriptionKey: "Room API unavailable; cannot start recording"]
            )
        }
        let session = try api.startRecording(externalRef: externalRef)
        activeRecordingId = session.recordingId
        return session
    }

    func stopRecording(recordingId: String? = nil) throws -> RecordingSession {
        guard let api = roomApiClient else {
            throw NSError(
                domain: "DrawsKit",
                code: 37,
                userInfo: [NSLocalizedDescriptionKey: "Room API unavailable; cannot stop recording"]
            )
        }
        let id = (recordingId ?? activeRecordingId ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw NSError(
                domain: "DrawsKit",
                code: 38,
                userInfo: [NSLocalizedDescriptionKey: "no active recording to stop"]
            )
        }
        let session = try api.stopRecording(recordingId: id)
        if activeRecordingId == id {
            activeRecordingId = nil
        }
        return session
    }

    private func syncViewportEvents(_ frame: [String: Any]) {
        let scale = SessionRead.getBoardScale(frame)
        let scroll = SessionRead.getBoardScroll(frame)
        if let lastScale = lastViewportScale, lastScale != scale {
            emit(DrawsKitConstants.EVENT.DK_BOARD_SCALE_CHANGE, [["id": initParams.id, "reason": "scale"]])
        }
        if let lastScroll = lastViewportScroll,
           lastScroll.0 != scroll.0 || lastScroll.1 != scroll.1 {
            emit(DrawsKitConstants.EVENT.DK_BOARD_SCROLL_CHANGED, [[
                "id": initParams.id,
                "x": Int(scroll.0),
                "y": Int(scroll.1),
            ]])
        }
        lastViewportScale = scale
        lastViewportScroll = scroll
    }

    private func syncHistoryEvents(_ frame: [String: Any]) {
        let canUndo = frame.bool("can_undo")
        let canRedo = frame.bool("can_redo")
        if lastCanUndo != canUndo {
            emit(DrawsKitConstants.EVENT.DK_OPERATE_CANUNDO_STATUS_CHANGED, [["enable": canUndo]])
            lastCanUndo = canUndo
        }
        if lastCanRedo != canRedo {
            emit(DrawsKitConstants.EVENT.DK_OPERATE_CANREDO_STATUS_CHANGED, [["enable": canRedo]])
            lastCanRedo = canRedo
        }
    }

    private func syncSelectionEvents(_ frame: [String: Any]) {
        let ids = SessionRead.getSelectedIds(frame)
        let prev = lastSelectedIds
        let changed = prev == nil || prev?.count != ids.count || zip(prev ?? [], ids).contains { $0 != $1 }
        guard changed else { return }
        lastSelectedIds = ids
        emit(DrawsKitConstants.EVENT.DK_SELECTED_ELEMENTS, [["ids": ids]])
    }

    private func syncBoardEvents(_ frame: [String: Any]) {
        let ids = SessionRead.getBoardList(frame)
        let currentId = SessionRead.getCurrentBoard(frame)
        let prevIds = lastBoardIds
        let prevCurrent = lastCurrentBoardId

        if let prevIds, ids.count > prevIds.count, let added = ids.first(where: { !prevIds.contains($0) }) {
            emit(DrawsKitConstants.EVENT.DK_ADDBOARD, [[
                "id": initParams.id,
                "boardId": added,
                "boardList": ids,
            ]])
        }
        if let prevCurrent, !currentId.isEmpty, currentId != prevCurrent {
            emit(DrawsKitConstants.EVENT.DK_GOTOBOARD, [[
                "id": initParams.id,
                "boardId": currentId,
                "boardList": ids,
            ]])
        }
        if let prevIds, ids.count < prevIds.count, let removed = prevIds.first(where: { !ids.contains($0) }) {
            emit(DrawsKitConstants.EVENT.DK_DELETEBOARD, [[
                "id": initParams.id,
                "boardId": removed,
                "boardList": ids,
            ]])
        }
        lastBoardIds = ids
        lastCurrentBoardId = currentId
    }

    func onTouchBegan(touch: UITouch, in view: DrawsKitView) {
        handleTouch(phase: .began, touch: touch, in: view)
    }

    func onTouchMoved(touches: [UITouch], in view: DrawsKitView) {
        guard let touch = touches.last else { return }
        if isPanToolActive() || isTextToolActive() || !canForwardPointer() {
            handleTouch(phase: .moved, touch: touch, in: view)
            return
        }
        let samples: [[String: Any]] = touches.map { sample in
            let location = sample.location(in: view)
            let (sx, sy) = ViewportCoords.touchToScreen(view: view, x: location.x, y: location.y)
            let (wx, wy) = screenToWorld(screenX: sx, screenY: sy)
            var pressure = sample.force > 0 ? Float(sample.force / sample.maximumPossibleForce) : 0.5
            pressure = min(max(pressure, 0), 1)
            if pressure == 0 { pressure = 0.5 }
            return [
                "x": Double(wx),
                "y": Double(wy),
                "pressure": Double(pressure),
                "timestamp": pointerGestureTimestamp(sample.timestamp),
            ]
        }
        send(PlatformEvents.pointerMoveBatch(pointerId: 0, samples: samples))
    }

    func onTouchEnded(touch: UITouch, in view: DrawsKitView) {
        handleTouch(phase: .ended, touch: touch, in: view)
    }

    private enum TouchPhase { case began, moved, ended }

    private func handleTouch(phase: TouchPhase, touch: UITouch, in view: DrawsKitView) {
        guard !destroyed, drawEnabled else { return }

        if isPanToolActive() {
            handlePanTouch(phase: phase, touch: touch, in: view)
            return
        }

        if isTextToolActive() {
            handleTextToolTouch(phase: phase, touch: touch, in: view)
            return
        }

        guard canForwardPointer() else { return }

        let location = touch.location(in: view)
        let (sx, sy) = ViewportCoords.touchToScreen(view: view, x: location.x, y: location.y)
        let (wx, wy) = screenToWorld(screenX: sx, screenY: sy)
        var pressure = touch.force > 0 ? Float(touch.force / touch.maximumPossibleForce) : 0.5
        pressure = min(max(pressure, 0), 1)
        if pressure == 0 { pressure = 0.5 }

        switch phase {
        case .began:
            send(PlatformEvents.pointerDown(
                pointerId: 0,
                x: wx,
                y: wy,
                pressure: pressure,
                timestamp: beginPointerGestureTimestamp(touch.timestamp)
            ))
        case .moved:
            send(PlatformEvents.pointerMove(
                pointerId: 0,
                x: wx,
                y: wy,
                pressure: pressure,
                timestamp: pointerGestureTimestamp(touch.timestamp)
            ))
        case .ended:
            send(PlatformEvents.pointerUp(
                pointerId: 0,
                x: wx,
                y: wy,
                timestamp: endPointerGestureTimestamp(touch.timestamp)
            ))
        }
    }

    private func handlePanTouch(phase: TouchPhase, touch: UITouch, in view: DrawsKitView) {
        let location = touch.location(in: view)
        let (sx, sy) = ViewportCoords.touchToScreen(view: view, x: location.x, y: location.y)
        switch phase {
        case .began:
            panDragOrigin = (sx, sy)
            cursorController.setPanDragging(true)
            send(PlatformEvents.screenPointerDown(
                pointerId: 0,
                x: sx,
                y: sy,
                timestamp: beginPointerGestureTimestamp(touch.timestamp)
            ))
        case .moved:
            guard panDragOrigin != nil else { return }
            send(PlatformEvents.screenPointerMove(
                pointerId: 0,
                x: sx,
                y: sy,
                timestamp: pointerGestureTimestamp(touch.timestamp)
            ))
        case .ended:
            send(PlatformEvents.screenPointerUp(
                pointerId: 0,
                x: sx,
                y: sy,
                timestamp: endPointerGestureTimestamp(touch.timestamp)
            ))
            panDragOrigin = nil
            cursorController.setPanDragging(false)
        }
    }

    private func beginPointerGestureTimestamp(_ monotonicTimestamp: TimeInterval) -> Int {
        pointerTimestamps.begin(
            epochNowMilliseconds: Int(Date().timeIntervalSince1970 * 1000),
            monotonicNowMilliseconds: Int(ProcessInfo.processInfo.systemUptime * 1000)
        )
        return pointerTimestamps.toEpoch(
            monotonicTimestampMilliseconds: Int(monotonicTimestamp * 1000)
        )
    }

    private func pointerGestureTimestamp(_ monotonicTimestamp: TimeInterval) -> Int {
        if !pointerTimestamps.isActive {
            pointerTimestamps.begin(
                epochNowMilliseconds: Int(Date().timeIntervalSince1970 * 1000),
                monotonicNowMilliseconds: Int(ProcessInfo.processInfo.systemUptime * 1000)
            )
        }
        return pointerTimestamps.toEpoch(
            monotonicTimestampMilliseconds: Int(monotonicTimestamp * 1000)
        )
    }

    private func endPointerGestureTimestamp(_ monotonicTimestamp: TimeInterval) -> Int {
        let timestamp = pointerGestureTimestamp(monotonicTimestamp)
        pointerTimestamps.reset()
        return timestamp
    }

    func onPinch(scaleFactor: Float, focusX: Float, focusY: Float, in view: DrawsKitView) {
        guard !destroyed, drawEnabled, enableScaleTool else { return }
        let (sx, sy) = ViewportCoords.touchToScreen(view: view, x: CGFloat(focusX), y: CGFloat(focusY))
        send(PlatformEvents.zoomAtPoint(screenX: sx, screenY: sy, scaleFactor: scaleFactor))
    }

    private func isPanToolActive() -> Bool {
        effectiveToolKind() == "pan"
    }

    private func isTextToolActive() -> Bool {
        effectiveToolKind() == "text"
    }

    private func handleTextToolTouch(phase: TouchPhase, touch: UITouch, in view: DrawsKitView) {
        guard phase == .began else { return }
        if textOverlay != nil { return }
        let location = touch.location(in: view)
        let (sx, sy) = ViewportCoords.touchToScreen(view: view, x: location.x, y: location.y)
        let (wx, wy) = screenToWorld(screenX: sx, screenY: sy)
        if let existing = TextMap.parseTextEditHit(session?.textAtPointJson(x: wx, y: wy)) {
            openTextInput(
                worldX: existing.x,
                worldY: existing.y,
                initialValue: existing.content,
                editingId: existing.id,
                fontSizePx: existing.fontSize,
                boldOverride: existing.bold,
                italicOverride: existing.italic,
                fontFamilyOverride: existing.fontFamily,
                colorOverride: existing.color
            )
        } else {
            openTextInput(worldX: wx, worldY: wy, initialValue: pendingTextValue)
        }
    }

    private func openTextInput(
        worldX: Float,
        worldY: Float,
        initialValue: String,
        editingId: String? = nil,
        fontSizePx: Float? = nil,
        boldOverride: Bool? = nil,
        italicOverride: Bool? = nil,
        fontFamilyOverride: String? = nil,
        colorOverride: String? = nil
    ) {
        guard let view, let boardContainer else { return }
        closeTextOverlay(keepEditingId: editingId != nil)
        editingTextId = editingId

        let transform = ViewportCoords.transform(frame: lastFrame)
        let (screenX, screenY) = ViewportCoords.worldToScreen(worldX: worldX, worldY: worldY, transform: transform)
        let (overlayX, overlayY) = ViewportCoords.screenToViewPixels(view: view, screenX: screenX, screenY: screenY)

        emit(DrawsKitConstants.EVENT.DK_TEXT_ELEMENT_STATUS_CHANGED, [[
            "status": "editing",
            "x": worldX,
            "y": worldY,
        ]])

        textOverlay = TextInputOverlay(
            boardContainer: boardContainer,
            canvasView: view,
            screenX: overlayX,
            screenY: overlayY,
            initialValue: initialValue,
            textColor: colorOverride ?? SessionRead.getTextColor(lastFrame),
            textSize: SessionRead.getTextSize(lastFrame),
            textStyle: SessionRead.getTextStyle(lastFrame),
            fontFamily: fontFamilyOverride ?? SessionRead.getTextFontFamily(lastFrame),
            lineHeight: SessionRead.getTextLineHeight(lastFrame),
            scalePercent: transform.scale,
            editing: editingId != nil,
            fontSizePx: fontSizePx,
            boldOverride: boldOverride,
            italicOverride: italicOverride,
            onCommit: { [weak self] value in
                self?.commitTextInput(worldX: worldX, worldY: worldY, value: value)
            },
            onCancel: { [weak self] in
                self?.emit(DrawsKitConstants.EVENT.DK_TEXT_ELEMENT_STATUS_CHANGED, [["status": "cancelled"]])
            }
        )
    }

    private func commitTextInput(worldX: Float, worldY: Float, value: String) {
        textOverlay = nil
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        emit(DrawsKitConstants.EVENT.DK_TEXT_ELEMENT_STATUS_CHANGED, [[
            "status": trimmed.isEmpty ? "cancelled" : "committed",
        ]])
        guard !trimmed.isEmpty else {
            editingTextId = nil
            return
        }
        if let editingId = editingTextId {
            send(PlatformEvents.withType(PlatformEventType.updateText) { payload in
                payload["id"] = editingId
                payload["content"] = trimmed
                payload["timestamp"] = Int(Date().timeIntervalSince1970 * 1000)
            })
        } else {
            send(PlatformEvents.withType(PlatformEventType.addText) { payload in
                payload["content"] = trimmed
                payload["x"] = Double(worldX)
                payload["y"] = Double(worldY)
                payload["timestamp"] = Int(Date().timeIntervalSince1970 * 1000)
            })
        }
        editingTextId = nil
        pendingTextValue = ""
    }

    private func closeTextOverlay(keepEditingId: Bool = false) {
        textOverlay?.destroy()
        textOverlay = nil
        if !keepEditingId { editingTextId = nil }
    }

    private func effectiveToolKind() -> String {
        requestedToolKind ?? SessionRead.getActiveToolKind(lastFrame)
    }

    private func canForwardPointer() -> Bool {
        guard !destroyed, drawEnabled else { return false }
        let kind = effectiveToolKind()
        return kind == "pen" || kind == "highlighter" || kind == "eraser" ||
            kind == "shape" || kind == "select" || kind == "laser"
    }

    private func screenToWorld(screenX: Float, screenY: Float) -> (Float, Float) {
        let transform = ViewportCoords.transform(frame: lastFrame)
        return ViewportCoords.screenToWorld(screenX: screenX, screenY: screenY, transform: transform)
    }

    func destroy() {
        guard !destroyed else { return }
        operationLogger.action("sdk.destroy", phase: "ok", result: "ok")
        destroyed = true
        closeTextOverlay()
        coursewareHost?.destroy()
        coursewareHost = nil
        mediaHost?.destroy()
        mediaHost = nil
        mediaSync.destroy()
        coursewareLoading?.destroy()
        coursewareLoading = nil
        bootstrapLoading?.destroy()
        bootstrapLoading = nil
        bootstrapErrorOverlay?.destroy()
        bootstrapErrorOverlay = nil
        operationLogger.setActionSink(nil)
        actionReporter?.destroy()
        actionReporter = nil
        imBridge?.destroy()
        imBridge = nil
        cursorController.detach()
        view?.bindEngine(nil)
        view = nil
        boardContainer = nil
        let coordinator = syncCoordinator
        syncCoordinator = nil
        if let coordinator {
            coordinator.destroy { [self] in
                releaseNativeSession()
            }
        } else {
            releaseNativeSession()
        }
        emit(DrawsKitConstants.EVENT.DK_DESTROY, [["id": initParams.id]])
    }

    /// Native handle lives until destroy-time workspace export finishes.
    private func releaseNativeSession() {
        send(PlatformEvents.simple("surface_destroyed"))
        session?.destroy()
        session = nil
        imageCache.release()
        let dyingRenderer = renderer
        renderer = nil
        let teardown = {
            if let dyingRenderer {
                dyingRenderer.destroy()
            }
        }
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.async(execute: teardown)
        }
    }

    func refresh() { send(PlatformEvents.simple("refresh")) }
    func reset() { send(PlatformEvents.withType(PlatformEventType.reset) { $0["keep_courseware"] = true }) }

    func addBoard(options: Any?) -> String {
        let opts = options as? [String: Any]
        let boardId = "board-\(Int(Date().timeIntervalSince1970 * 1000))"
        send(PlatformEvents.withType(PlatformEventType.addBoard) { payload in
            payload["board_id"] = boardId
            payload["switch_to"] = opts?["needSwitch"] as? Bool ?? true
            payload["remark"] = ""
            payload["timestamp"] = Int(Date().timeIntervalSince1970 * 1000)
            if let index = opts?["index"] { payload["index"] = index }
        })
        return boardId
    }

    func deleteBoard(_ boardId: String) {
        send(PlatformEvents.withType(PlatformEventType.deleteBoard) { payload in
            payload["board_id"] = boardId
            payload["timestamp"] = Int(Date().timeIntervalSince1970 * 1000)
        })
    }

    func gotoBoard(_ boardId: String) {
        send(PlatformEvents.withType(PlatformEventType.gotoBoard) { payload in
            payload["board_id"] = boardId
            payload["timestamp"] = Int(Date().timeIntervalSince1970 * 1000)
        })
    }

    func nextBoard() {
        send(PlatformEvents.withType(PlatformEventType.nextBoard) { $0["timestamp"] = Int(Date().timeIntervalSince1970 * 1000) })
    }

    func prevBoard() {
        send(PlatformEvents.withType(PlatformEventType.prevBoard) { $0["timestamp"] = Int(Date().timeIntervalSince1970 * 1000) })
    }

    func getBoardList() -> [String] { SessionRead.getBoardList(lastFrame) }
    func getCurrentBoard() -> String { SessionRead.getCurrentBoard(lastFrame) }
    func getBoardRatio() -> String { SessionRead.getBoardRatio(lastFrame) }

    func setBoardRatio(_ ratio: String) {
        send(PlatformEvents.withType(PlatformEventType.setBoardRatio) { $0["ratio"] = ratio })
    }

    func getBoardScale() -> Int { SessionRead.getBoardScale(lastFrame) }

    func setBoardScale(_ scale: Int) {
        let range = SessionRead.getScaleRange(lastFrame)
        let clamped = max(range.0, min(scale, range.1))
        send(PlatformEvents.withType(PlatformEventType.setBoardScale) { $0["scale"] = clamped })
    }

    func getBoardScroll() -> [String: Int] {
        let (x, y) = SessionRead.getBoardScroll(lastFrame)
        return ["x": Int(x), "y": Int(y)]
    }

    func setBoardScroll(x: Int, y: Int) {
        send(PlatformEvents.withType(PlatformEventType.viewportScroll) { payload in
            payload["offset_x"] = x
            payload["offset_y"] = y
        })
    }

    func getBoardClientSize() -> [String: Int] {
        let (w, h) = ViewportCoords.logicalSize(view: view)
        return ["width": w, "height": h]
    }

    func getBoardRemark(_ boardId: String) -> String {
        SessionRead.getBoardRemark(lastFrame, boardId: boardId)
    }

    func setBoardRemark(_ boardId: String, _ remark: String) {
        send(PlatformEvents.withType(PlatformEventType.setBoardRemark) { payload in
            payload["board_id"] = boardId
            payload["remark"] = remark
        })
    }

    func addTranscodeFile(_ manifest: Any, baseUrl: String? = nil) -> String {
        switch CoursewareMap.parseManifest(manifest, baseUrl: baseUrl) {
        case .failure(let error):
            emit(DrawsKitConstants.EVENT.DK_WARNING, [[
                "code": DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_ILLEGAL_OPERATION,
                "message": CoursewareMap.errorMessage(error),
            ]])
            return ""
        case .ok(let payload):
            return loadStaticCourseware(payload)
        }
    }

    func addImagesFile(_ urls: [String], title: String?) -> String {
        guard let payload = CoursewareMap.buildImagesFilePayload(urls, title: title) else { return "" }
        return loadStaticCourseware(payload)
    }

    func addVideoFile(_ url: String, title: String?) -> String {
        guard let payload = CoursewareMap.buildVideoFilePayload(url, title: title) else { return "" }
        return loadStaticCourseware(payload)
    }

    func addAudioElement(
        id: String,
        url: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        global: Bool
    ) {
        send(PlatformEvents.addAudioElement(
            id: id, url: url, x: x, y: y, width: width, height: height, global: global
        ))
    }

    func playMedia(_ key: String) { mediaHost?.play(key) }
    func pauseMedia(_ key: String) { mediaHost?.pause(key) }
    func seekMedia(_ key: String, time: Int) { mediaHost?.seek(key, time: time) }
    func muteMedia(_ key: String, muted: Bool) { mediaHost?.mute(key, muted: muted) }
    func setMediaVolume(_ key: String, volume: Int) { mediaHost?.setVolume(key, volume: volume) }
    func getMediaVolume(_ key: String) -> Int { mediaHost?.getVolume(key) ?? MediaDefaults.defaultAudioVolume }
    func setShowVideoControl(_ show: Bool) { mediaHost?.setShowVideoControl(show) }
    func setEnableAudioControl(_ enable: Bool) { mediaHost?.setEnableAudioControl(enable) }
    func setShowPPTAudioControls(_ show: Bool) { mediaHost?.setShowPPTAudioControls(show) }
    func setVideoFileDrawEnable(_ enable: Bool) { mediaHost?.setVideoFileDrawEnable(enable) }
    func soundMuteForPPT(_ mute: Bool) { mediaHost?.soundMuteForPPT(mute) }
    func setSyncAudioStatusEnable(_ enable: Bool) { mediaSync.setSyncAudioStatusEnable(enable) }
    func setSyncVideoStatusEnable(_ enable: Bool) { mediaSync.setSyncVideoStatusEnable(enable) }
    func startSyncVideoStatus() { mediaSync.startSyncVideoStatus() }
    func stopSyncVideoStatus() { mediaSync.stopSyncVideoStatus() }

    private func applyMediaSyncInbound(_ payload: Any) -> Bool {
        guard let message = mediaSync.parseInbound(payload),
              let key = message["key"] as? String,
              let action = message["action"] as? String
        else { return false }
        let position = Int(message["position"] as? Double ?? 0)
        switch action {
        case MediaDefaults.syncActionPlay, MediaDefaults.syncActionState:
            mediaHost?.seek(key, time: position)
            mediaHost?.play(key)
        case MediaDefaults.syncActionPause:
            mediaHost?.seek(key, time: position)
            mediaHost?.pause(key)
        case MediaDefaults.syncActionSeek:
            mediaHost?.seek(key, time: position)
        default:
            break
        }
        return true
    }

    private func loadStaticCourseware(_ payload: CoursewarePayload) -> String {
        currentCoursewareFileId = payload.fileId
        if let first = payload.pages.first {
            coursewareLoading?.show(message: "课件加载中…")
            emit(DrawsKitConstants.EVENT.DK_COURSEWARE_STATUS_CHANGED, [[
                "id": initParams.id,
                "fileId": payload.fileId,
                "pageIndex": 0,
                "status": "loading",
            ]])
            kickCoursewarePageLoad(url: first.url, format: first.format, width: first.width, height: first.height)
        }
        send(PlatformEvents.loadCourseware(payload))
        emit(DrawsKitConstants.EVENT.DK_ADDTRANSCODEFILE, [["fileId": payload.fileId]])
        return payload.fileId
    }

    private func kickCoursewarePageLoad(
        url: String,
        format: String,
        width: Double = 0,
        height: Double = 0
    ) {
        imageCache.forgetAssetFailure(url)
        let isSvg = format == "svg" || url.localizedCaseInsensitiveContains(".svg")
        if !isSvg {
            imageCache.load(url, svg: false, notifyStatus: true)
            return
        }
        let vp = lastFrame?.dict("viewport")
        let host = view
        let dpr = CGFloat(ViewportCoords.density(view: host))
        let vpW = (vp?["width"] as? Double).flatMap { $0 > 0 ? CGFloat($0) : nil }
            ?? host.map { $0.bounds.width / max(dpr, 1) }
            ?? 0
        let vpH = (vp?["height"] as? Double).flatMap { $0 > 0 ? CGFloat($0) : nil }
            ?? host.map { $0.bounds.height / max(dpr, 1) }
            ?? 0
        let boardScale = CGFloat(max(SessionRead.getBoardScale(lastFrame), 1)) / 100
        let full = ImageCache.coursewareRasterSize(
            pageWidth: CGFloat(width),
            pageHeight: CGFloat(height),
            viewportWidth: vpW,
            viewportHeight: vpH,
            deviceScale: dpr,
            boardScale: boardScale
        )
        let preview = ImageCache.coursewareRasterSize(
            pageWidth: CGFloat(width),
            pageHeight: CGFloat(height),
            viewportWidth: vpW,
            viewportHeight: vpH,
            deviceScale: dpr,
            boardScale: boardScale,
            maxEdge: ImageCache.coursewareRasterPreviewMaxEdge
        )
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

    private func pageIndexForUrl(_ url: String, fileId: String) -> Int {
        guard !fileId.isEmpty else { return 0 }
        let urls = CoursewareRead.getThumbnailImages(lastFrame, fileId: fileId)
        return urls.firstIndex(of: url) ?? 0
    }

    func addH5File(_ url: String, title: String?) -> String {
        guard let payload = CoursewareMap.parseH5FileUrl(url, title: title) else { return "" }
        if let existing = CoursewareRead.getCoursewareLayer(lastFrame),
           CoursewareRead.isWebViewRenderMode(existing.string("render_mode")),
           existing.string("webview_url") == payload.url {
            emit(DrawsKitConstants.EVENT.DK_WARNING, [[
                "code": DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_H5FILE_ALREADY_EXISTS,
                "message": "H5 courseware already loaded for this URL",
            ]])
            return existing.string("resource_id")
        }
        currentCoursewareFileId = payload.fileId
        send(PlatformEvents.loadH5Courseware(resourceId: payload.fileId, url: payload.url, title: payload.title))
        emit(DrawsKitConstants.EVENT.DK_H5FILE_STATUS_CHANGED, [[
            "id": initParams.id,
            "fileId": payload.fileId,
            "status": "loading",
            "url": payload.url,
        ]])
        emit(DrawsKitConstants.EVENT.DK_ADDFILE, [[
            "id": initParams.id,
            "fileId": payload.fileId,
            "title": payload.title ?? "",
        ]])
        return payload.fileId
    }

    func getThumbnailImages(_ fileId: String) -> [String] {
        CoursewareRead.getThumbnailImages(lastFrame, fileId: fileId)
    }

    func getFileBoardList(_ fileId: String) -> [String] {
        CoursewareRead.getFileBoardList(lastFrame, fileId: fileId)
    }

    func getPPTRemarks(_ fileId: String) -> [String] {
        CoursewareRead.getPPTRemarks(lastFrame, fileId: fileId)
    }

    func getFileInfoList() -> [[String: Any]] {
        let currentFile = CoursewareRead.getCurrentFileId(lastFrame)
        let currentPage = CoursewareRead.getPageIndex(lastFrame)
        return CoursewareRead.getCoursewareFiles(lastFrame).map { file in
            let fileId = file.string("file_id")
            return [
                "fileId": fileId,
                "title": file.string("title"),
                "sourceType": file.string("source_type"),
                "pageCount": file.int("page_count"),
                "pageIndex": fileId == currentFile ? currentPage : 0,
                "boardIds": CoursewareRead.getFileBoardList(lastFrame, fileId: fileId),
            ]
        }
    }

    func getFileInfo(_ fileId: String) -> [String: Any]? {
        getFileInfoList().first { ($0["fileId"] as? String) == fileId }
    }

    func switchFile(_ fileId: String) {
        guard let firstBoard = CoursewareRead.getFileBoardList(lastFrame, fileId: fileId).first else {
            emit(DrawsKitConstants.EVENT.DK_WARNING, [[
                "code": DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_ILLEGAL_OPERATION,
                "message": "No courseware file with id: \(fileId)",
            ]])
            return
        }
        gotoBoard(firstBoard)
    }

    func clearFileDraws(_ fileId: String?) {
        let trimmed = fileId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = (trimmed?.isEmpty == false ? trimmed : nil) ?? CoursewareRead.getCurrentFileId(lastFrame)
        guard !id.isEmpty else { return }
        send(PlatformEvents.clearFileDraws(resourceId: id))
    }

    func getCoursewarePageCount() -> Int { CoursewareRead.getPageCount(lastFrame) }
    func getCoursewarePageIndex() -> Int { CoursewareRead.getPageIndex(lastFrame) }

    func deleteFile(_ fileId: String) {
        let id = fileId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard CoursewareRead.getCoursewareFile(lastFrame, fileId: id) != nil else {
            emit(DrawsKitConstants.EVENT.DK_WARNING, [[
                "code": DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_ILLEGAL_OPERATION,
                "message": "No courseware file with id: \(id)",
            ]])
            return
        }
        currentCoursewareFileId = nil
        send(PlatformEvents.removeCourseware(resourceId: id))
        emit(DrawsKitConstants.EVENT.DK_DELETEFILE, [[
            "id": initParams.id,
            "fileId": id,
        ]])
    }

    func getCurrentFile() -> String {
        CoursewareRead.getCoursewareLayer(lastFrame)?.string("resource_id") ?? ""
    }

    func gotoStep(_ step: Int) {
        send(PlatformEvents.withType(PlatformEventType.gotoPage) { $0["page_index"] = max(step, 0) })
    }

    func canPrevStep() -> Bool { getCoursewarePageIndex() > 0 }

    func canNextStep() -> Bool {
        let index = getCoursewarePageIndex()
        let count = getCoursewarePageCount()
        return count > 0 && index + 1 < count
    }

    func nextStep() {
        guard canNextStep() else { return }
        gotoStep(getCoursewarePageIndex() + 1)
    }

    func prevStep() {
        guard canPrevStep() else { return }
        gotoStep(getCoursewarePageIndex() - 1)
    }

    func setToolType(_ toolType: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setToolType(toolType) }
            return
        }
        guard let kind = ToolMap.toolTypeToKind(toolType) else {
            operationLogger.action(
                "tool.set",
                phase: "fail",
                result: "unsupported",
                level: 2,
                detail: ["tool_type": toolType]
            )
            return
        }
        closeTextOverlay()
        panDragOrigin = nil
        requestedToolKind = kind
        cursorController.setPanDragging(false)
        cursorController.setToolType(toolType)
        send(PlatformEvents.withType(PlatformEventType.setTool) { $0["tool"] = kind })
        if let sub = ToolMap.toolTypeToShapeSubTool(toolType) {
            let arrowEnd = SessionRead.getGraphStyle(lastFrame)["arrowEnd"] as? Bool == true
            let effective = sub == "line" && arrowEnd ? "arrow" : sub
            send(PlatformEvents.withType(PlatformEventType.setShapeSubTool) { $0["sub_tool"] = effective })
        }
        view?.setNeedsDisplay()
        operationLogger.action(
            "tool.set",
            phase: "ok",
            result: "ok",
            detail: ["tool_type": toolType, "tool": kind]
        )
    }

    func getToolType() -> Int { SessionRead.getToolType(lastFrame) }
    func setBrushColor(_ color: String) { send(PlatformEvents.withType(PlatformEventType.setBrushColor) { $0["color"] = color }) }
    func getBrushColor() -> String { SessionRead.getBrushColor(lastFrame) }
    func setBrushThin(_ thin: Int) { send(PlatformEvents.withType(PlatformEventType.setBrushThin) { $0["thin"] = max(0, min(thin, EngineDefaults.industryUnitMax)) }) }
    func getBrushThin() -> Int { SessionRead.getBrushThin(lastFrame) }
    func setBrushThinMode(_ mode: Int) { send(PlatformEvents.withType(PlatformEventType.setBrushThinMode) { $0["mode"] = mode }) }
    func getBrushThinMode() -> Int { SessionRead.getBrushThinMode(lastFrame) }
    func setHighlighterColor(_ color: String) { send(PlatformEvents.withType(PlatformEventType.setHighlighterColor) { $0["color"] = color }) }
    func getHighlighterColor() -> String { SessionRead.getHighlighterColor(lastFrame) }
    func setLineStyle(_ style: Int) { send(PlatformEvents.withType(PlatformEventType.setLineStyle) { $0["style"] = style }) }
    func getLineStyle() -> Int { SessionRead.getLineStyle(lastFrame) }

    func setGraphStyle(_ style: Any) {
        guard let style = style as? [String: Any] else { return }
        if let color = style["color"] as? String {
            send(PlatformEvents.withType(PlatformEventType.setGraphColor) { $0["color"] = color })
        }
        if let thin = JSONCoerce.int(style["thin"]) {
            send(PlatformEvents.withType(PlatformEventType.setGraphThin) { $0["thin"] = max(0, min(thin, EngineDefaults.industryUnitMax)) })
        }
        if style.keys.contains("fillEnabled") {
            send(PlatformEvents.withType(PlatformEventType.setGraphFillEnabled) { $0["enabled"] = JSONCoerce.bool(style["fillEnabled"]) == true })
        }
        if let lineStyle = JSONCoerce.int(style["lineStyle"]) {
            send(PlatformEvents.withType(PlatformEventType.setGraphLineStyle) { $0["style"] = max(0, min(lineStyle, 2)) })
        }
        if let fillStyle = JSONCoerce.int(style["fillStyle"]) {
            send(PlatformEvents.withType(PlatformEventType.setGraphFillStyle) { $0["style"] = max(0, min(fillStyle, 3)) })
        }
        if let roughness = JSONCoerce.int(style["roughness"]) {
            send(PlatformEvents.withType(PlatformEventType.setGraphRoughness) { $0["roughness"] = max(0, min(roughness, 2)) })
        }
        if style.keys.contains("roundness") {
            let round = JSONCoerce.bool(style["roundness"]) ?? (JSONCoerce.int(style["roundness"]) != 0)
            send(PlatformEvents.withType(PlatformEventType.setGraphRoundness) { $0["roundness"] = round ? 1 : 0 })
        }
        if style.keys.contains("fillColor") {
            send(PlatformEvents.withType(PlatformEventType.setGraphFillColor) { payload in
                payload["color"] = style["fillColor"] ?? NSNull()
            })
        }
        if let arrowEnd = style["arrowEnd"] as? Bool {
            send(PlatformEvents.withType(PlatformEventType.setGraphArrowEnd) { $0["enabled"] = arrowEnd })
        }
    }

    func getGraphStyle() -> [String: Any?] { SessionRead.getGraphStyle(lastFrame) }
    func setGraphLineStyle(_ style: Int) {
        send(PlatformEvents.withType(PlatformEventType.setGraphLineStyle) { $0["style"] = max(0, min(style, 2)) })
    }
    func setOvalDrawMode(_ mode: Int) { send(PlatformEvents.withType(PlatformEventType.setOvalDrawMode) { $0["mode"] = mode }) }
    func getOvalDrawMode() -> Int { SessionRead.getOvalDrawMode(lastFrame) }
    func setEraserSize(_ size: Int) { send(PlatformEvents.withType(PlatformEventType.setEraserSize) { $0["size"] = max(0, min(size, EngineDefaults.industryUnitMax)) }) }
    func getEraserSize() -> Int { SessionRead.getEraserSize(lastFrame) }
    func setEraserMode(_ mode: Int) { send(PlatformEvents.withType(PlatformEventType.setEraserMode) { $0["mode"] = mode }) }
    func setPiecewiseErasureEnable(_ enable: Bool) {
        send(PlatformEvents.withType(PlatformEventType.setPiecewiseErasure) { $0["enabled"] = enable })
        send(PlatformEvents.withType(PlatformEventType.setEraserMode) { $0["mode"] = enable ? 1 : 0 })
    }
    func isPiecewiseErasureEnable() -> Bool { SessionRead.isPiecewiseErasure(lastFrame) }
    func setLaserSize(_ size: Int) { send(PlatformEvents.withType(PlatformEventType.setLaserSize) { $0["size"] = max(0, min(size, EngineDefaults.industryUnitMax)) }) }
    func getLaserSize() -> Int { SessionRead.getLaserSize(lastFrame) }
    func enablePenAutoFit() { send(PlatformEvents.withType(PlatformEventType.setMagicPenEnabled) { $0["enabled"] = true }) }
    func setPenAutoFitEnable(_ enable: Bool) { send(PlatformEvents.withType(PlatformEventType.setMagicPenEnabled) { $0["enabled"] = enable }) }
    func isPenAutoFitEnable() -> Bool { SessionRead.getMagicPenEnabled(lastFrame) }
    func setPenAutoFittingMode(_ mode: Int) {
        send(PlatformEvents.withType(PlatformEventType.setPenAutoFittingMode) { $0["mode"] = mode == 0 ? 0 : 1 })
    }
    func getPenAutoFittingMode() -> Int { SessionRead.getPenAutoFittingMode(lastFrame) }
    func setPerfectFreehandEnable(_ enable: Bool) { send(PlatformEvents.withType(PlatformEventType.setStrokeTaper) { $0["enabled"] = enable }) }
    func getPerfectFreehandEnable() -> Bool { SessionRead.getStrokeTaperEnabled(lastFrame) }
    func setTextColor(_ color: String) { send(PlatformEvents.withType(PlatformEventType.setTextColor) { $0["color"] = color }) }
    func getTextColor() -> String { SessionRead.getTextColor(lastFrame) }
    func setTextSize(_ size: Int) { send(PlatformEvents.withType(PlatformEventType.setTextSize) { $0["size"] = max(size, 1) }) }
    func getTextSize() -> Int { SessionRead.getTextSize(lastFrame) }
    func setTextStyle(_ style: Int) { send(PlatformEvents.withType(PlatformEventType.setTextStyle) { $0["style"] = style }) }
    func getTextStyle() -> Int { SessionRead.getTextStyle(lastFrame) }
    func setTextFontFamily(_ font: String) { send(PlatformEvents.withType(PlatformEventType.setTextFontFamily) { $0["font"] = font }) }
    func getTextFontFamily() -> String { SessionRead.getTextFontFamily(lastFrame) }
    func setTextLineHeight(_ height: Float) {
        send(PlatformEvents.withType(PlatformEventType.setTextLineHeight) { $0["height"] = Double(max(height, 0.5)) })
    }
    func getTextLineHeight() -> Float { SessionRead.getTextLineHeight(lastFrame) }
    func setTextValue(_ value: String) { pendingTextValue = value }

    func setNextTextInput(_ options: Any) {
        guard let options = options as? [String: Any],
              let x = (options["x"] as? NSNumber)?.floatValue,
              let y = (options["y"] as? NSNumber)?.floatValue else { return }
        let value = options["value"] as? String ?? pendingTextValue
        openTextInput(worldX: x, worldY: y, initialValue: value)
    }

    func undo() { send(PlatformEvents.simple("undo")) }
    func redo() { send(PlatformEvents.simple("redo")) }
    func clear() { send(PlatformEvents.simple("clear")) }
    func clearWithUndo() {
        send(PlatformEvents.withType(PlatformEventType.clearWithUndo) { $0["timestamp"] = Int(Date().timeIntervalSince1970 * 1000) })
    }
    func cancelSelect() { send(PlatformEvents.simple("cancel_select")) }
    func autoSelectedElement(_ id: String) { send(PlatformEvents.withType(PlatformEventType.autoSelectElement) { $0["id"] = id }) }
    func copyElementsByIds(_ ids: [String]) {
        send(PlatformEvents.withType(PlatformEventType.copyElements) { payload in
            payload["ids"] = ids
            payload["timestamp"] = Int(Date().timeIntervalSince1970 * 1000)
        })
    }
    func getSelectedElementIds() -> [String] { SessionRead.getSelectedIds(lastFrame) }
    func setDrawEnable(_ enable: Bool) {
        requestedDrawEnabled = enable
        applyDrawPermission()
    }
    func isDrawEnable() -> Bool { drawEnabled }

    func setCursorIcon(_ toolType: Int, _ icon: Any?) {
        cursorController.setCursorIcon(toolType: toolType, icon: icon)
    }

    func setZoomCursorIcon(_ icon: Any?) {
        cursorController.setZoomCursorIcon(icon)
    }

    func setSystemCursorEnable(_ enable: Bool) {
        cursorController.setSystemCursorEnable(enable)
    }
    func exportData() -> String? { session?.exportJson() }
    func importData(_ json: String) -> Int32 { session?.importJson(json) ?? -1 }
    func isStrokeTaperBlocked() -> Bool {
        getLineStyle() != DrawsKitConstants.DrawsKitLineType.DRAWSKIT_LINE_TYPE_SOLID
    }
}
