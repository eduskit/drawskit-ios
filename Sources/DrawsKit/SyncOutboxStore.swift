import Foundation

struct SyncOutboxRecord: Codable {
    let opId: String
    let roomId: String
    let clientId: String
    let envelopeJson: String
    let serverAck: Bool
    let createdAt: Int64
    let imDispatchedAt: Int64?
}

protocol SyncOutboxStore: AnyObject {
    func append(_ record: SyncOutboxRecord)
    func appendBatch(_ records: [SyncOutboxRecord])
    func listPending(roomId: String, clientId: String) throws -> [SyncOutboxRecord]
    func markAcked(opIds: [String])
    func markImDispatched(opIds: [String], dispatchedAt: Int64)
    func pruneAcked(roomId: String, maxAgeMs: Int64, maxCount: Int)
    func clearRoom(roomId: String, clientId: String)
    func flush()
}

func buildOutboxRecord(roomId: String, clientId: String, envelope: [String: Any]) -> SyncOutboxRecord? {
    guard let json = try? SyncPolicy.buildOutboxRecord(roomId: roomId, clientId: clientId, envelope: envelope),
          let opId = json["op_id"] as? String,
          let envelopeObj = json["envelope"] as? [String: Any],
          let envelopeJson = JSONCodec.stringify(envelopeObj)
    else { return nil }
    return SyncOutboxRecord(
        opId: opId,
        roomId: (json["room_id"] as? String) ?? roomId,
        clientId: (json["client_id"] as? String) ?? clientId,
        envelopeJson: envelopeJson,
        serverAck: json["server_ack"] as? Bool ?? false,
        createdAt: (json["created_at"] as? NSNumber)?.int64Value
            ?? Int64(Date().timeIntervalSince1970 * 1000),
        imDispatchedAt: (json["im_dispatched_at"] as? NSNumber)?.int64Value
    )
}

final class FileSyncOutboxStore: SyncOutboxStore {
    private let ioQueue = DispatchQueue(label: "io.drawskit.sync-outbox", qos: .utility)
    private let directoryURL: URL
    private var writeBuffer: [SyncOutboxRecord] = []
    private let bufferLock = NSLock()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directoryURL = base.appendingPathComponent("drawskit/outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func append(_ record: SyncOutboxRecord) {
        bufferLock.lock()
        writeBuffer.append(record)
        bufferLock.unlock()
        scheduleFlush()
    }

    func appendBatch(_ records: [SyncOutboxRecord]) {
        bufferLock.lock()
        writeBuffer.append(contentsOf: records)
        bufferLock.unlock()
        scheduleFlush()
    }

    func listPending(roomId: String, clientId: String) throws -> [SyncOutboxRecord] {
        let records = try loadRecords(roomId: roomId, clientId: clientId)
        return records.filter { !$0.serverAck }.sorted { $0.createdAt < $1.createdAt }
    }

    func markAcked(opIds: [String]) {
        guard !opIds.isEmpty else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            let grouped = self.groupedRoomFiles()
            for (fileURL, _) in grouped {
                var records = (try? self.readFile(fileURL)) ?? []
                let before = records.count
                records.removeAll { opIds.contains($0.opId) }
                if records.count != before {
                    try? self.writeFile(fileURL, records: records)
                }
            }
        }
    }

    func markImDispatched(opIds: [String], dispatchedAt: Int64) {
        guard !opIds.isEmpty else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            for (fileURL, _) in self.groupedRoomFiles() {
                var records = (try? self.readFile(fileURL)) ?? []
                var changed = false
                for index in records.indices {
                    if opIds.contains(records[index].opId) {
                        let old = records[index]
                        records[index] = SyncOutboxRecord(
                            opId: old.opId,
                            roomId: old.roomId,
                            clientId: old.clientId,
                            envelopeJson: old.envelopeJson,
                            serverAck: old.serverAck,
                            createdAt: old.createdAt,
                            imDispatchedAt: dispatchedAt
                        )
                        changed = true
                    }
                }
                if changed {
                    try? self.writeFile(fileURL, records: records)
                }
            }
        }
    }

    func pruneAcked(roomId: String, maxAgeMs: Int64, maxCount: Int) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let fileURL = self.fileURL(roomId: roomId, clientId: "")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            var records = (try? self.readFile(fileURL)) ?? []
            let payload: [[String: Any]] = records.compactMap { row in
                guard let envelope = JSONCodec.parseObject(row.envelopeJson) else { return nil }
                return [
                    "op_id": row.opId,
                    "room_id": row.roomId,
                    "client_id": row.clientId,
                    "envelope": envelope,
                    "server_ack": row.serverAck,
                    "created_at": row.createdAt,
                    "im_dispatched_at": row.imDispatchedAt as Any,
                ]
            }
            let dropIds = Set((try? SyncPolicy.planPruneAcked(
                records: payload,
                roomId: roomId,
                maxAgeMs: maxAgeMs,
                maxCount: Int32(maxCount)
            )) ?? [])
            if !dropIds.isEmpty {
                records.removeAll { dropIds.contains($0.opId) }
                try? self.writeFile(fileURL, records: records)
            }
        }
    }

    func clearRoom(roomId: String, clientId: String) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let fileURL = self.fileURL(roomId: roomId, clientId: clientId)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func flush() {
        ioQueue.sync { flushWriteBuffer() }
    }

    private func scheduleFlush() {
        ioQueue.async { [weak self] in self?.flushWriteBuffer() }
    }

    private func flushWriteBuffer() {
        bufferLock.lock()
        let batch = writeBuffer
        writeBuffer.removeAll()
        bufferLock.unlock()
        guard !batch.isEmpty else { return }
        for record in batch {
            let fileURL = fileURL(roomId: record.roomId, clientId: record.clientId)
            var records = (try? readFile(fileURL)) ?? []
            records.removeAll { $0.opId == record.opId }
            records.append(record)
            try? writeFile(fileURL, records: records)
        }
    }

    private func loadRecords(roomId: String, clientId: String) throws -> [SyncOutboxRecord] {
        let fileURL = fileURL(roomId: roomId, clientId: clientId)
        return try readFile(fileURL)
    }

    private func fileURL(roomId: String, clientId: String) -> URL {
        let safeRoom = roomId.replacingOccurrences(of: "/", with: "_")
        let safeClient = clientId.replacingOccurrences(of: "/", with: "_")
        return directoryURL.appendingPathComponent("\(safeRoom)__\(safeClient).json")
    }

    private func readFile(_ url: URL) throws -> [SyncOutboxRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([SyncOutboxRecord].self, from: data)
    }

    private func writeFile(_ url: URL, records: [SyncOutboxRecord]) throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: .atomic)
    }

    private func groupedRoomFiles() -> [(URL, String)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files.filter { $0.pathExtension == "json" }.map { ($0, $0.lastPathComponent) }
    }
}

func createSyncOutboxStore() -> SyncOutboxStore? {
    FileSyncOutboxStore()
}
