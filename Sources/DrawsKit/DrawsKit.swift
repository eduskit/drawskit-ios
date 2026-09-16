import Foundation
import UIKit

/// DrawsKit 互动白板 SDK（iOS）— 公开 API 薄封装，业务逻辑在 Rust 引擎。
public final class DrawsKit {
    public static let SDK_VERSION = "0.1.3"

    public static let EVENT = DrawsKitConstants.EVENT.self
    public static let ToolType = DrawsKitConstants.ToolType.self
    public static let ElementType = DrawsKitConstants.ElementType.self
    public static let ContentFitMode = DrawsKitConstants.ContentFitMode.self
    public static let BackgroundType = DrawsKitConstants.BackgroundType.self
    public static let TextStyle = DrawsKitConstants.TextStyle.self
    public static let ErrorCode = DrawsKitConstants.ErrorCode.self
    public static let WarningCode = DrawsKitConstants.WarningCode.self
    public static let DrawStatusCode = DrawsKitConstants.DrawStatusCode.self
    public static let MathToolType = DrawsKitConstants.MathToolType.self
    public static let SnapshotCode = DrawsKitConstants.SnapshotCode.self
    public static let LogLevel = DrawsKitConstants.LogLevel.self

    /// Package root for a manifest URL (`…/manifest.json` → directory).
    public static func manifestBaseUrl(_ manifestUrl: String) -> String {
        CoursewareMap.manifestBaseUrl(manifestUrl)
    }

    public let initParams: DrawsKitInitParams
    private var listeners: [String: [(Any) -> Void]] = [:]
    private lazy var engine = DrawsKitEngine(initParams: initParams) { [weak self] event, args in
        self?.emit(event, args: args)
    }

    public init(initParams: DrawsKitInitParams) {
        self.initParams = initParams
    }

    public static func getVersion() -> String { SDK_VERSION }

    public static func getEngineVersion() -> String { NativeEngine.getVersion() }

    /// Load native FFI without a token or room. Idempotent.
    public static func preload() {
        _ = NativeEngine.getVersion()
    }

    public func on(_ event: String, callback: @escaping (Any) -> Void) {
        listeners[event, default: []].append(callback)
    }

    public func off(_ event: String, callback: ((Any) -> Void)? = nil) {
        if let callback {
            listeners[event]?.removeAll { $0 as AnyObject === callback as AnyObject }
        } else {
            listeners.removeValue(forKey: event)
        }
    }

    private func emit(_ event: String, args: [Any]) {
        listeners[event]?.forEach { $0(args) }
    }

    // ── 生命周期 ──

    /// 当前绑定的 `DrawsKitView`；未 attach 时为 nil。
    public var attachedView: DrawsKitView? { engine.attachedView }

    public func attachView(_ drawsKitView: DrawsKitView, boardContainer: UIView? = nil) {
        engine.attachView(drawsKitView, boardContainer: boardContainer)
    }

    /** Replace the cloud Room Token without rebuilding the engine or surface. */
    public func updateCredentials(_ token: String) throws {
        try engine.updateCredentials(token)
    }

    /// 卸下 UI surface，保留引擎会话（横竖屏布局切换复用）。
    public func detachView() { engine.detachView() }

    /// 仅当仍绑定 `view` 时卸下 surface，避免布局切换时旧 dismantle 误卸新 surface。
    public func detachView(onlyIfView view: DrawsKitView) {
        engine.detachView(onlyIfView: view)
    }

    public func ready() -> Bool { engine.awaitReady() }

    public func destroy() { engine.destroy() }

    public func refresh() { engine.refresh() }

    public func reset() { engine.reset() }

    // ── 同步与数据 ──

    public func addSyncData(_ data: Any) { engine.addSyncData(data) }
    public func addAckData(_ data: Any) { engine.addAckData(data) }
    public func syncAndReload() { engine.syncAndReload() }
    public func renderHistoryData(_ data: Any) { engine.renderHistoryData(data) }
    public func getSyncTime() -> Int { engine.getSyncTime() }
    public func setSyncFps(_ fps: Int) { engine.setSyncFps(fps) }
    public func isDataSyncEnable() -> Bool { engine.isDataSyncEnable() }
    public func setDataSyncEnable(_ enable: Bool) { engine.setDataSyncEnable(enable) }

