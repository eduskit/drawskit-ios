import Foundation
import os.log

public typealias LogLineCallback = (String) -> Void
public typealias ActionEventSink = (StructuredActionEvent) -> Void

public struct StructuredActionEvent {
    public static let schemaVersionValue = 1
    public static let sourceSdk = "sdk"
    public static let sourceCore = "core"

    public let schemaVersion: Int
    public let eventId: String
    public let sessionId: String
    public let clientSeq: Int64
    public let occurredAt: Int64
    public let source: String
    public let action: String
    public let phase: String
    public let level: Int
    public let result: String?
    public let boardId: String?
    public let detail: [String: Any]

    public init(
        schemaVersion: Int = StructuredActionEvent.schemaVersionValue,
        eventId: String,
        sessionId: String,
        clientSeq: Int64,
        occurredAt: Int64,
        source: String,
        action: String,
        phase: String,
        level: Int,
        result: String? = nil,
        boardId: String? = nil,
        detail: [String: Any] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.eventId = eventId
        self.sessionId = sessionId
        self.clientSeq = clientSeq
        self.occurredAt = occurredAt
        self.source = source
        self.action = action
        self.phase = phase
        self.level = level
        self.result = result
        self.boardId = boardId
        self.detail = detail
    }

    func toDictionary() -> [String: Any] {
        var json: [String: Any] = [
            "schemaVersion": schemaVersion,
            "eventId": eventId,
            "sessionId": sessionId,
            "clientSeq": clientSeq,
            "occurredAt": occurredAt,
            "source": source,
            "action": action,
            "phase": phase,
            "level": level,
        ]
        if let result { json["result"] = result }
        if let boardId { json["boardId"] = boardId }
        if !detail.isEmpty { json["detail"] = detail }
        return json
    }

    static func fromDictionary(_ json: [String: Any]) -> StructuredActionEvent {
        let detail = json["detail"] as? [String: Any] ?? [:]
        return StructuredActionEvent(
            schemaVersion: (json["schemaVersion"] as? NSNumber)?.intValue
                ?? StructuredActionEvent.schemaVersionValue,
            eventId: (json["eventId"] as? String) ?? (json["event_id"] as? String) ?? "",
            sessionId: (json["sessionId"] as? String) ?? (json["session_id"] as? String) ?? "",
            clientSeq: (json["clientSeq"] as? NSNumber)?.int64Value
                ?? (json["client_seq"] as? NSNumber)?.int64Value ?? 0,
            occurredAt: (json["occurredAt"] as? NSNumber)?.int64Value
                ?? (json["occurred_at"] as? NSNumber)?.int64Value ?? 0,
            source: (json["source"] as? String) ?? StructuredActionEvent.sourceSdk,
            action: (json["action"] as? String) ?? "",
            phase: (json["phase"] as? String) ?? "ok",
            level: (json["level"] as? NSNumber)?.intValue ?? 3,
            result: json["result"] as? String,
            boardId: (json["boardId"] as? String) ?? (json["board_id"] as? String),
            detail: detail
        )
    }
}

@_silgen_name("wb_telemetry_create")
private func wb_telemetry_create(
    _ sid: UnsafePointer<CChar>?,
    _ boardId: UnsafePointer<CChar>?,
    _ userId: UnsafePointer<CChar>?,
    _ clientId: UnsafePointer<CChar>?,
    _ capacity: Int32
) -> OpaquePointer?

@_silgen_name("wb_telemetry_destroy")
private func wb_telemetry_destroy(_ handle: OpaquePointer?)

@_silgen_name("wb_telemetry_set_level")
private func wb_telemetry_set_level(_ handle: OpaquePointer?, _ level: UInt32)

@_silgen_name("wb_telemetry_clear")
private func wb_telemetry_clear(_ handle: OpaquePointer?)

