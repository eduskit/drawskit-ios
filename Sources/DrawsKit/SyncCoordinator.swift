import Foundation

/// Live-stroke playout is a sync concern, not a display callback. Keep its
/// clock on a private queue so Core work can never enter the render run loop.
private final class LiveStrokeTicker {
    private let queue = DispatchQueue(label: "io.drawskit.live-stroke-clock", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let onTick: () -> Void

    init(onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler(handler: onTick)
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }
}

/// Thin host interpreter for the shared Rust sync state machine.
final class SyncCoordinator {
    private let roomId: String
    private let clientId: String
    private let emitEvent: (String, [Any]) -> Void
    private let warn: (Int, String) -> Void
    private let sendJson: (String) -> Void
    private let roomApi: RoomApiClient?
    private let imTransport: DrawsKitImTransport?

    private var dataSyncEnable: Bool
    private var syncFps: Int
    /// When false, skip client POST /checkpoints; local checkpoint still saved. Default true.
    private let checkpointUploadEnable: Bool
    private var syncTime: Int64 = 0
    private var historyLoaded = false
    private var reloadInProgress = false
    private var lastKnownServerSeq: Int64 = 0
    private var serverCheckpointSeq: Int64 = 0
    private var pendingAck: [String: [String: Any]] = [:]
    private let ioQueue = DispatchQueue(label: "io.drawskit.room-api", qos: .utility)
    /// Policy/JSON/retry actor. Never target the UIKit render/main queue.
    private let coordinationQueue = DispatchQueue(label: "io.drawskit.sync-coordinator", qos: .utility)
    private let coursewareRefreshQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.drawskit.courseware-refresh"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    private let outbox: SyncOutboxStore?
    private let checkpointStore: WorkspaceCheckpointStore?
    private let exportWorkspace: (() -> [String: Any]?)?
    private let importWorkspace: (([String: Any]) -> Void)?
    private let log: OperationLogger?
    private let prefetchCoursewarePage: ((String, String) -> Void)?
    private var visibleCoursewareFileId: String?
    private var visibleCoursewarePageIndex = 0
    private var prefetchedCoursewareUrl: String?
    private var visibleRefreshTimeoutMs = SyncPolicy.coursewareRefreshHttpTimeoutMs
    private var outboxHydrated = false
    private var localCheckpointSeq: Int64 = 0
    private var prefetchWorkItems: [DispatchWorkItem] = []
    private var coursewareRefreshWorkItems: [String: DispatchWorkItem] = [:]
    private var runtimeTimers: [String: DispatchWorkItem] = [:]
    private let liveStrokePruneLock = NSRecursiveLock()
    private var liveStrokePruneGeneration: UInt64 = 0
    private var liveStrokePruneWorkItem: DispatchWorkItem?
    private let liveStrokeTickerLock = NSLock()
    private var liveStrokeTickerGeneration: UInt64 = 0
    private var liveStrokeTicker: LiveStrokeTicker?
    private var liveStrokeTickerDestroyed = false
    /// Room-wide live-ink message budget shared by everyone drawing.
    private static let liveStrokeBudgetQps = 8
    /// How long a stroke may stay silent while betting it can be delivered as a
    /// single `end` message carrying its whole timeline. Most strokes finish
    /// inside this window and then cost one message instead of a paced sequence
    /// of chunks. Zero streams every stroke from its first move.
    private static let liveStrokeSingleShotMaxMs: Int64 = 1_500
    /// Shared policy runtime (`drawskit-sdk-sync` via FFI).
    private let syncRuntime: SyncRuntime
    /// Once true, runtime commands and late exports are no-ops.
    private var destroyed = false
    /// True only while the destroy command list is being interpreted.
    private var tearingDown = false

    init(
        roomId: String,
        clientId: String,
        emitEvent: @escaping (String, [Any]) -> Void,
        warn: @escaping (Int, String) -> Void,
        sendJson: @escaping (String) -> Void,
        roomApi: RoomApiClient?,
        imTransport: DrawsKitImTransport?,
        dataSyncEnable: Bool,
        syncFps: Int,
        checkpointUploadEnable: Bool = true,
        liveStrokeEnable: Bool = true,
        /// Nil keeps the SDK default.
        liveStrokeBudgetQps: Int? = nil,
        /// Nil keeps the SDK default.
        liveStrokeSingleShotMaxMs: Int64? = nil,
        outbox: SyncOutboxStore? = nil,
        checkpointStore: WorkspaceCheckpointStore? = nil,
        exportWorkspace: (() -> [String: Any]?)? = nil,
        importWorkspace: (([String: Any]) -> Void)? = nil,
        log: OperationLogger? = nil,
        prefetchCoursewarePage: ((String, String) -> Void)? = nil
    ) throws {
        self.roomId = roomId
        self.clientId = clientId
        self.emitEvent = emitEvent
        self.warn = warn
        self.sendJson = sendJson
        self.roomApi = roomApi
        self.imTransport = imTransport
        self.dataSyncEnable = dataSyncEnable
        self.syncFps = Self.clampSyncFps(syncFps)
        self.checkpointUploadEnable = checkpointUploadEnable
        self.log = log
        self.prefetchCoursewarePage = prefetchCoursewarePage
        self.syncRuntime = try SyncRuntime.create()
        if let outbox {
            self.outbox = outbox
        } else if roomApi != nil {
            self.outbox = createSyncOutboxStore()
        } else {
            self.outbox = nil
        }
        if let checkpointStore {
            self.checkpointStore = checkpointStore
        } else if roomApi != nil {
            self.checkpointStore = createWorkspaceCheckpointStore()
        } else {
            self.checkpointStore = nil
        }
        self.exportWorkspace = exportWorkspace
        self.importWorkspace = importWorkspace
        // Configuring hands the engine its live-ink pacing, so the reply matters.
        executeRuntimeCommands(syncRuntime.handle([
            "type": "configure",
            "config": [
                "room_id": roomId,
                "client_id": clientId,
                "data_sync_enable": dataSyncEnable,
                "checkpoint_upload_enable": checkpointUploadEnable,
                "has_room_api": roomApi != nil,
                "local_persistence_enabled": self.outbox != nil || self.checkpointStore != nil,
                "sync_fps": self.syncFps,
                "live_stroke_enable": liveStrokeEnable,
                "live_stroke_budget_qps": liveStrokeBudgetQps ?? Self.liveStrokeBudgetQps,
                "live_stroke_single_shot_max_ms":
                    liveStrokeSingleShotMaxMs ?? Self.liveStrokeSingleShotMaxMs,
            ] as [String: Any],
        ]))
    }