    public func getPendingSyncOpsCount() -> Int { engine.getPendingSyncOpsCount() }

    public func clearLocalSyncOutbox() { engine.clearLocalSyncOutbox() }

    public func getActiveRecordingId() -> String? { engine.getActiveRecordingId() }

    public func startRecording(externalRef: String? = nil) throws -> RecordingSession {
        try engine.startRecording(externalRef: externalRef)
    }

    public func stopRecording(recordingId: String? = nil) throws -> RecordingSession {
        try engine.stopRecording(recordingId: recordingId)
    }

    public func exportData() -> Any? { engine.exportData() }

    public func importData(_ data: Any) {
        guard let json = data as? String else { return }
        _ = engine.importData(json)
    }

    public func exportInLocalMode() -> Any? { exportData() }

    public func importInLocalMode(_ data: Any) { importData(data) }

    // ── 白板页 ──

    public func addBoard(_ options: Any? = nil) -> String { engine.addBoard(options: options) }
    public func deleteBoard(_ boardId: String) { engine.deleteBoard(boardId) }
    public func gotoBoard(_ boardId: String) { engine.gotoBoard(boardId) }
    public func nextBoard() { engine.nextBoard() }
    public func prevBoard() { engine.prevBoard() }
    public func getBoardList() -> [String] { engine.getBoardList() }
    public func getCurrentBoard() -> String { engine.getCurrentBoard() }
    public func getBoardRatio() -> String { engine.getBoardRatio() }
    public func setBoardRatio(_ ratio: String) { engine.setBoardRatio(ratio) }
    public func getBoardScale() -> Int { engine.getBoardScale() }
    public func setBoardScale(_ scale: Int) { engine.setBoardScale(scale) }
    public func getBoardScroll() -> [String: Int] { engine.getBoardScroll() }
    public func setBoardScroll(x: Int, y: Int) { engine.setBoardScroll(x: x, y: y) }
    public func getBoardClientSize() -> [String: Int] { engine.getBoardClientSize() }
    public func getBoardRemark(_ boardId: String) -> String { engine.getBoardRemark(boardId) }
    public func setBoardRemark(_ boardId: String, _ remark: String) { engine.setBoardRemark(boardId, remark) }

    // ── 课件 / 文件 ──

    public func addTranscodeFile(_ manifest: Any, baseUrl: String? = nil) -> String {
        engine.addTranscodeFile(manifest, baseUrl: baseUrl)
    }
    public func addImagesFile(_ urls: [String], _ title: String? = nil) -> String {
        engine.addImagesFile(urls, title: title)
    }
    public func addH5File(_ url: String, _ title: String? = nil) -> String { engine.addH5File(url, title: title) }
    public func getThumbnailImages(_ fileId: String) -> [String] { engine.getThumbnailImages(fileId) }
    public func getCoursewarePageCount() -> Int { engine.getCoursewarePageCount() }
    public func getCoursewarePageIndex() -> Int { engine.getCoursewarePageIndex() }
    public func deleteFile(_ fileId: String) { engine.deleteFile(fileId) }
    public func getCurrentFile() -> String { engine.getCurrentFile() }
    public func getFileBoardList(_ fileId: String) -> [String] { engine.getFileBoardList(fileId) }
    public func switchFile(_ fileId: String) { engine.switchFile(fileId) }
    public func getFileInfo(_ fileId: String) -> [String: Any]? { engine.getFileInfo(fileId) }
    public func getFileInfoList() -> [[String: Any]] { engine.getFileInfoList() }
    public func clearFileDraws(_ fileId: String) { engine.clearFileDraws(fileId) }
    public func gotoStep(_ step: Int) { engine.gotoStep(step) }
    public func nextStep() { engine.nextStep() }
    public func prevStep() { engine.prevStep() }
    public func canPrevStep() -> Bool { engine.canPrevStep() }
    public func canNextStep() -> Bool { engine.canNextStep() }

    // ── 工具与样式 ──