@_silgen_name("wb_telemetry_recent_json")
private func wb_telemetry_recent_json(_ handle: OpaquePointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_telemetry_ingest_line_json")
private func wb_telemetry_ingest_line_json(
    _ handle: OpaquePointer?,
    _ line: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_telemetry_action_json")
private func wb_telemetry_action_json(
    _ handle: OpaquePointer?,
    _ action: UnsafePointer<CChar>?,
    _ phase: UnsafePointer<CChar>?,
    _ level: Int32,
    _ result: UnsafePointer<CChar>?,
    _ detailJson: UnsafePointer<CChar>?,
    _ nowMs: UInt64
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_engine_free_string")
private func wb_telemetry_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

/// Thin adapter over `drawskit-sdk-telemetry` (`wb_telemetry_*`).
public final class OperationLogger {
    public static let defaultCapacity = 200

    private var handle: OpaquePointer?
    private var userCallback: LogLineCallback?
    private var actionSink: ActionEventSink?
    private let lock = NSLock()
    private let osLog = OSLog(subsystem: "io.drawskit", category: "Action")

    public init(
        sid: String,
        boardId: String,
        userId: String,
        clientId: String,
        capacity: Int = OperationLogger.defaultCapacity
    ) {
        handle = sid.withCString { s in
            boardId.withCString { b in
                userId.withCString { u in
                    clientId.withCString { c in
                        wb_telemetry_create(s, b, u, c, Int32(capacity))
                    }
                }
            }
        }
        precondition(
            handle != nil,
            "OperationLogger unavailable (missing wb_telemetry_* in libwhiteboard_ffi)"
        )
    }

    deinit {
        if let handle {
            wb_telemetry_destroy(handle)
        }
    }

    public static func createSessionId() -> String {
        UUID().uuidString
    }

    public func setLevel(_ level: Int) {
        guard let handle else { return }
        wb_telemetry_set_level(handle, UInt32(max(0, min(5, level))))
    }

    public func setLogCallback(_ callback: LogLineCallback?) {
        lock.lock()
        userCallback = callback
        lock.unlock()
    }

    public func setActionSink(_ sink: ActionEventSink?) {
        lock.lock()
        actionSink = sink
        lock.unlock()
    }

    public func getRecentActionLogs() -> [String] {
        guard let handle, let out = wb_telemetry_recent_json(handle) else { return [] }
        defer { wb_telemetry_free_string(out) }
        let s = String(cString: out)
        guard let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }

    public func clear() {
        guard let handle else { return }
        wb_telemetry_clear(handle)
    }

    public func ingestLine(_ line: String) {
        emitLine(line, printConsole: false, level: 3)
        guard let handle else { return }
        let raw: String? = line.withCString { cstr in
            guard let out = wb_telemetry_ingest_line_json(handle, cstr) else { return nil }
            defer { wb_telemetry_free_string(out) }
            return String(cString: out)
        }
        guard let raw, raw != "null",
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        emitAction(StructuredActionEvent.fromDictionary(obj))
    }

    public func action(
        _ action: String,
        phase: String,
        result: String? = nil,
        level: Int = 3,
        detail: [String: Any] = [:]
    ) {
        guard let handle else { return }
        let detailJson: String? = {
            guard !detail.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: detail),
                  let s = String(data: data, encoding: .utf8)
            else { return nil }
            return s
        }()
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let raw: String? = action.withCString { a in
            phase.withCString { p in
                if let result {
                    return result.withCString { r in
                        if let detailJson {
                            return detailJson.withCString { d in
                                guard let out = wb_telemetry_action_json(
                                    handle, a, p, Int32(level), r, d, nowMs
                                ) else { return nil }
                                defer { wb_telemetry_free_string(out) }
                                return String(cString: out)
                            }
                        }
                        guard let out = wb_telemetry_action_json(
                            handle, a, p, Int32(level), r, nil, nowMs
                        ) else { return nil }
                        defer { wb_telemetry_free_string(out) }
                        return String(cString: out)
                    }
                }
                if let detailJson {
                    return detailJson.withCString { d in
                        guard let out = wb_telemetry_action_json(
                            handle, a, p, Int32(level), nil, d, nowMs
                        ) else { return nil }
                        defer { wb_telemetry_free_string(out) }
                        return String(cString: out)
                    }
                }
                guard let out = wb_telemetry_action_json(
                    handle, a, p, Int32(level), nil, nil, nowMs
                ) else { return nil }
                defer { wb_telemetry_free_string(out) }
                return String(cString: out)
            }
        }
        guard let raw,
              let data = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["skipped"] as? Bool != true,
              let line = payload["line"] as? String,
              let eventObj = payload["event"] as? [String: Any]
        else { return }
        let event = StructuredActionEvent.fromDictionary(eventObj)
        emitLine(line, printConsole: true, level: event.level)
        emitAction(event)
    }

    private func emitAction(_ event: StructuredActionEvent) {
        lock.lock()
        let sink = actionSink
        lock.unlock()
        sink?(event)
    }

    private func emitLine(_ line: String, printConsole: Bool, level: Int) {
        if printConsole {
            let type: OSLogType
            switch level {
            case ...1: type = .error
            case 2: type = .default
            case 4...: type = .debug
            default: type = .info
            }
            os_log("%{public}@", log: osLog, type: type, line)
        }
        lock.lock()
        let callback = userCallback
        lock.unlock()
        callback?(line)
    }
}
