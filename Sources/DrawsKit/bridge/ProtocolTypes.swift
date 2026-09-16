// Generated from protocol/whiteboard-protocol.json. Do not edit.
import Foundation

struct BaseRevisionPayload {
    let elementId: String
    let revision: Int64
    let lastOpId: String?
}

struct SyncEnvelopePayload {
    let schemaVersion: Int
    let seq: Int64
    let serverSeq: Int64?
    let baseRevisions: [BaseRevisionPayload]
    let boardId: String
    let op: [String: Any]
    let userId: String
    let clientId: String
    let timestamp: Int64
    let opId: String
    let raw: [String: Any]

    static func parse(_ data: Any) -> SyncEnvelopePayload? {
        let raw: [String: Any]?
        if let text = data as? String,
           let bytes = text.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: bytes) {
            raw = value as? [String: Any]
        } else {
            raw = data as? [String: Any]
        }
        guard let raw else { return nil }
        guard let schema = (raw["schema_version"] as? NSNumber)?.intValue,
              schema == 1,
              let seq = (raw["seq"] as? NSNumber)?.int64Value,
              let boardId = raw["board_id"] as? String,
              let op = raw["op"] as? [String: Any],
              let userId = raw["user_id"] as? String,
              let clientId = raw["client_id"] as? String,
              let timestamp = (raw["ts"] as? NSNumber)?.int64Value,
              let opId = raw["op_id"] as? String else { return nil }
        let serverSeq: Int64?
        if let value = raw["server_seq"] {
            guard let number = value as? NSNumber else { return nil }
            serverSeq = number.int64Value
        } else {
            serverSeq = nil
        }
        guard let revisions = parseBaseRevisions(raw["base_revisions"]) else { return nil }
        return SyncEnvelopePayload(schemaVersion: schema, seq: seq, serverSeq: serverSeq, baseRevisions: revisions, boardId: boardId, op: op, userId: userId, clientId: clientId, timestamp: timestamp, opId: opId, raw: raw)
    }

    private static func parseBaseRevisions(_ value: Any?) -> [BaseRevisionPayload]? {
        guard let value else { return [] }
        guard let values = value as? [[String: Any]] else { return nil }
        var result: [BaseRevisionPayload] = []
        for item in values {
            guard let elementId = item["element_id"] as? String,
                  let revision = (item["revision"] as? NSNumber)?.int64Value else {
                return nil
            }
            if item["last_op_id"] != nil && !(item["last_op_id"] is String) { return nil }
            result.append(BaseRevisionPayload(
                elementId: elementId,
                revision: revision,
                lastOpId: item["last_op_id"] as? String
            ))
        }
        return result
    }
}

enum LiveStrokePhases {
    static let begin = "begin"
    static let append = "append"
    static let end = "end"
    static let cancel = "cancel"
    static let all: Set<String> = [begin, append, end, cancel]
}

struct LiveStrokeEnvelopePayload {
    let schemaVersion: Int
    let boardId: String
    let userId: String
    let clientId: String
    let strokeId: String
    let phase: String
    let chunkSeq: Int
    let pointOffset: Int
    let raw: [String: Any]

    static func parse(_ data: Any) -> LiveStrokeEnvelopePayload? {
        let raw: [String: Any]?
        if let text = data as? String,
           let bytes = text.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: bytes) {
            raw = value as? [String: Any]
        } else {
            raw = data as? [String: Any]
        }
        guard let raw else { return nil }
        guard let schema = (raw["schema_version"] as? NSNumber)?.intValue,
              schema == 3,
              let boardId = raw["board_id"] as? String,
              let userId = raw["user_id"] as? String,
              let clientId = raw["client_id"] as? String,
              let strokeId = raw["stroke_id"] as? String,
              let phase = raw["phase"] as? String,
              LiveStrokePhases.all.contains(phase),
              let chunkSeq = (raw["chunk_seq"] as? NSNumber)?.intValue,
              let pointOffset = (raw["point_offset"] as? NSNumber)?.intValue,
              raw["ts"] is NSNumber else { return nil }
        var pointCount = 0
        if let points = raw["points"] {
            guard let values = points as? [[String: Any]] else { return nil }
            for point in values where !(point["x"] is NSNumber) || !(point["y"] is NSNumber) {
                return nil
            }
            pointCount = values.count
        }
        // The timeline is meaningless unless it lines up with the points it
        // dates, so a mismatched length is rejected rather than ignored.
        let pointTimes = raw["point_times"] ?? [NSNumber]()
        guard let times = pointTimes as? [NSNumber], times.count == pointCount else { return nil }
        return LiveStrokeEnvelopePayload(schemaVersion: schema, boardId: boardId, userId: userId, clientId: clientId, strokeId: strokeId, phase: phase, chunkSeq: chunkSeq, pointOffset: pointOffset, raw: raw)
    }
}