    func isDataSyncEnable() -> Bool { dataSyncEnable }

    func setDataSyncEnable(_ enable: Bool) {
        dataSyncEnable = enable
        executeLiveRuntimeEvent([
            "type": "set_data_sync_enable",
            "enable": enable,
        ])
        sendCollaborationEnabled(enable)
    }

    func sendCollaborationEnabled(_ enable: Bool? = nil) {
        let requested = enable ?? dataSyncEnable
        sendJson(PlatformEvents.withType(PlatformEventType.setCollaborationEnabled) { payload in
            // DK_SYNCDATA/addSyncData is a supported manual transport too.
            payload["enabled"] = requested
        })
    }

    func setSyncFps(_ fps: Int) {
        syncFps = Self.clampSyncFps(fps)
    }

    func getSyncTime() -> Int { Int(syncTime) }

    func getPendingSyncOpsCount() -> Int { pendingAck.count }

    func clearLocalSyncOutbox() {
        executeRuntimeCommands(syncRuntime.handle(["type": "clear_local_persistence"]))
    }

    func onCredentialsUpdated() {
        executeRuntimeCommands(syncRuntime.handle(["type": "resume_ops_flush"]))
    }

    func onLocalSyncOut(_ json: String) {
        guard dataSyncEnable, let envelope = JSONCodec.parseObject(json) else { return }
        guard let opId = envelope["op_id"] as? String, !opId.isEmpty else { return }
        executeRuntimeCommands(syncRuntime.handle([
            "type": "local_sync_out",
            "envelope": envelope,
        ]))
        let opType = (envelope["op"] as? [String: Any])?["type"] as? String
        log?.action(
            "sync.outbox.enqueue",
            phase: "ok",
            result: "ok",
            detail: ["op_id": opId, "seq": envelope["seq"] as Any, "op_type": opType as Any]
        )
    }

    func addSyncData(_ data: Any) {
        handleInboundMessage(data)
    }

    func addAckData(_ data: Any) {
        guard let envelope = Self.parseEnvelope(data),
              let opId = envelope["op_id"] as? String else {
            warn(DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_SYNC_DATA_PARSE_FAILED, "addAckData: invalid payload")
            return
        }
        executeRuntimeCommands(syncRuntime.handle(["type": "ack_op", "op_id": opId]))
    }

    /// Volatile in-progress ink from the engine. It never enters the outbox, so
    /// peers watch the stroke being drawn while the committed op that follows
    /// stays the source of truth.
    func onLocalLiveStrokeOut(_ json: String) {
        guard dataSyncEnable, let envelope = JSONCodec.parseObject(json) else { return }
        executeRuntimeCommands(syncRuntime.handle([
            "type": "local_live_stroke_out",
            "envelope": envelope,
        ]))
    }

    func handleInboundMessage(_ data: Any) {
        if handleInboundLiveStroke(data) { return }
        guard let envelope = Self.parseEnvelope(data) else {
            warn(DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_SYNC_DATA_PARSE_FAILED, "inbound sync: invalid payload")
            return
        }
        executeLiveRuntimeEvent([
            "type": "inbound_im",
            "envelope": envelope,
        ])
    }

    /// IM delivers committed ops and volatile ink on the same channel; only live
    /// envelopes carry `stroke_id` + `phase`, so the two shapes never collide.
    private func handleInboundLiveStroke(_ data: Any) -> Bool {
        guard let live = LiveStrokeEnvelopePayload.parse(data) else { return false }
        executeLiveRuntimeEvent([
            "type": "inbound_live_stroke",
            "envelope": live.raw,
            "now_ms": Int64(Date().timeIntervalSince1970 * 1000),
        ])
        return true
    }

    /// Keep Rust timer state and its host timer effects atomic with prune callbacks.
    private func executeLiveRuntimeEvent(_ event: [String: Any]) {
        liveStrokePruneLock.lock()
        defer { liveStrokePruneLock.unlock() }
        guard !destroyed else { return }
        executeRuntimeCommands(syncRuntime.handle(event))
    }