    public func setToolType(_ toolType: Int) { engine.setToolType(toolType) }
    public func getToolType() -> Int { engine.getToolType() }
    public func setBrushColor(_ color: String) { engine.setBrushColor(color) }
    public func getBrushColor() -> String { engine.getBrushColor() }
    public func setBrushThin(_ thin: Int) { engine.setBrushThin(thin) }
    public func getBrushThin() -> Int { engine.getBrushThin() }
    public func setBrushThinMode(_ mode: Int) { engine.setBrushThinMode(mode) }
    public func getBrushThinMode() -> Int { engine.getBrushThinMode() }
    public func setHighlighterColor(_ color: String) { engine.setHighlighterColor(color) }
    public func getHighlighterColor() -> String { engine.getHighlighterColor() }
    public func setLineStyle(_ style: Int) { engine.setLineStyle(style) }
    public func getLineStyle() -> Any { engine.getLineStyle() }
    public func setGraphStyle(_ style: Any) { engine.setGraphStyle(style) }
    public func getGraphStyle() -> Any { engine.getGraphStyle() }
    public func setGraphLineStyle(_ style: Int) { engine.setGraphLineStyle(style) }
    public func setOvalDrawMode(_ mode: Int) { engine.setOvalDrawMode(mode) }
    public func getOvalDrawMode() -> Int { engine.getOvalDrawMode() }
    public func setEraserSize(_ size: Int) { engine.setEraserSize(size) }
    public func getEraserSize() -> Int { engine.getEraserSize() }
    public func setEraserMode(_ mode: Int) { engine.setEraserMode(mode) }
    public func setPiecewiseErasureEnable(_ enable: Bool) { engine.setPiecewiseErasureEnable(enable) }
    public func isPiecewiseErasureEnable() -> Bool { engine.isPiecewiseErasureEnable() }
    public func setLaserSize(_ size: Int) { engine.setLaserSize(size) }
    public func getLaserSize() -> Int { engine.getLaserSize() }
    public func enablePenAutoFit() { engine.enablePenAutoFit() }
    public func setPenAutoFitEnable(_ enable: Bool) { engine.setPenAutoFitEnable(enable) }
    public func isPenAutoFitEnable() -> Bool { engine.isPenAutoFitEnable() }
    public func setPenAutoFittingMode(_ mode: Int) { engine.setPenAutoFittingMode(mode) }
    public func getPenAutoFittingMode() -> Int { engine.getPenAutoFittingMode() }
    public func setPerfectFreehandEnable(_ enable: Bool) { engine.setPerfectFreehandEnable(enable) }
    public func getPerfectFreehandEnable() -> Bool { engine.getPerfectFreehandEnable() }
    public func isStrokeTaperBlocked() -> Bool { engine.isStrokeTaperBlocked() }
    public func setTextColor(_ color: String) { engine.setTextColor(color) }
    public func getTextColor() -> String { engine.getTextColor() }
    public func setTextSize(_ size: Int) { engine.setTextSize(size) }
    public func getTextSize() -> Int { engine.getTextSize() }
    public func setTextStyle(_ style: Int) { engine.setTextStyle(style) }
    public func getTextStyle() -> Int { engine.getTextStyle() }
    public func setTextFontFamily(_ font: String) { engine.setTextFontFamily(font) }
    public func getTextFontFamily() -> String { engine.getTextFontFamily() }
    public func setTextLineHeight(_ height: Float) { engine.setTextLineHeight(height) }
    public func getTextLineHeight() -> Float { engine.getTextLineHeight() }
    public func setTextValue(_ value: String) { engine.setTextValue(value) }
    public func setNextTextInput(_ options: Any) { engine.setNextTextInput(options) }

    // ── 操作 ──

    public func undo() { engine.undo() }
    public func redo() { engine.redo() }
    public func clear() { engine.clear() }
    public func clearWithUndo() { engine.clearWithUndo() }
    public func cancelSelect() { engine.cancelSelect() }
    public func autoSelectedElement(_ id: String) { engine.autoSelectedElement(id) }

    public func copyElementsByIds(_ ids: String) {
        let list = ids.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        copyElementsByIds(list)
    }

    public func copyElementsByIds(_ ids: [String]) { engine.copyElementsByIds(ids) }

    public func getSelectedElementIds() -> [String] { engine.getSelectedElementIds() }
    public func setDrawEnable(_ enable: Bool) { engine.setDrawEnable(enable) }
    public func isDrawEnable() -> Bool { engine.isDrawEnable() }