struct SceneDeltaPayload {
    let schemaVersion: Int
    let baseVersion: Int
    let version: Int
    let fullSnapshot: Bool
    let upserts: [[String: Any]]
    let removedIds: [String]
    let raw: [String: Any]

    static func parse(_ raw: [String: Any]) -> SceneDeltaPayload? {
        guard let schema = (raw["schema_version"] as? NSNumber)?.intValue,
              schema == 1,
              let baseVersion = (raw["base_version"] as? NSNumber)?.intValue,
              let version = (raw["version"] as? NSNumber)?.intValue,
              let fullSnapshot = raw["full_snapshot"] as? Bool else { return nil }
        let upserts: [[String: Any]]
        if let value = raw["upserts"] {
            guard let shapes = value as? [[String: Any]] else { return nil }
            upserts = shapes
        } else {
            upserts = []
        }
        let removedIds: [String]
        if let value = raw["removed_ids"] {
            guard let ids = value as? [String] else { return nil }
            removedIds = ids
        } else {
            removedIds = []
        }
        return SceneDeltaPayload(schemaVersion: schema, baseVersion: baseVersion, version: version, fullSnapshot: fullSnapshot, upserts: upserts, removedIds: removedIds, raw: raw)
    }
}

struct WorkspaceExportPayload {
    let schemaVersion: Int
    let roomId: String
    let checkpointSeq: Int64
    let currentBoardId: String
    let raw: [String: Any]

    static func parse(_ raw: [String: Any]) -> WorkspaceExportPayload? {
        guard let schema = (raw["schema_version"] as? NSNumber)?.intValue,
              schema == 1,
              let roomId = raw["room_id"] as? String,
              let checkpointSeq = (raw["checkpoint_seq"] as? NSNumber)?.int64Value,
              raw["created_at"] is NSNumber,
              raw["board_order"] is [String],
              let currentBoardId = raw["current_board_id"] as? String,
              raw["ratio"] is String,
              raw["scale_min"] is NSNumber,
              raw["scale_max"] is NSNumber,
              raw["boards"] is [String: Any] else { return nil }
        return WorkspaceExportPayload(schemaVersion: schema, roomId: roomId, checkpointSeq: checkpointSeq, currentBoardId: currentBoardId, raw: raw)
    }
}

struct RoomBootstrapProtocolPayload {
    let workspace: [String: Any]?
    let checkpointSeq: Int64
    let tail: [[String: Any]]

    static func parse(_ raw: [String: Any]) -> RoomBootstrapProtocolPayload? {
        let workspace: [String: Any]?
        if let value = raw["workspace"], !(value is NSNull) {
            guard let object = value as? [String: Any],
                  let parsed = WorkspaceExportPayload.parse(object) else { return nil }
            workspace = parsed.raw
        } else {
            workspace = nil
        }
        guard let checkpoint = (raw["checkpoint_seq"] as? NSNumber)?.int64Value,
              let rawTail = raw["tail"] as? [Any] else { return nil }
        var tail: [[String: Any]] = []
        for value in rawTail {
            guard let envelope = SyncEnvelopePayload.parse(value) else { return nil }
            tail.append(envelope.raw)
        }
        return RoomBootstrapProtocolPayload(workspace: workspace, checkpointSeq: checkpoint, tail: tail)
    }
}