    private func executeRuntimeCommands(_ commands: [[String: Any]]) {
        guard !destroyed else { return }
        for command in commands {
            switch command["type"] as? String {
            case "http":
                executeRuntimeHttp(command)
            case "persist_outbox_append":
                guard let envelope = command["envelope"] as? [String: Any],
                      let opId = command["op_id"] as? String, !opId.isEmpty else { continue }
                pendingAck[opId] = envelope
                persistToOutbox(envelope)
            case "persist_outbox_ack":
                let ids = command["op_ids"] as? [String] ?? []
                ids.forEach { pendingAck.removeValue(forKey: $0) }
                outbox?.markAcked(opIds: ids)
            case "persist_outbox_prune":
                outbox?.pruneAcked(roomId: roomId, maxAgeMs: 86_400_000, maxCount: 1000)
            case "persist_local_clear":
                pendingAck.removeAll()
                outbox?.clearRoom(roomId: roomId, clientId: clientId)
                checkpointStore?.clear(roomId: roomId, clientId: clientId)
            case "persist_local_flush":
                outbox?.flush()
                checkpointStore?.flush()
            case "persist_local_load":
                try? hydrateOutbox()
                try? loadLocalCheckpoint()
                hydrateRuntimePending(syncRuntime)
            case "cancel_board_prefetch":
                cancelBoardPrefetch()
            case "schedule_board_prefetch":
                executeBoardPrefetch(
                    boardId: command["board_id"] as? String ?? "",
                    delayMs: (command["delay_ms"] as? NSNumber)?.int64Value ?? 0
                )
            case "persist_checkpoint":
                guard let workspace = command["workspace"] as? [String: Any],
                      let workspaceJson = JSONCodec.stringify(workspace) else { continue }
                localCheckpointSeq = (command["local_checkpoint_seq"] as? NSNumber)?.int64Value ?? 0
                checkpointStore?.save(WorkspaceCheckpointRecord(
                    roomId: roomId,
                    clientId: clientId,
                    workspaceJson: workspaceJson,
                    updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                    localCheckpointSeq: localCheckpointSeq
                ))
            case "request_workspace_export":
                let runExport: () -> Void = { [weak self] in
                    guard let self, !self.destroyed, let workspace = self.exportWorkspace?() else { return }
                    self.executeRuntimeCommands(self.syncRuntime.handle([
                        "type": "workspace_export", "workspace": workspace,
                    ]))
                }
                // Destroy must export before the native engine is freed. The
                // async hop is only for live sync_out re-entrancy.
                if tearingDown {
                    runExport()
                } else {
                    coordinationQueue.async(execute: runExport)
                }
            case "bridge_apply_sync":
                guard let envelope = command["envelope"] as? [String: Any] else { continue }
                sendJson(PlatformEvents.withType(PlatformEventType.applySync) { payload in
                    payload["envelope"] = envelope
                    payload["now_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
                })
            case "bridge_reject_sync":
                let ids = command["op_ids"] as? [String] ?? []
                sendJson(PlatformEvents.withType(PlatformEventType.rejectSync) { $0["op_ids"] = ids })
            case "bridge_refresh_courseware":
                if let file = command["file"] as? [String: Any], let event = coursewareRefreshEvent(file) {
                    sendJson(event)
                }
            case "schedule_courseware_asset_refresh":
                scheduleCoursewareAssetRefresh(
                    fileId: command["file_id"] as? String ?? "",
                    delayMs: (command["delay_ms"] as? NSNumber)?.int64Value ?? 0
                )
            case "emit":
                let event = command["event"] as? String ?? ""
                if event != DrawsKitConstants.EVENT.DK_HISTROYDATA_SYNCCOMPLETED || !historyLoaded {
                    emitEvent(event, [command["payload"] ?? [:]])
                }
            case "warn":
                warn(
                    DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_SYNC_DATA_PARSE_FAILED,
                    command["message"] as? String ?? "sync warning"
                )
            case "set_draw_gate":
                historyLoaded = command["history_ready"] as? Bool ?? false
            case "schedule_timer":
                scheduleRuntimeTimer(
                    kind: command["kind"] as? String ?? "",
                    delayMs: (command["delay_ms"] as? NSNumber)?.int64Value ?? 0
                )
            case "cancel_timer":
                cancelRuntimeTimer(kind: command["kind"] as? String ?? "")
            case "im_send":
                for envelope in command["envelopes"] as? [[String: Any]] ?? [] {
                    if let imTransport { imTransport.send(envelope) }
                    else { emitEvent(DrawsKitConstants.EVENT.DK_SYNCDATA, [envelope]) }
                }
            case "im_send_live_stroke":
                guard let envelope = command["envelope"] as? [String: Any] else { continue }
                if let imTransport {
                    imTransport.send(envelope)
                } else {
                    emitEvent(DrawsKitConstants.EVENT.DK_SYNCDATA, [envelope])
                }
            case "bridge_apply_live_stroke":
                guard let envelope = command["envelope"] as? [String: Any] else { continue }
                let nowMs = (command["now_ms"] as? NSNumber)?.int64Value ?? 0
                sendJson(PlatformEvents.withType(PlatformEventType.applyLiveStroke) { payload in
                    payload["envelope"] = envelope
                    payload["now_ms"] = nowMs
                })
            case "bridge_live_stroke_prune":
                let nowMs = (command["now_ms"] as? NSNumber)?.int64Value ?? 0
                sendJson(PlatformEvents.withType(PlatformEventType.pruneLiveStrokes) { payload in
                    payload["now_ms"] = nowMs
                })
            case "schedule_live_stroke_prune":
                let delayMs = (command["delay_ms"] as? NSNumber)?.int64Value ?? 0
                scheduleLiveStrokePrune(delayMs: delayMs)
            case "cancel_live_stroke_prune":
                cancelLiveStrokePrune()
            case "set_live_stroke_rate":
                let intervalMs = (command["interval_ms"] as? NSNumber)?.int64Value ?? 0
                let singleShotMaxMs = (command["single_shot_max_ms"] as? NSNumber)?.int64Value ?? 0
                sendJson(PlatformEvents.withType(PlatformEventType.setLiveStrokeRate) { payload in
                    payload["interval_ms"] = intervalMs
                    payload["single_shot_max_ms"] = singleShotMaxMs
                })
            case "start_live_stroke_ticker":
                startLiveStrokeTicker()
            case "stop_live_stroke_ticker":
                stopLiveStrokeTicker()
            default:
                continue
            }
        }
        lastKnownServerSeq = syncRuntime.lastKnownServerSeq
        historyLoaded = syncRuntime.historyLoaded
    }

    private func scheduleRuntimeTimer(kind: String, delayMs: Int64) {
        cancelRuntimeTimer(kind: kind)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.runtimeTimers.removeValue(forKey: kind)
            self.executeRuntimeCommands(self.syncRuntime.handle(["type": "timer", "kind": kind]))
        }
        runtimeTimers[kind] = work
        coordinationQueue.asyncAfter(
            deadline: .now() + .milliseconds(Int(max(0, delayMs))),
            execute: work
        )
    }

