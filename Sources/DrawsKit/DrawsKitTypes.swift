import Foundation

public struct RoomBootstrapPayload {
    public let workspace: [String: Any]?
    public let checkpointSeq: Int64
    public let tail: [[String: Any]]

    public init(workspace: [String: Any]?, checkpointSeq: Int64, tail: [[String: Any]]) {
        self.workspace = workspace
        self.checkpointSeq = checkpointSeq
        self.tail = tail
    }
}

/// Cloud recording session from sdk-api `/v1/rooms/:roomId/recording/…`.
public struct RecordingSession {
    public let recordingId: String
    public let appId: String?
    public let roomId: String?
    public let status: String
    public let externalRef: String?
    public let wallStart: String?
    public let wallEnd: String?
    public let startServerSeq: Int64?
    public let endServerSeq: Int64?
    public let startedAt: String?
    public let stoppedAt: String?

    public init(
        recordingId: String,
        appId: String? = nil,
        roomId: String? = nil,
        status: String,
        externalRef: String? = nil,
        wallStart: String? = nil,
        wallEnd: String? = nil,
        startServerSeq: Int64? = nil,
        endServerSeq: Int64? = nil,
        startedAt: String? = nil,
        stoppedAt: String? = nil
    ) {
        self.recordingId = recordingId
        self.appId = appId
        self.roomId = roomId
        self.status = status
        self.externalRef = externalRef
        self.wallStart = wallStart
        self.wallEnd = wallEnd
        self.startServerSeq = startServerSeq
        self.endServerSeq = endServerSeq
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
    }
}

public struct DrawsKitInitParams {
    public let id: String
    public let roomId: String
    public let appid: String
    public let userId: String
    /// Required for cloud edition; optional for local.
    public let token: String
    /// Required when `config["productEdition"] == "local"`.
    public let license: String?
    public let config: [String: Any]?
    public let imTransport: DrawsKitImTransport?

    public init(
        id: String,
        roomId: String,
        appid: String,
        userId: String,
        token: String = "",
        license: String? = nil,
        config: [String: Any]? = nil,
        imTransport: DrawsKitImTransport? = nil
    ) {
        self.id = id
        self.roomId = roomId
        self.appid = appid
        self.userId = userId
        self.token = token
        self.license = license
        self.config = config
        self.imTransport = imTransport
    }
}