    public func setLogLevel(_ level: Int) {
        engine.operationLogger.setLevel(level)
        NativeEngine.setLogLevel(level)
    }

    public func setLogCallback(_ callback: LogLineCallback?) {
        engine.operationLogger.setLogCallback(callback)
    }

    public func getRecentActionLogs() -> [String] {
        engine.operationLogger.getRecentActionLogs()
    }

    // ── 未接入（保持 todo） ──

    public func getBoardContentFitMode() -> Int { Self.todo("getBoardContentFitMode"); return 0 }
    public func setBoardContentFitMode(_ mode: Int) { Self.todo("setBoardContentFitMode") }
    public func getBoardElementList(_ boardId: String? = nil) -> [Any] { Self.todo("getBoardElementList"); return [] }
    public func addVideoFile(_ url: String, _ title: String? = nil) -> String {
        engine.addVideoFile(url, title: title)
    }
    public func getFileScale(_ fileId: String) -> Int { Self.todo("getFileScale"); return 100 }
    public func setFileScale(_ fileId: String, _ scale: Int) { Self.todo("setFileScale") }
    public func applyFileTranscode(_ options: Any) { Self.todo("applyFileTranscode") }
    public func getPPTRemarks(_ fileId: String) -> [Any] { Self.todo("getPPTRemarks"); return [] }
    public func setEnableStoreLastPPTFile(_ enable: Bool) { Self.todo("setEnableStoreLastPPTFile") }
    public func setToolTypeTitle(_ toolType: Int, _ title: String) { Self.todo("setToolTypeTitle") }
    public func setPerfectFreehandConfig(_ config: Any) { Self.todo("setPerfectFreehandConfig") }
    public func getPerfectFreehandConfig() -> Any? { Self.todo("getPerfectFreehandConfig"); return nil }
    public func setHandwritingEnable(_ enable: Bool) { Self.todo("setHandwritingEnable") }
    public func isHandwritingEnable() -> Bool { Self.todo("isHandwritingEnable"); return false }
    public func addElement(_ type: Int, _ url: String, _ options: Any? = nil) -> String {
        let isAudio = type == DrawsKitConstants.ElementType.DRAWSKIT_ELEMENT_AUDIO
            || type == DrawsKitConstants.ElementType.DRAWSKIT_ELEMENT_GLOBAL_AUDIO
        guard isAudio else { Self.todo("addElement"); return "" }
        let opts = options as? [String: Any]
        let id = (opts?["id"] as? String)?.isEmpty == false
            ? (opts?["id"] as? String)!
            : "audio-\(Int(Date().timeIntervalSince1970 * 1000))"
        engine.addAudioElement(
            id: id,
            url: url,
            x: opts?["x"] as? Double ?? 0,
            y: opts?["y"] as? Double ?? 0,
            width: opts?["width"] as? Double ?? MediaDefaults.defaultAudioWidth,
            height: opts?["height"] as? Double ?? MediaDefaults.defaultAudioHeight,
            global: type == DrawsKitConstants.ElementType.DRAWSKIT_ELEMENT_GLOBAL_AUDIO
        )
        return id
    }
    public func addImageElement(_ url: String, _ options: Any? = nil) -> String { Self.todo("addImageElement"); return "" }
    public func removeElement(_ id: String) { Self.todo("removeElement") }
    public func updateElementById(_ id: String, _ data: Any) { Self.todo("updateElementById") }
    public func getElementById(_ id: String) -> Any? { Self.todo("getElementById"); return nil }
    public func lockElements(_ ids: String, _ locked: Bool) { Self.todo("lockElements") }
    public func setElementsDisplay(_ ids: String, _ visible: Bool) { Self.todo("setElementsDisplay") }
    public func bringImageElementToFront(_ id: String) { Self.todo("bringImageElementToFront") }
    public func sendImageElementToBack(_ id: String) { Self.todo("sendImageElementToBack") }
    public func enableShowGraffiti(_ enable: Bool) { Self.todo("enableShowGraffiti") }
    public func setBackgroundColor(_ color: String) { Self.todo("setBackgroundColor") }
    public func getBackgroundColor() -> String { Self.todo("getBackgroundColor"); return "#ffffff" }
    public func setBackgroundImage(_ url: String, _ mode: Int = 0) { Self.todo("setBackgroundImage") }
    public func getBackgroundImage() -> String { Self.todo("getBackgroundImage"); return "" }
    public func setBackgroundImageAngle(_ angle: Int) { Self.todo("setBackgroundImageAngle") }
    public func setGlobalBackgroundColor(_ color: String) { Self.todo("setGlobalBackgroundColor") }
    public func getGlobalBackgroundColor() -> String { Self.todo("getGlobalBackgroundColor"); return "#ffffff" }
    public func setGlobalBackgroundPic(_ pic: Any) { Self.todo("setGlobalBackgroundPic") }
    public func getGlobalBackgroundPic() -> Any? { Self.todo("getGlobalBackgroundPic"); return nil }
    public func setScaleAnchor(_ anchor: Any) { Self.todo("setScaleAnchor") }
    public func setScaleToolRatio(_ ratio: Int) { Self.todo("setScaleToolRatio") }
    public func setScrollBarVisible(_ visible: Bool) { Self.todo("setScrollBarVisible") }
    public func setCursorIcon(_ toolType: Int, _ icon: Any?) { engine.setCursorIcon(toolType, icon) }
    public func setCursorPosition(_ position: Any) { Self.todo("setCursorPosition") }
    public func setZoomCursorIcon(_ icon: Any?) { engine.setZoomCursorIcon(icon) }
    public func setRemoteCursorVisible(_ config: Any) { Self.todo("setRemoteCursorVisible") }
    public func setSystemCursorEnable(_ enable: Bool) { engine.setSystemCursorEnable(enable) }
    public func setMouseToolBehavior(_ behavior: Any) { Self.todo("setMouseToolBehavior") }
    public func enableMultiTouch(_ enable: Bool) { Self.todo("enableMultiTouch") }
    public func setPenToolWheelRollEnable(_ enable: Bool) { Self.todo("setPenToolWheelRollEnable") }
    public func playVideo(_ fileId: String) { engine.playMedia(MediaDefaults.fileKey(fileId)) }
    public func pauseVideo(_ fileId: String) { engine.pauseMedia(MediaDefaults.fileKey(fileId)) }
    public func seekVideo(_ fileId: String, _ time: Int) { engine.seekMedia(MediaDefaults.fileKey(fileId), time: time) }
    public func muteVideo(_ fileId: String, _ mute: Bool) { engine.muteMedia(MediaDefaults.fileKey(fileId), muted: mute) }
    public func playAudio(_ elementId: String) { engine.playMedia(MediaDefaults.elementKey(elementId)) }
    public func pauseAudio(_ elementId: String) { engine.pauseMedia(MediaDefaults.elementKey(elementId)) }
    public func seekAudio(_ elementId: String, _ time: Int) { engine.seekMedia(MediaDefaults.elementKey(elementId), time: time) }
    public func muteAudio(_ elementId: String, _ mute: Bool) { engine.muteMedia(MediaDefaults.elementKey(elementId), muted: mute) }
    public func getAudioVolume(_ elementId: String) -> Int { engine.getMediaVolume(MediaDefaults.elementKey(elementId)) }
    public func setAudioVolume(_ elementId: String, _ volume: Int) { engine.setMediaVolume(MediaDefaults.elementKey(elementId), volume: volume) }
    public func enableAudioControl(_ enable: Bool) { engine.setEnableAudioControl(enable) }
    public func showVideoControl(_ show: Bool) { engine.setShowVideoControl(show) }
    public func playH5PPTVideo(_ fileId: String, _ mediaId: String) {
        engine.playMedia(MediaDefaults.slotKey(fileId: fileId, mediaId: mediaId))
    }
    public func pauseH5PPTVideo(_ fileId: String, _ mediaId: String) {
        engine.pauseMedia(MediaDefaults.slotKey(fileId: fileId, mediaId: mediaId))
    }
    public func playH5PPTAudio(_ fileId: String, _ mediaId: String) {
        engine.playMedia(MediaDefaults.slotKey(fileId: fileId, mediaId: mediaId))
    }
    public func pauseH5PPTAudio(_ fileId: String, _ mediaId: String) {
        engine.pauseMedia(MediaDefaults.slotKey(fileId: fileId, mediaId: mediaId))
    }
    public func setShowPPTAudioControls(_ show: Bool) { engine.setShowPPTAudioControls(show) }
    public func soundMuteForPPT(_ mute: Bool) { engine.soundMuteForPPT(mute) }
    public func setSpeakerDevice(_ deviceId: String) { /* host OS I/O */ }
    public func setSpeakerDeviceForPPT(_ deviceId: String) { /* host OS I/O */ }
    public func setSyncAudioStatusEnable(_ enable: Bool) { engine.setSyncAudioStatusEnable(enable) }
    public func setSyncVideoStatusEnable(_ enable: Bool) { engine.setSyncVideoStatusEnable(enable) }
    public func startSyncVideoStatus() { engine.startSyncVideoStatus() }
    public func stopSyncVideoStatus() { engine.stopSyncVideoStatus() }
    public func setVideoFileDrawEnable(_ enable: Bool) { engine.setVideoFileDrawEnable(enable) }
    public func enablePermissionChecker(_ enable: Bool) { Self.todo("enablePermissionChecker") }
    public func disablePermissionChecker() { Self.todo("disablePermissionChecker") }
    public func resetPermissionChecker() { Self.todo("resetPermissionChecker") }
    public func setAccessibleUsers(_ users: String) { Self.todo("setAccessibleUsers") }
    public func setOwnerNickNameVisible(_ visible: Bool) { Self.todo("setOwnerNickNameVisible") }
    public func disableDrawActionEventResponding() { Self.todo("disableDrawActionEventResponding") }
    public func disablePointerEventResponding() { Self.todo("disablePointerEventResponding") }
    public func setClassGroup(_ groups: Any) { Self.todo("setClassGroup") }
    public func setClassGroupEnable(_ enable: Bool) { Self.todo("setClassGroupEnable") }
    public func getClassGroupEnable() -> Bool { Self.todo("getClassGroupEnable"); return false }
    public func setClassGroupTitle(_ groupId: String, _ title: String) { Self.todo("setClassGroupTitle") }
    public func addUserToClassGroup(_ groupId: String, _ userId: String) { Self.todo("addUserToClassGroup") }
    public func removeUserInClassGroup(_ groupId: String, _ userId: String) { Self.todo("removeUserInClassGroup") }
    public func addBoardToClassGroup(_ groupId: String, _ boardId: String) { Self.todo("addBoardToClassGroup") }
    public func removeBoardInClassGroup(_ groupId: String, _ boardId: String) { Self.todo("removeBoardInClassGroup") }
    public func removeClassGroup(_ groupId: String) { Self.todo("removeClassGroup") }
    public func resetClassGroup() { Self.todo("resetClassGroup") }
    public func gotoClassGroupBoard(_ groupId: String, _ boardId: String) { Self.todo("gotoClassGroupBoard") }
    public func getAllClassGroupIds() -> [String] { Self.todo("getAllClassGroupIds"); return [] }
    public func getClassGroupIdByUserId(_ userId: String) -> String { Self.todo("getClassGroupIdByUserId"); return "" }
    public func getClassGroupInfoByGroupId(_ groupId: String) -> Any? { Self.todo("getClassGroupInfoByGroupId"); return nil }
    public func snapshot(_ options: Any? = nil) { Self.todo("snapshot") }
    public func addSnapshotMark(_ mark: Any) { Self.todo("addSnapshotMark") }
    public func setProxyServer(_ config: String) { Self.todo("setProxyServer") }
    public func addBackupDomain(_ domain: String, _ backup: String, _ priority: Int = 0) { Self.todo("addBackupDomain") }
    public func removeBackupDomain(_ domain: String, _ backup: String) { Self.todo("removeBackupDomain") }
    public func setImageTimeout(_ timeout: Int) { Self.todo("setImageTimeout") }
    public func setDownGradeEnable(_ enable: Bool) { Self.todo("setDownGradeEnable") }
    public func setUserInfo(_ info: Any) { Self.todo("setUserInfo") }
    public func useMathTool(_ type: Int) { Self.todo("useMathTool") }
    public func setMathGraphType(_ type: Int) { Self.todo("setMathGraphType") }

    private static func todo(_ method: String) {
        print("[DrawsKit] TODO: \(method)")
    }
}
