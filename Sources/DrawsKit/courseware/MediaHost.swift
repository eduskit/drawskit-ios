import AVFoundation
import CoreMedia
import UIKit

final class MediaHost {
    private let boardRoot: UIView
    private weak var drawsKitView: DrawsKitView?
    private let layerHost = UIView()
    private var players: [String: Player] = [:]
    private var showVideoControl = false
    private var videoFileDrawEnable = false
    private var showAudioControl = false
    private var pptAudioControls = false
    private var pptMuted = false
    var onVideoStatus: (([String: Any]) -> Void)?
    var onAudioStatus: (([String: Any]) -> Void)?

    init(boardRoot: UIView, drawsKitView: DrawsKitView) {
        self.boardRoot = boardRoot
        self.drawsKitView = drawsKitView
        layerHost.isUserInteractionEnabled = false
        if let index = boardRoot.subviews.firstIndex(of: drawsKitView) {
            boardRoot.insertSubview(layerHost, at: index)
        } else {
            boardRoot.insertSubview(layerHost, belowSubview: drawsKitView)
        }
        layerHost.frame = boardRoot.bounds
        layerHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    func sync(_ frame: [String: Any]?) {
        let wanted = collectWanted(frame)
        let keep = Set(wanted.map(\.key))
        for (key, player) in players where !keep.contains(key) && !player.global {
            player.release()
            players.removeValue(forKey: key)
        }
        for item in wanted {
            if players[item.key]?.url != item.url {
                players[item.key]?.release()
                players[item.key] = mount(item)
            }
            layout(players[item.key], rect: item.rect)
        }
        applyPointerPolicy()
    }

    func play(_ key: String) { players[key]?.play() }
    func pause(_ key: String) { players[key]?.pause() }
    func seek(_ key: String, time: Int) { players[key]?.seek(seconds: Double(time)) }
    func mute(_ key: String, muted: Bool) { players[key]?.mute(muted) }
    func setVolume(_ key: String, volume: Int) { players[key]?.setVolume(volume) }
    func getVolume(_ key: String) -> Int { players[key]?.volume ?? MediaDefaults.defaultAudioVolume }
    func snapshot() -> [[String: Any]] { players.values.map { $0.snapshot() } }
    func setShowVideoControl(_ show: Bool) { showVideoControl = show; applyPointerPolicy() }
    func setEnableAudioControl(_ enable: Bool) { showAudioControl = enable; applyPointerPolicy() }
    func setShowPPTAudioControls(_ show: Bool) { pptAudioControls = show; applyPointerPolicy() }
    func setVideoFileDrawEnable(_ enable: Bool) { videoFileDrawEnable = enable; applyPointerPolicy() }
    func soundMuteForPPT(_ mute: Bool) {
        pptMuted = mute
        players.values.filter { $0.mediaId != nil }.forEach { $0.mute(mute) }
    }

    func destroy() {
        players.values.forEach { $0.release() }
        players.removeAll()
        layerHost.removeFromSuperview()
    }

    private func mount(_ item: Wanted) -> Player {
        let player = AVPlayer(url: URL(string: item.url) ?? URL(fileURLWithPath: item.url))
        let view = PlayerView()
        view.playerLayer.player = player
        layerHost.addSubview(view)
        if pptMuted && item.mediaId != nil { player.isMuted = true }
        return Player(item: item, player: player, view: view)
    }

    private func layout(_ player: Player?, rect: ViewportCoords.ScreenRect?) {
        guard let player, let view = player.view else { return }
        guard let rect else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        let origin = ViewportCoords.screenToViewPixels(view: drawsKitView, screenX: rect.x, screenY: rect.y)
        let corner = ViewportCoords.screenToViewPixels(
            view: drawsKitView,
            screenX: rect.x + rect.width,
            screenY: rect.y + rect.height
        )
        view.frame = CGRect(x: origin.0, y: origin.1, width: corner.0 - origin.0, height: corner.1 - origin.1)
    }

    private func applyPointerPolicy() {
        for player in players.values {
            let interactive = player.kind == MediaDefaults.kindVideo
                ? showVideoControl && !videoFileDrawEnable
                : showAudioControl || pptAudioControls
            player.view?.isUserInteractionEnabled = interactive
        }
    }

    private func collectWanted(_ frame: [String: Any]?) -> [Wanted] {
        guard let frame else { return [] }
        var wanted: [Wanted] = []
        if let layer = CoursewareRead.getCoursewareLayer(frame),
           layer.string("render_mode") == EngineDefaults.coursewareRenderModeStaticImage {
            let fileId = layer.string("resource_id")
            let media = layer.dict("page")?.array("media") ?? []
            for item in media {
                guard let slot = item as? [String: Any] else { continue }
                let mediaId = slot.string("media_id")
                let url = slot.string("url")
                guard !mediaId.isEmpty, !url.isEmpty else { continue }
                let key = mediaId == fileId ? MediaDefaults.fileKey(fileId) : MediaDefaults.slotKey(fileId: fileId, mediaId: mediaId)
                wanted.append(Wanted(
                    key: key,
                    kind: slot.string("type", default: MediaDefaults.kindVideo),
                    url: url,
                    rect: ViewportCoords.mediaSlotToScreen(frame: frame, slot: slot, layer: layer),
                    mediaId: mediaId,
                    global: false
                ))
            }
        }
        let layers = frame["layers"] as? [Any] ?? []
        for item in layers {
            guard let entry = item as? [String: Any],
                  entry.string("type") == RenderDefaults.renderLayerShapes else { continue }
            let shapes = entry.array("shapes") ?? []
            for shapeItem in shapes {
                guard let shape = shapeItem as? [String: Any],
                      shape.string("type") == MediaDefaults.shapeTypeAudio else { continue }
                let id = shape.string("id")
                let url = shape.string("url")
                let bounds = shape.dict("bounds")
                let global = shape["global"] as? Bool ?? false
                wanted.append(Wanted(
                    key: MediaDefaults.elementKey(id),
                    kind: MediaDefaults.kindAudio,
                    url: url,
                    rect: global || bounds == nil
                        ? nil
                        : ViewportCoords.sceneRectToScreen(
                            frame: frame,
                            x: Float(bounds?.double("x") ?? 0),
                            y: Float(bounds?.double("y") ?? 0),
                            width: Float(bounds?.double("width") ?? 0),
                            height: Float(bounds?.double("height") ?? 0)
                        ),
                    mediaId: id,
                    global: global
                ))
            }
        }
        return wanted
    }

    private struct Wanted {
        let key: String
        let kind: String
        let url: String
        let rect: ViewportCoords.ScreenRect?
        let mediaId: String?
        let global: Bool
    }

    private final class Player {
        let key: String
        let kind: String
        let url: String
        let mediaId: String?
        let global: Bool
        let player: AVPlayer
        let view: PlayerView?
        var volume: Int = MediaDefaults.defaultAudioVolume

        init(item: Wanted, player: AVPlayer, view: PlayerView) {
            self.key = item.key
            self.kind = item.kind
            self.url = item.url
            self.mediaId = item.mediaId
            self.global = item.global
            self.player = player
            self.view = view
        }

        func play() { player.play() }
        func pause() { player.pause() }
        func seek(seconds: Double) {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        func mute(_ muted: Bool) { player.isMuted = muted }
        func setVolume(_ volume: Int) {
            self.volume = volume
            player.volume = Float(volume) / Float(MediaDefaults.defaultAudioVolume)
        }
        func snapshot() -> [String: Any] {
            let playing = player.rate > 0
            let status = kind == MediaDefaults.kindVideo
                ? (playing
                    ? DrawsKitConstants.DrawsKitVideoStatus.DRAWSKIT_VIDEO_STATUS_PLAYING
                    : DrawsKitConstants.DrawsKitVideoStatus.DRAWSKIT_VIDEO_STATUS_PAUSED)
                : (playing
                    ? DrawsKitConstants.DrawsKitAudioStatus.DRAWSKIT_AUDIO_STATUS_PLAYING
                    : DrawsKitConstants.DrawsKitAudioStatus.DRAWSKIT_AUDIO_STATUS_PAUSED)
            return [
                "key": key,
                "mediaId": mediaId as Any,
                "kind": kind,
                "status": status,
                "position": CMTimeGetSeconds(player.currentTime()),
                "muted": player.isMuted,
                "volume": volume,
            ]
        }
        func release() {
            player.pause()
            view?.removeFromSuperview()
        }
    }

    private final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
