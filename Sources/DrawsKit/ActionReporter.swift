import Foundation

internal struct ActionReporterConfig {
    var enabled: Bool
    var batchSize: Int
    var flushIntervalMs: Int64
    let sdkVersion: String
    let engineVersion: String
    let platform: String

    init(
        enabled: Bool,
        batchSize: Int = ActionReporter.defaultBatchSize,
        flushIntervalMs: Int64 = ActionReporter.defaultFlushIntervalMs,
        sdkVersion: String,
        engineVersion: String,
        platform: String = ActionReporter.platformIOS
    ) {
        self.enabled = enabled
        self.batchSize = batchSize
        self.flushIntervalMs = flushIntervalMs
        self.sdkVersion = sdkVersion
        self.engineVersion = engineVersion
        self.platform = platform
    }
}

@_silgen_name("wb_action_reporter_create")
private func wb_action_reporter_create() -> OpaquePointer?

@_silgen_name("wb_action_reporter_destroy")
private func wb_action_reporter_destroy(_ handle: OpaquePointer?)

@_silgen_name("wb_action_reporter_handle_json")
private func wb_action_reporter_handle_json(
    _ handle: OpaquePointer?,
    _ eventJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_engine_free_string")
private func wb_action_reporter_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

/// Thin executor over `drawskit-sdk-sync` ActionReporterRuntime (FFI).
internal final class ActionReporter {
    static let defaultBatchSize = 50
    static let defaultFlushIntervalMs: Int64 = 5_000
    static let platformIOS = "ios"

    private let roomApi: RoomApiClient
    private var handle: OpaquePointer?
    private var config: ActionReporterConfig
    private var flushWorkItem: DispatchWorkItem?
    private var flushPosted = false
    private var destroyed = false
    private let actorQueue = DispatchQueue(label: "io.drawskit.ActionReporter.actor", qos: .utility)
    private let ioQueue = DispatchQueue(label: "io.drawskit.ActionReporter.network", qos: .utility)

    init(roomApi: RoomApiClient, config: ActionReporterConfig) {
        self.roomApi = roomApi
        self.config = config
        guard let h = wb_action_reporter_create() else {
            fatalError("ActionReporter unavailable (missing wb_action_reporter_* in libwhiteboard_ffi)")
        }
        self.handle = h
        dispatch([
            "type": "configure",
            "config": [
                "enabled": config.enabled,
                "batch_size": config.batchSize,
                "flush_interval_ms": config.flushIntervalMs,
                "sdk_version": config.sdkVersion,
                "engine_version": config.engineVersion,
                "platform": config.platform,
            ] as [String: Any],
        ])
    }

    func configure(enabled: Bool? = nil, batchSize: Int? = nil, flushIntervalMs: Int64? = nil) {
        if let enabled { config.enabled = enabled }
        if let batchSize { config.batchSize = batchSize }
        if let flushIntervalMs { config.flushIntervalMs = flushIntervalMs }
        dispatch([
            "type": "configure",
            "config": [
                "enabled": config.enabled,
                "batch_size": config.batchSize,
                "flush_interval_ms": config.flushIntervalMs,
                "sdk_version": config.sdkVersion,
                "engine_version": config.engineVersion,
                "platform": config.platform,
            ] as [String: Any],
        ])
    }

    func enqueue(_ event: StructuredActionEvent) {
        dispatch(["type": "enqueue", "event": event.toDictionary()])
    }

    func flush() {
        dispatch(["type": "timer"])
    }

    func destroy() {
        actorQueue.async { [weak self] in
            guard let self, !self.destroyed else { return }
            self.dispatchOnActor(["type": "destroy"])
            self.destroyed = true
            if let handle = self.handle {
                wb_action_reporter_destroy(handle)
            }
            self.handle = nil
            self.flushWorkItem?.cancel()
            self.flushWorkItem = nil
        }
    }

    deinit {
        flushWorkItem?.cancel()
        if let handle { wb_action_reporter_destroy(handle) }
    }

    private func dispatch(_ event: [String: Any]) {
        actorQueue.async { [weak self] in self?.dispatchOnActor(event) }
    }

    private func dispatchOnActor(_ event: [String: Any]) {
        if destroyed { return }
        guard let handle,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8)
        else { return }
        let cmds: [[String: Any]] = json.withCString { cstr in
            guard let out = wb_action_reporter_handle_json(handle, cstr) else { return [] }
            defer { wb_action_reporter_free_string(out) }
            let s = String(cString: out)
            guard let data = s.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [Any]
            else { return [] }
            return payload.compactMap { $0 as? [String: Any] }
        }
        for cmd in cmds {
            switch cmd["type"] as? String {
            case "cancel_flush":
                flushPosted = false
                flushWorkItem?.cancel()
                flushWorkItem = nil
            case "schedule_flush":
                let delay = (cmd["delay_ms"] as? NSNumber)?.int64Value ?? 0
                schedule(delayMs: delay)
            case "http_report_actions":
                let events = (cmd["events"] as? [[String: Any]]) ?? []
                ioQueue.async { [weak self] in
                    guard let self else { return }
                    let ok: Bool
                    do {
                        try self.roomApi.reportActions(events: events)
                        ok = true
                    } catch {
                        ok = false
                    }
                    self.dispatch(["type": "flush_result", "ok": ok])
                }
            default:
                break
            }
        }
    }

    private func schedule(delayMs: Int64) {
        if destroyed || flushPosted { return }
        flushPosted = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flushPosted = false
            self.flushWorkItem = nil
            self.dispatchOnActor(["type": "timer"])
        }
        flushWorkItem = work
        actorQueue.asyncAfter(
            deadline: .now() + .milliseconds(Int(max(0, delayMs))),
            execute: work
        )
    }
}
