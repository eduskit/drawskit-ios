import Foundation

struct WorkspaceCheckpointRecord: Codable {
    let roomId: String
    let clientId: String
    let workspaceJson: String
    let updatedAt: Int64
    let localCheckpointSeq: Int64
}

protocol WorkspaceCheckpointStore: AnyObject {
    func save(_ record: WorkspaceCheckpointRecord)
    func load(roomId: String, clientId: String) throws -> WorkspaceCheckpointRecord?
    func clear(roomId: String, clientId: String)
    func flush()
}

final class FileWorkspaceCheckpointStore: WorkspaceCheckpointStore {
    private let ioQueue = DispatchQueue(label: "io.drawskit.workspace-checkpoint", qos: .utility)
    private let directoryURL: URL
    private var pending: WorkspaceCheckpointRecord?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directoryURL = base.appendingPathComponent("drawskit/workspace-checkpoint", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func save(_ record: WorkspaceCheckpointRecord) {
        pending = record
        ioQueue.async { [weak self] in self?.flushWrite() }
    }

    func load(roomId: String, clientId: String) throws -> WorkspaceCheckpointRecord? {
        let url = fileURL(roomId: roomId, clientId: clientId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WorkspaceCheckpointRecord.self, from: data)
    }

    func clear(roomId: String, clientId: String) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.fileURL(roomId: roomId, clientId: clientId))
        }
    }

    func flush() {
        ioQueue.sync { flushWrite() }
    }

    private func flushWrite() {
        guard let record = pending else { return }
        pending = nil
        let url = fileURL(roomId: record.roomId, clientId: record.clientId)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func fileURL(roomId: String, clientId: String) -> URL {
        let safeRoom = roomId.replacingOccurrences(of: "/", with: "_")
        let safeClient = clientId.replacingOccurrences(of: "/", with: "_")
        return directoryURL.appendingPathComponent("\(safeRoom)__\(safeClient).json")
    }
}

func createWorkspaceCheckpointStore() -> WorkspaceCheckpointStore? {
    FileWorkspaceCheckpointStore()
}