    private func cancelRuntimeTimer(kind: String) {
        runtimeTimers.removeValue(forKey: kind)?.cancel()
    }

    private func executeRuntimeHttp(_ command: [String: Any]) {
        guard let roomApi else { return }
        let requestId = (command["request_id"] as? NSNumber)?.int64Value ?? 0
        let endpoint = command["endpoint"] as? String ?? ""
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                let body: [String: Any]
                switch endpoint {
                case "bootstrap":
                    let query = command["query"] as? [String: Any]
                    let since = (query?["since_seq"] as? NSNumber)?.int64Value
                    let state = try roomApi.fetchRoomBootstrap(sinceSeq: since)
                    self.coordinationQueue.async { self.bootstrap(state) }
                    body = self.bootstrapSeed(state)
                case "sync_reload":
                    let requestBody = command["body"] as? [String: Any]
                    let state = try roomApi.syncReload(
                        clientId: requestBody?["client_id"] as? String ?? self.clientId,
                        pendingOps: requestBody?["pending_ops"] as? [[String: Any]] ?? [],
                        lastKnownSeq: (requestBody?["last_known_seq"] as? NSNumber)?.int64Value
                            ?? self.lastKnownServerSeq
                    )
                    self.coordinationQueue.async { self.bootstrap(state) }
                    body = self.bootstrapSeed(state)
                case "ops":
                    let requestBody = command["body"] as? [String: Any]
                    body = try roomApi.reportOps(
                        envelopes: requestBody?["envelopes"] as? [[String: Any]] ?? []
                    )
                case "checkpoints":
                    let requestBody = command["body"] as? [String: Any]
                    try roomApi.createCheckpoint(
                        workspace: requestBody?["workspace"] as? [String: Any] ?? [:]
                    )
                    body = ["checkpoint_seq": self.syncRuntime.lastKnownServerSeq]
                default:
                    return
                }
                self.coordinationQueue.async {
                    self.executeRuntimeCommands(self.syncRuntime.handle([
                        "type": "http_result",
                        "request_id": requestId,
                        "ok": true,
                        "body": body,
                    ]))
                }
            } catch {
                self.coordinationQueue.async {
                    var result: [String: Any] = [
                        "type": "http_result",
                        "request_id": requestId,
                        "ok": false,
                        "error": error.localizedDescription,
                    ]
                    if let http = error as? RoomApiHttpError { result["status"] = http.status }
                    self.executeRuntimeCommands(self.syncRuntime.handle(result))
                }
            }
        }
    }

    private func bootstrapSeed(_ state: RoomBootstrapPayload) -> [String: Any] {
        let last = state.tail.reduce(state.checkpointSeq) { value, item in
            max(value, (item["server_seq"] as? NSNumber)?.int64Value ?? value)
        }
        return ["checkpoint_seq": state.checkpointSeq, "last_server_seq": last]
    }

    /// Peer ink arrives at a fraction of the display rate, so the engine plays
    /// it back against a clock it does not own. Drawing the chunks as they land
    /// would read as a series of jumps instead of a stroke.
    private func startLiveStrokeTicker() {
        // Inbound IM lands on the transport's queue; the display link belongs
        // to the main run loop.
        liveStrokeTickerLock.lock()
        guard !liveStrokeTickerDestroyed else {
            liveStrokeTickerLock.unlock()
            return
        }
        liveStrokeTickerGeneration &+= 1
        let generation = liveStrokeTickerGeneration
        liveStrokeTickerLock.unlock()
        liveStrokeTickerLock.lock()
        guard !liveStrokeTickerDestroyed,
              generation == liveStrokeTickerGeneration,
              liveStrokeTicker == nil else {
            liveStrokeTickerLock.unlock()
            return
        }
        let ticker = LiveStrokeTicker { [weak self] in
            guard let self else { return }
            self.sendJson(PlatformEvents.withType(PlatformEventType.tickLiveStrokes) { payload in
                payload["now_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
            })
        }
        ticker.start()
        liveStrokeTicker = ticker
        liveStrokeTickerLock.unlock()
    }

    private func stopLiveStrokeTicker() {
        liveStrokeTickerLock.lock()
        liveStrokeTickerGeneration &+= 1
        let ticker = liveStrokeTicker
        liveStrokeTicker = nil
        liveStrokeTickerLock.unlock()
        ticker?.stop()
    }

    private func scheduleLiveStrokePrune(delayMs: Int64) {
        liveStrokePruneLock.lock()
        liveStrokePruneGeneration &+= 1
        let generation = liveStrokePruneGeneration
        liveStrokePruneWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.liveStrokePruneLock.lock()
            guard generation == self.liveStrokePruneGeneration else {
                self.liveStrokePruneLock.unlock()
                return
            }
            self.liveStrokePruneWorkItem = nil
            self.executeRuntimeCommands(self.syncRuntime.handle([
                "type": "live_stroke_prune_due",
                "now_ms": Int64(Date().timeIntervalSince1970 * 1000),
            ]))
            self.liveStrokePruneLock.unlock()
        }
        liveStrokePruneWorkItem = item
        liveStrokePruneLock.unlock()
        coordinationQueue.asyncAfter(
            deadline: .now() + .milliseconds(Int(max(0, delayMs))),
            execute: item
        )
    }

    private func cancelLiveStrokePrune() {
        liveStrokePruneLock.lock()
        liveStrokePruneGeneration &+= 1
        liveStrokePruneWorkItem?.cancel()
        liveStrokePruneWorkItem = nil
        liveStrokePruneLock.unlock()
    }

    func onEngineEffects(_ effects: [[String: Any]]?) {
        guard let effects else { return }
        executeRuntimeCommands(syncRuntime.handle(["type": "engine_effects", "effects": effects]))
        for effect in effects {
            switch effect["type"] as? String {
            case "sync_gap":
                break
            case "sync_conflict":
                let ids = effect["conflicting_element_ids"] as? [String] ?? []
                warn(
                    DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_SYNC_DATA_PARSE_FAILED,
                    "authoritative revision conflict: \(ids.joined(separator: ","))"
                )
            case "sync_rebased", "sync_reload_required":
                break
            case "command_rejected":
                let command = effect["command"] as? String ?? "command"
                let reason = effect["reason"] as? String ?? "not allowed"
                warn(
                    DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_ILLEGAL_OPERATION,
                    "\(command) rejected: \(reason)"
                )
            case "room_transaction_applied":
                log?.action(
                    "room.transaction.apply",
                    phase: "ok",
                    result: "ok",
                    detail: ["transaction_id": effect["transaction_id"] as? String ?? ""]
                )
            default:
                break
            }
        }
    }

    func ackByOpId(_ opId: String) {
        guard !opId.isEmpty else { return }
        coordinationQueue.async { [weak self] in
            guard let self else { return }
            self.executeRuntimeCommands(self.syncRuntime.handle(["type": "ack_op", "op_id": opId]))
        }
    }

    func renderHistoryData(_ data: Any) {
        coordinationQueue.async { [weak self] in self?.applyHistoryPayload(data) }
    }

    func onCoursewareAssetFailed(fileId: String, url: String, reason: String, status: Int? = nil) {
        var event: [String: Any] = [
            "type": "courseware_asset_failed",
            "file_id": fileId,
            "url": url,
            "reason": reason,
            "now_ms": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        if let status { event["status"] = status }
        coordinationQueue.async { [weak self] in
            guard let self else { return }
            self.executeCoursewareRuntimeCommands(self.syncRuntime.handle(event))
        }
    }

    private func executeCoursewareRuntimeCommands(_ commands: [[String: Any]]) {
        guard let roomApi else { return }
        for command in commands {
            switch command["type"] as? String {
            case "http" where command["endpoint"] as? String == "courseware_assets":
                guard let query = command["query"] as? [String: Any],
                      let fileId = query["file_id"] as? String,
                      !fileId.isEmpty else { continue }
                let requestId = (command["request_id"] as? NSNumber)?.int64Value ?? 0
                ioQueue.async { [weak self] in
                    guard let self else { return }
                    do {
                        var response = try roomApi.refreshCoursewareAssets(
                        fileId: fileId,
                        timeoutMs: visibleRefreshTimeoutMs
                    )
                        if let file = response["file"] as? [String: Any] {
                            response["file"] = self.rewriteCoursewareFile(file)
                        }
                        self.coordinationQueue.async {
                            self.executeCoursewareRuntimeCommands(self.syncRuntime.handle([
                                "type": "http_result",
                                "request_id": requestId,
                                "ok": true,
                                "body": response,
                            ]))
                        }
                    } catch {
                        var result: [String: Any] = [
                            "type": "http_result",
                            "request_id": requestId,
                            "ok": false,
                            "error": error.localizedDescription,
                        ]
                        if let status = (error as? RoomApiHttpError)?.status { result["status"] = status }
                        self.coordinationQueue.async {
                            self.executeCoursewareRuntimeCommands(self.syncRuntime.handle(result))
                        }
                    }
                }
            case "bridge_refresh_courseware":
                if let file = command["file"] as? [String: Any],
                   let event = coursewareRefreshEvent(file) {
                    sendJson(event)
                }
            case "schedule_courseware_asset_refresh":
                scheduleCoursewareAssetRefresh(
                    fileId: command["file_id"] as? String ?? "",
                    delayMs: (command["delay_ms"] as? NSNumber)?.int64Value ?? 0
                )
            case "warn":
                warn(
                    DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_ASSET_LOAD_FAILED,
                    command["message"] as? String ?? "courseware refresh failed"
                )
            default:
                break
            }
        }
    }

    private func noteCoursewareAssetRefreshed(fileId: String, response: [String: Any]) {
        guard let expiresIn = (response["assetUrlExpiresIn"] as? NSNumber)?.int64Value,
              expiresIn > 0 else { return }
        coordinationQueue.async { [weak self] in
            guard let self else { return }
            self.executeCoursewareRuntimeCommands(self.syncRuntime.handle([
                "type": "courseware_asset_refreshed",
                "file_id": fileId,
                "expires_in_seconds": expiresIn,
            ]))
        }
    }

    private func scheduleCoursewareAssetRefresh(fileId: String, delayMs: Int64) {
        guard !fileId.isEmpty else { return }
        coursewareRefreshWorkItems.removeValue(forKey: fileId)?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.coursewareRefreshWorkItems.removeValue(forKey: fileId)
            self.executeCoursewareRuntimeCommands(self.syncRuntime.handle([
                "type": "courseware_asset_refresh_due",
                "file_id": fileId,
                "now_ms": Int64(Date().timeIntervalSince1970 * 1000),
            ]))
        }
        coursewareRefreshWorkItems[fileId] = item
        coordinationQueue.asyncAfter(
            deadline: .now() + .milliseconds(Int(max(0, delayMs))),
            execute: item
        )
    }

    func syncAndReload() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.executeRuntimeCommands(self.syncRuntime.handle(["type": "load_local_persistence"]))
            self.coordinationQueue.async {
                self.executeRuntimeCommands(self.syncRuntime.handle(["type": "begin_reload"]))
            }
        }
    }

    /// Blocking join history load (call off the main thread). Returns false on failure.
    @discardableResult
    func loadInitialHistory() -> Bool {
        if reloadInProgress { return false }
        reloadInProgress = true
        log?.action("sync.history.load", phase: "start")
        defer { reloadInProgress = false }
        do {
            executeRuntimeCommands(syncRuntime.handle(["type": "load_local_persistence"]))
            let bootstrap = try fetchBootstrapForJoin()
            if let bootstrap {
                self.bootstrap(bootstrap)
                log?.action(
                    "sync.history.load",
                    phase: "ok",
                    result: "ok",
                    detail: [
                        "checkpoint_seq": bootstrap.checkpointSeq,
                        "tail": bootstrap.tail.count,
                        "has_workspace": bootstrap.workspace != nil,
                    ]
                )
            } else {
                completeHistorySync(Int64(Date().timeIntervalSince1970 * 1000))
                log?.action(
                    "sync.history.load",
                    phase: "ok",
                    result: "ok",
                    detail: ["mode": "local_only"]
                )
            }
            return true
        } catch {
            warn(
                DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_SYNC_DATA_PARSE_FAILED,
                "initial history load failed: \(error.localizedDescription)"
            )
            log?.action(
                "sync.history.load",
                phase: "fail",
                result: "error",
                level: 2,
                detail: ["message": error.localizedDescription]
            )
            return false
        }
    }

    func destroy(onComplete: (() -> Void)? = nil) {
        liveStrokeTickerLock.lock()
        liveStrokeTickerDestroyed = true
        liveStrokeTickerLock.unlock()
        cancelBoardPrefetch()
        coursewareRefreshQueue.cancelAllOperations()
        coursewareRefreshWorkItems.values.forEach { $0.cancel() }
        coursewareRefreshWorkItems.removeAll()
        cancelLiveStrokePrune()
        stopLiveStrokeTicker()
        // Export and native teardown stay on this serial queue so they cannot
        // race DrawsKitEngine releasing the FFI handle, and JSON stays off main.
        coordinationQueue.async {
            if self.destroyed {
                onComplete?()
                return
            }
            self.tearingDown = true
            self.executeRuntimeCommands(self.syncRuntime.handle(["type": "destroy"]))
            self.destroyed = true
            self.tearingDown = false
            self.syncRuntime.destroy()
            onComplete?()
        }
    }

    private func loadLocalCheckpoint() throws {
        guard let checkpointStore, let importWorkspace else { return }
        guard let saved = try checkpointStore.load(roomId: roomId, clientId: clientId),
              let workspace = JSONCodec.parseObject(saved.workspaceJson) else { return }
        importWorkspace(workspace)
        localCheckpointSeq = saved.localCheckpointSeq
        if let checkpointSeq = (workspace["checkpoint_seq"] as? NSNumber)?.int64Value,
           checkpointSeq > lastKnownServerSeq {
            lastKnownServerSeq = checkpointSeq
        }
    }

    private func hydrateOutbox() throws {
        guard let outbox, !outboxHydrated else { return }
        let pending = try outbox.listPending(roomId: roomId, clientId: clientId)
        for record in pending {
            guard let envelope = JSONCodec.parseObject(record.envelopeJson) else { continue }
            pendingAck[record.opId] = envelope
        }
        outboxHydrated = true
    }

    private func persistToOutbox(_ envelope: [String: Any]) {
        guard let outbox, let record = buildOutboxRecord(roomId: roomId, clientId: clientId, envelope: envelope) else { return }
        outbox.append(record)
    }

    private func fetchBootstrapForJoin() throws -> RoomBootstrapPayload? {
        hydrateRuntimePending(syncRuntime)
        if lastKnownServerSeq > 0 {
            _ = syncRuntime.handle([
                "type": "seed_local_checkpoint_seq",
                "checkpoint_seq": lastKnownServerSeq,
            ])
        }
        let cmds = syncRuntime.handle(["type": "begin_join"])
        if let payload = try executeRuntimeFetch(syncRuntime, cmds: cmds) {
            return payload
        }
        return nil
    }

    private func hydrateRuntimePending(_ rt: SyncRuntime) {
        let records: [[String: Any]] = pendingAck.map { opId, envelope in
            ["op_id": opId, "envelope": envelope]
        }
        _ = rt.handle(["type": "hydrate_outbox", "records": records])
    }

    private func executeRuntimeFetch(_ rt: SyncRuntime, cmds: [[String: Any]]) throws -> RoomBootstrapPayload? {
        guard let roomApi else { return nil }
        for cmd in cmds {
            guard (cmd["type"] as? String) == "http" else { continue }
            let requestId = cmd["request_id"] as? Int64 ?? Int64(cmd["request_id"] as? Int ?? 0)
            let endpoint = cmd["endpoint"] as? String ?? ""
            do {
                let body: RoomBootstrapPayload?
                switch endpoint {
                case "sync_reload":
                    let reqBody = cmd["body"] as? [String: Any] ?? [:]
                    let pending = (reqBody["pending_ops"] as? [[String: Any]]) ?? Array(pendingAck.values)
                    let seq = (reqBody["last_known_seq"] as? NSNumber)?.int64Value ?? lastKnownServerSeq
                    body = try roomApi.syncReload(
                        clientId: (reqBody["client_id"] as? String) ?? clientId,
                        pendingOps: pending,
                        lastKnownSeq: seq
                    )
                case "bootstrap":
                    let since = (cmd["query"] as? [String: Any])?["since_seq"] as? NSNumber
                    let sinceSeq = since.flatMap { $0.int64Value > 0 ? $0.int64Value : nil }
                    body = try roomApi.fetchRoomBootstrap(sinceSeq: sinceSeq)
                default:
                    body = nil
                }
                guard let body else { return nil }
                var lastServerSeq = body.checkpointSeq
                for item in body.tail {
                    if let seq = item["server_seq"] as? NSNumber {
                        lastServerSeq = max(lastServerSeq, seq.int64Value)
                    } else if let seq = item["server_seq"] as? Int64 {
                        lastServerSeq = max(lastServerSeq, seq)
                    }
                }
                let resultBody: [String: Any] = [
                    "checkpoint_seq": body.checkpointSeq,
                    "last_server_seq": lastServerSeq,
                ]
                _ = rt.handle([
                    "type": "http_result",
                    "request_id": requestId,
                    "ok": true,
                    "body": resultBody,
                ])
                lastKnownServerSeq = rt.lastKnownServerSeq
                return body
            } catch {
                _ = rt.handle([
                    "type": "http_result",
                    "request_id": requestId,
                    "ok": false,
                    "error": error.localizedDescription,
                ])
                throw error
            }
        }
        return nil
    }

    private func applyHistoryPayload(_ data: Any) {
        if let dict = data as? [String: Any], dict["checkpoint_seq"] != nil, dict["tail"] != nil {
            guard let state = Self.bootstrapFromDict(dict) else {
                warn(DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_SYNC_DATA_PARSE_FAILED, "renderHistoryData: invalid workspace snapshot")
                return
            }
            bootstrap(state)
            return
        }
        if let list = data as? [[String: Any]] {
            bootstrap(RoomBootstrapPayload(workspace: nil, checkpointSeq: 0, tail: list))
            return
        }
        warn(DrawsKitConstants.WarningCode.DRAWSKIT_WARNING_SYNC_DATA_PARSE_FAILED, "renderHistoryData: unsupported payload")
    }

    private func bootstrap(_ state: RoomBootstrapPayload) {
        let refresh = refreshBootstrapCoursewareAssets(state)
        let refreshedState = refresh.state
        log?.action(
            "room.bootstrap",
            phase: "start",
            detail: [
                "checkpoint_seq": refreshedState.checkpointSeq,
                "tail": refreshedState.tail.count,
                "has_workspace": refreshedState.workspace != nil,
            ]
        )
        sendJson(PlatformEvents.withType(PlatformEventType.bootstrapRoom) { payload in
            payload["workspace"] = refreshedState.workspace ?? NSNull()
            payload["checkpoint_seq"] = refreshedState.checkpointSeq
            payload["tail"] = refreshedState.tail
        })
        refreshCoursewareAssetsInBackground(refresh.deferredBatches)
        seedServerSeq(refreshedState)
        completeHistorySync(Int64(Date().timeIntervalSince1970 * 1000))
        log?.action(
            "room.bootstrap",
            phase: "ok",
            result: "ok",
            detail: ["checkpoint_seq": refreshedState.checkpointSeq, "tail": refreshedState.tail.count]
        )
        executeRuntimeCommands(syncRuntime.handle([
            "type": "plan_board_prefetch",
            "workspace": refreshedState.workspace ?? [:],
        ]))
    }

    private func refreshBootstrapCoursewareAssets(
        _ state: RoomBootstrapPayload
    ) -> (state: RoomBootstrapPayload, deferredBatches: [[String]]) {
        var bootstrap = bootstrapDict(state)
        var nextState = state
        if let roomApi {
            if let rewritten = try? SyncPolicy.rewriteCoursewareContentUrls(
                bootstrap,
                roomApiBase: roomApi.collaborationBaseUrl(),
                roomId: roomApi.roomId()
            ) {
                bootstrap = rewritten
                nextState = payloadFromBootstrapDict(rewritten)
            }
        }
        guard let plan = try? SyncPolicy.planCoursewareAssetRefresh(bootstrap) else {
            return (nextState, [])
        }
        if plan.prefetchFirstPage, let first = plan.firstPage {
            prefetchFirstPage(url: first.url, format: first.format)
        }
        var deferred = plan.deferredBatches
        if let activeId = plan.blockingFileIds.first, roomApi != nil {
            visibleCoursewareFileId = activeId
            visibleCoursewarePageIndex = plan.firstPage?.pageIndex ?? 0
            prefetchedCoursewareUrl = plan.firstPage?.url
            visibleRefreshTimeoutMs = plan.httpTimeoutMs > 0
                ? plan.httpTimeoutMs
                : SyncPolicy.coursewareRefreshHttpTimeoutMs
            deferred.insert([activeId], at: 0)
        }
        return (nextState, deferred)
    }

    private func rewriteCoursewareFile(_ file: [String: Any]) -> [String: Any] {
        guard let roomApi else { return file }
        return (try? SyncPolicy.rewriteCoursewareFileContentUrls(
            file,
            roomApiBase: roomApi.collaborationBaseUrl(),
            roomId: roomApi.roomId()
        )) ?? file
    }

    private func payloadFromBootstrapDict(_ dict: [String: Any]) -> RoomBootstrapPayload {
        let workspace = dict["workspace"] as? [String: Any]
        let checkpoint = (dict["checkpoint_seq"] as? NSNumber)?.int64Value ?? 0
        let tail = dict["tail"] as? [[String: Any]] ?? []
        return RoomBootstrapPayload(workspace: workspace, checkpointSeq: checkpoint, tail: tail)
    }

    private func prefetchFirstPage(url: String, format: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        prefetchCoursewarePage?(trimmed, format)
    }

    private func prefetchRefreshedVisiblePage(_ file: [String: Any]) {
        guard let pages = normalizedCoursewarePages(file), !pages.isEmpty else { return }
        let index = min(max(0, visibleCoursewarePageIndex), pages.count - 1)
        let url = coursewarePageUrl(pages[index])
        guard !url.isEmpty else { return }
        prefetchedCoursewareUrl = url
        prefetchFirstPage(url: url, format: pages[index]["format"] as? String ?? "")
    }

    private func refreshCoursewareAssetsInBackground(_ batches: [[String]]) {
        guard let roomApi else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            for batch in batches {
                for fileId in batch {
                let startedAt = CFAbsoluteTimeGetCurrent()
                do {
                    let response = try roomApi.refreshCoursewareAssets(
                        fileId: fileId,
                        timeoutMs: self.visibleRefreshTimeoutMs
                    )
                    guard let rawFile = response["file"] as? [String: Any] else {
                        self.logCoursewareRefresh(fileId, startedAt: startedAt, result: "invalid_payload", blocking: false)
                        continue
                    }
                    let file = self.rewriteCoursewareFile(rawFile)
                    guard self.coursewareFileId(file) == fileId else {
                        self.logCoursewareRefresh(fileId, startedAt: startedAt, result: "invalid_payload", blocking: false)
                        continue
                    }
                    self.noteCoursewareAssetRefreshed(fileId: fileId, response: response)
                    if fileId == self.visibleCoursewareFileId {
                        self.prefetchRefreshedVisiblePage(file)
                    }
                    guard let event = self.coursewareRefreshEvent(file) else { continue }
                    self.coordinationQueue.async { [weak self] in self?.sendJson(event) }
                    self.logCoursewareRefresh(fileId, startedAt: startedAt, result: "background_updated", blocking: false)
                } catch {
                    self.logCoursewareRefresh(
                        fileId,
                        startedAt: startedAt,
                        result: "background_fallback",
                        blocking: false,
                        message: error.localizedDescription
                    )
                    self.coordinationQueue.async { [weak self] in
                        guard let self else { return }
                        self.executeCoursewareRuntimeCommands(self.syncRuntime.handle([
                            "type": "courseware_asset_refresh_due",
                            "file_id": fileId,
                            "now_ms": Int64(Date().timeIntervalSince1970 * 1_000),
                        ]))
                    }
                }
            }
            }
        }
    }

    private func bootstrapDict(_ state: RoomBootstrapPayload) -> [String: Any] {
        [
            "workspace": state.workspace ?? NSNull(),
            "checkpoint_seq": state.checkpointSeq,
            "tail": state.tail,
        ]
    }

    private func coursewareFileId(_ file: [String: Any]) -> String? {
        let id = (file["file_id"] as? String) ?? (file["fileId"] as? String)
        guard let id, !id.isEmpty, file["pages"] is [Any] else { return nil }
        return id
    }

    private func coursewarePageUrl(_ page: [String: Any]) -> String {
        let url = (page["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !url.isEmpty { return url }
        return (page["src"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func normalizedCoursewarePages(_ file: [String: Any]) -> [[String: Any]]? {
        guard var pages = file["pages"] as? [[String: Any]] else { return nil }
        for index in pages.indices {
            if coursewarePageUrl(pages[index]).isEmpty { continue }
            if (pages[index]["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                pages[index]["url"] = coursewarePageUrl(pages[index])
            }
        }
        return pages
    }

    private func coursewareRefreshEvent(_ file: [String: Any]) -> String? {
        guard let id = coursewareFileId(file),
              let pages = normalizedCoursewarePages(file) else { return nil }
        let renderMode = (file["render_mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceType = (file["source_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlatformEvents.withType(PlatformEventType.loadCourseware) { payload in
            payload["resource_id"] = id
            payload["render_mode"] = (renderMode?.isEmpty == false)
                ? renderMode!
                : EngineDefaults.coursewareRenderModeStaticImage
            payload["source_type"] = (sourceType?.isEmpty == false)
                ? sourceType!
                : EngineDefaults.coursewareSourceTypeImage
            payload["webview_url"] = file["webview_url"] ?? NSNull()
            payload["pages"] = pages
            payload["title"] = file["title"] ?? NSNull()
        }
    }

    private func logCoursewareRefresh(
        _ fileId: String,
        startedAt: CFAbsoluteTime,
        result: String,
        blocking: Bool,
        message: String? = nil
    ) {
        log?.action(
            "courseware.assets.refresh",
            phase: result == "updated" || result == "background_updated" ? "ok" : "skip",
            result: result,
            detail: [
                "file_id": fileId,
                "blocking": blocking,
                "duration_ms": (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000,
                "message": message as Any,
            ]
        )
    }

    private func cancelBoardPrefetch() {
        prefetchWorkItems.forEach { $0.cancel() }
        prefetchWorkItems.removeAll()
    }

    private func executeBoardPrefetch(boardId: String, delayMs: Int64) {
        guard !boardId.isEmpty else { return }
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [weak self] in
            guard !item.isCancelled else { return }
            self?.sendJson(PlatformEvents.withType(PlatformEventType.prefetchBoard) { payload in
                payload["board_id"] = boardId
            })
        }
        prefetchWorkItems.append(item)
        ioQueue.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, delayMs))), execute: item)
    }

    private func seedServerSeq(_ state: RoomBootstrapPayload) {
        var maxSeq = state.checkpointSeq
        for envelope in state.tail {
            if let serverSeq = envelope["server_seq"] as? NSNumber {
                let value = serverSeq.int64Value
                if value > maxSeq { maxSeq = value }
            }
        }
        lastKnownServerSeq = maxSeq
        serverCheckpointSeq = max(serverCheckpointSeq, state.checkpointSeq)
    }

    private func completeHistorySync(_ ts: Int64) {
        syncTime = ts
        historyLoaded = true
        emitEvent(DrawsKitConstants.EVENT.DK_HISTROYDATA_SYNCCOMPLETED, [[
            "roomId": roomId,
            "syncTime": syncTime,
        ]])
        log?.action("sync.history.completed", phase: "ok", result: "ok", detail: ["sync_time": ts])
    }

    private static func parseEnvelope(_ data: Any) -> [String: Any]? {
        SyncEnvelopePayload.parse(data)?.raw
    }

    static func bootstrapFromDict(_ dict: [String: Any]) -> RoomBootstrapPayload? {
        guard let parsed = RoomBootstrapProtocolPayload.parse(dict) else { return nil }
        return RoomBootstrapPayload(
            workspace: parsed.workspace,
            checkpointSeq: parsed.checkpointSeq,
            tail: parsed.tail
        )
    }

    private static func clampSyncFps(_ fps: Int) -> Int {
        min(60, max(1, fps))
    }
}
