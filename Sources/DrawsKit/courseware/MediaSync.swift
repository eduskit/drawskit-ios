import Foundation

final class MediaSync {
    private var videoEnabled = false
    private var audioEnabled = false
    private var videoStreaming = false
    private var transport: (([String: Any]) -> Void)?
    private var snapshot: () -> [[String: Any]] = { [] }
    private let clockQueue = DispatchQueue(label: "io.drawskit.media-sync", qos: .utility)
    private var timer: DispatchSourceTimer?

    func setTransport(_ send: (([String: Any]) -> Void)?) {
        clockQueue.async { self.transport = send }
    }

    func setSnapshot(_ snapshot: @escaping () -> [[String: Any]]) {
        clockQueue.async { self.snapshot = snapshot }
    }

    func setSyncVideoStatusEnable(_ enable: Bool) {
        clockQueue.async {
            self.videoEnabled = enable
            if !enable { self.stopSyncVideoStatusOnClock() }
        }
    }

    func setSyncAudioStatusEnable(_ enable: Bool) {
        clockQueue.async { self.audioEnabled = enable }
    }

    func startSyncVideoStatus() {
        clockQueue.async {
            self.videoStreaming = true
            guard self.timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: self.clockQueue)
            source.schedule(deadline: .now(), repeating: MediaDefaults.syncIntervalMs)
            source.setEventHandler { [weak self] in self?.broadcastState() }
            self.timer = source
            source.resume()
        }
    }

    func stopSyncVideoStatus() {
        clockQueue.async { self.stopSyncVideoStatusOnClock() }
    }

    func onLocalStatus(_ payload: [String: Any]) {
        clockQueue.async {
            let kind = payload["kind"] as? String ?? ""
            let video = kind == MediaDefaults.kindVideo
            if video && !self.videoEnabled { return }
            if !video && !self.audioEnabled { return }
            let status = payload["status"] as? Int ?? 0
            self.send([
                "type": MediaDefaults.syncMessageType,
                "key": payload["key"] as? String ?? "",
                "action": self.actionFromStatus(status, video: video),
                "position": payload["position"] as? Double ?? 0,
                "at": Date().timeIntervalSince1970 * 1000,
                "kind": kind,
                "status": status,
            ])
        }
    }

    func parseInbound(_ payload: Any) -> [String: Any]? {
        guard let record = payload as? [String: Any],
              record["type"] as? String == MediaDefaults.syncMessageType,
              let key = record["key"] as? String, !key.isEmpty,
              let action = record["action"] as? String, !action.isEmpty
        else { return nil }
        return record
    }

    func destroy() {
        clockQueue.async {
            self.stopSyncVideoStatusOnClock()
            self.transport = nil
        }
    }

    private func stopSyncVideoStatusOnClock() {
        videoStreaming = false
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func broadcastState() {
        guard videoStreaming, videoEnabled else { return }
        for item in snapshot() where (item["kind"] as? String) == MediaDefaults.kindVideo {
            send([
                "type": MediaDefaults.syncMessageType,
                "key": item["key"] as? String ?? "",
                "action": MediaDefaults.syncActionState,
                "position": item["position"] as? Double ?? 0,
                "at": Date().timeIntervalSince1970 * 1000,
                "kind": item["kind"] as? String ?? "",
                "status": item["status"] as? Int ?? 0,
            ])
        }
    }

    private func send(_ message: [String: Any]) {
        transport?(message)
    }

    private func actionFromStatus(_ status: Int, video: Bool) -> String {
        let playing = video
            ? DrawsKitConstants.DrawsKitVideoStatus.DRAWSKIT_VIDEO_STATUS_PLAYING
            : DrawsKitConstants.DrawsKitAudioStatus.DRAWSKIT_AUDIO_STATUS_PLAYING
        let paused = video
            ? DrawsKitConstants.DrawsKitVideoStatus.DRAWSKIT_VIDEO_STATUS_PAUSED
            : DrawsKitConstants.DrawsKitAudioStatus.DRAWSKIT_AUDIO_STATUS_PAUSED
        let ended = video
            ? DrawsKitConstants.DrawsKitVideoStatus.DRAWSKIT_VIDEO_STATUS_ENDED
            : DrawsKitConstants.DrawsKitAudioStatus.DRAWSKIT_AUDIO_STATUS_ENDED
        if status == playing { return MediaDefaults.syncActionPlay }
        if status == paused || status == ended { return MediaDefaults.syncActionPause }
        return MediaDefaults.syncActionSeek
    }
}
