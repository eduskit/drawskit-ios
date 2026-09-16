import Foundation

internal final class RoomApiClientConfig {
    let roomId: String
    let appid: String
    let serverHost: String
    let serverPath: String
    private let lock = NSLock()
    private var _token: String

    var token: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _token
        }
        set {
            lock.lock()
            _token = newValue
            lock.unlock()
        }
    }

    init(roomId: String, appid: String, token: String, serverHost: String, serverPath: String) {
        self.roomId = roomId
        self.appid = appid
        self._token = token
        self.serverHost = serverHost
        self.serverPath = serverPath
    }
}

internal struct DrawsKitSessionPermissions {
    let canDraw: Bool
    let canSync: Bool
    let canReportActions: Bool
}

internal struct DrawsKitActionReportConfig {
    let enabled: Bool?
    let sampleRate: Double?
    let batchSize: Int?
    let flushIntervalMs: Int64?
}

internal struct DrawsKitSessionContext {
    let appId: String
    let roomId: String
    let userId: String
    let role: String?
    let expiresAt: String?
    let permissions: DrawsKitSessionPermissions
    let actionReport: DrawsKitActionReportConfig?
    let serverTime: Int64?
}

internal struct RoomApiHttpError: Error, LocalizedError {
    let status: Int
    let method: String
    let path: String
    let body: String

    var errorDescription: String? {
        "room API \(method) \(path) failed: HTTP \(status): \(body)"
    }

    var isCompactionConflict: Bool { status == 409 }
    var isNotFound: Bool { status == 404 }
}

/// Built-in HTTP client for room bootstrap / op persistence (see room-snapshot-sync.md §6).
internal final class RoomApiClient {
    private let config: RoomApiClientConfig
    var onAuthExpired: (() -> Void)?
    private static let endpointSession = "session"
    private static let endpointActionsBatch = "actions/batch"
    private static let endpointCheckpoints = "checkpoints"
    private static let checkpointReasonSdkPeriodic = "sdk_periodic"

    init(config: RoomApiClientConfig) {
        self.config = config
    }

    func fetchSession() throws -> DrawsKitSessionContext {
        let json = try requestJson(method: "GET", urlString: "\(baseUrl())/\(Self.endpointSession)")
        guard let session = Self.parseSessionContext(json) else {
            throw NSError(
                domain: "DrawsKit",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "invalid SDK session payload"]
            )
        }
        return session
    }

    func fetchRoomBootstrap(sinceSeq: Int64? = nil) throws -> RoomBootstrapPayload {
        let first = try fetchBootstrapPage(sinceSeq: sinceSeq)
        return try collectBootstrapPages(first: first, requestedSinceSeq: sinceSeq)
    }

    func reportOps(envelopes: [[String: Any]]) throws -> [String: Any] {
        let body: [String: Any] = ["envelopes": envelopes]
        return try requestJson(method: "POST", urlString: roomUrl(DrawsKitServerHosts.endpointOps), body: body)
    }

    func syncReload(
        clientId: String,
        pendingOps: [[String: Any]],
        lastKnownSeq: Int64
    ) throws -> RoomBootstrapPayload {
        let body: [String: Any] = [
            "client_id": clientId,
            "pending_ops": pendingOps,
            "last_known_seq": lastKnownSeq,
        ]
        let json = try requestJson(
            method: "POST",
            urlString: roomUrl(DrawsKitServerHosts.endpointSyncReload),
            body: body
        )
        let hydrated = try WorkspaceBlob.hydrateBootstrapPage(json)
        let first = try Self.bootstrapPageFromDict(hydrated)
        return try collectBootstrapPages(first: first, requestedSinceSeq: lastKnownSeq)
    }

    func reportActions(events: [[String: Any]]) throws {
        if events.isEmpty { return }
        _ = try requestJson(
            method: "POST",
            urlString: roomUrl(Self.endpointActionsBatch),
            body: ["events": events]
        )
    }

    func createCheckpoint(workspace: [String: Any]) throws {
        _ = try requestJson(
            method: "POST",
            urlString: roomUrl(Self.endpointCheckpoints),
            body: [
                "reason": Self.checkpointReasonSdkPeriodic,
                "workspace": workspace,
            ]
        )
    }

    /// Refresh private courseware URLs using the existing Room Token.
    func refreshCoursewareAssets(
        fileId: String,
        timeoutMs: Int = SyncPolicy.coursewareRefreshHttpTimeoutMs
    ) throws -> [String: Any] {
        let encoded = fileId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileId
        return try requestJson(
            method: "GET",
            urlString: roomUrl("coursewares/\(encoded)/assets"),
            timeoutInterval: TimeInterval(timeoutMs) / 1_000
        )
    }

    /// Start cloud recording (sdk-api `/v1/...`, not `/api/v1`).
    func startRecording(externalRef: String? = nil) throws -> RecordingSession {
        var body: [String: Any] = [:]
        if let externalRef, !externalRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["externalRef"] = externalRef.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let json = try requestJson(
            method: "POST",
            urlString: recordingUrl(DrawsKitServerHosts.endpointRecordingStart),
            body: body
        )
        return try Self.parseRecordingSession(json)
    }

    func stopRecording(recordingId: String) throws -> RecordingSession {
        let id = recordingId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw NSError(
                domain: "DrawsKit",
                code: 35,
                userInfo: [NSLocalizedDescriptionKey: "recordingId is required"]
            )
        }
        let json = try requestJson(
            method: "POST",
            urlString: recordingUrl(DrawsKitServerHosts.endpointRecordingStop),
            body: ["recordingId": id]
        )
        return try Self.parseRecordingSession(json)
    }

    func updateToken(_ token: String) {
        config.token = token
    }

    /// Headers for sdk-api courseware content URLs. Third-party URLs stay unsigned.
    func authorizedHeaders(for urlString: String) -> [String: String] {
        guard isSdkApiUrl(urlString) else { return [:] }
        return [
            "Authorization": "Bearer \(config.token)",
            "X-App-Id": config.appid,
        ]
    }

    private func fetchBootstrapPage(sinceSeq: Int64?) throws -> RoomBootstrapPage {
        var urlString = roomUrl(DrawsKitServerHosts.endpointBootstrap)
        if let sinceSeq, sinceSeq > 0 {
            urlString += "?since_seq=\(sinceSeq)"
        }
        let json = try requestJson(method: "GET", urlString: urlString)
        let hydrated = try WorkspaceBlob.hydrateBootstrapPage(json)
        return try Self.bootstrapPageFromDict(hydrated)
    }

    private func collectBootstrapPages(
        first: RoomBootstrapPage,
        requestedSinceSeq: Int64?
    ) throws -> RoomBootstrapPayload {
        let seedExpected = UInt64(max(first.checkpointSeq, requestedSinceSeq ?? first.checkpointSeq) + 1)
        var state = try SyncPolicy.mergeBootstrapPage(
            aggregateJson: nil,
            page: first.toDict(),
            previousCursor: -1,
            pageCount: 0,
            expectedServerSeq: seedExpected
        )
        while state.hasMore {
            guard let next = state.nextSinceSeq, next >= 0 else {
                throw NSError(
                    domain: "DrawsKit",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "invalid room bootstrap pagination cursor"]
                )
            }
            let page = try fetchBootstrapPage(sinceSeq: next)
            state = try SyncPolicy.mergeBootstrapPage(
                aggregateJson: state.aggregateJson,
                page: page.toDict(),
                previousCursor: state.previousCursor,
                pageCount: state.pageCount,
                expectedServerSeq: state.expectedServerSeq
            )
        }
        guard let data = state.aggregateJson.data(using: .utf8),
              let aggregate = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(domain: "DrawsKit", code: 10, userInfo: [NSLocalizedDescriptionKey: "invalid room bootstrap aggregate"])
        }
        let workspace = aggregate["workspace"] as? [String: Any]
        let checkpointSeq = (aggregate["checkpoint_seq"] as? NSNumber)?.int64Value ?? 0
        let tail = aggregate["tail"] as? [[String: Any]] ?? []
        return RoomBootstrapPayload(workspace: workspace, checkpointSeq: checkpointSeq, tail: tail)
    }

    private func roomUrl(_ suffix: String) -> String {
        let room = config.roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.roomId
        return "\(baseUrl())/rooms/\(room)/\(suffix)"
    }

    private func recordingUrl(_ suffix: String) -> String {
        let host = config.serverHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = DrawsKitServerHosts.recordingPathDefault.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let room = config.roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.roomId
        return "\(host)/\(path)/rooms/\(room)/\(suffix)"
    }

    func collaborationBaseUrl() -> String { baseUrl() }

    func roomId() -> String { config.roomId }

    private func baseUrl() -> String {
        let host = config.serverHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = config.serverPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(host)/\(path)"
    }

    private static func parseRecordingSession(_ json: [String: Any]) throws -> RecordingSession {
        let recordingId: String
        if let value = json["recordingId"] as? String, !value.isEmpty {
            recordingId = value
        } else if let value = json["recording_id"] as? String, !value.isEmpty {
            recordingId = value
        } else {
            throw NSError(
                domain: "DrawsKit",
                code: 36,
                userInfo: [NSLocalizedDescriptionKey: "invalid recording session payload: missing recordingId"]
            )
        }
        let status = (json["status"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "recording"
        return RecordingSession(
            recordingId: recordingId,
            appId: json["appId"] as? String,
            roomId: json["roomId"] as? String,
            status: status,
            externalRef: json["externalRef"] as? String,
            wallStart: json["wallStart"] as? String,
            wallEnd: json["wallEnd"] as? String,
            startServerSeq: (json["startServerSeq"] as? NSNumber)?.int64Value,
            endServerSeq: (json["endServerSeq"] as? NSNumber)?.int64Value,
            startedAt: json["startedAt"] as? String,
            stoppedAt: json["stoppedAt"] as? String
        )
    }

    private func requestJson(
        method: String,
        urlString: String,
        body: [String: Any]? = nil,
        timeoutInterval: TimeInterval? = nil
    ) throws -> [String: Any] {
        var attempt = 0
        while true {
            guard let url = URL(string: urlString) else {
                throw NSError(domain: "DrawsKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid URL"])
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            if let timeoutInterval { request.timeoutInterval = timeoutInterval }
            applyAuth(&request)
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try DrawsKitURLSession.syncData(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "DrawsKit", code: 3, userInfo: [NSLocalizedDescriptionKey: "invalid response"])
            }
            if http.statusCode == 409,
               let delayMs = SyncPolicy.compactionRetryDelayMs(attempt: UInt32(attempt)) {
                attempt += 1
                usleep(useconds_t(delayMs * 1000))
                continue
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 401 {
                    onAuthExpired?()
                }
                throw RoomApiHttpError(status: http.statusCode, method: method, path: urlString, body: text)
            }
            if http.statusCode == 204 || text.isEmpty {
                return [:]
            }
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dict = object as? [String: Any] else {
                throw NSError(domain: "DrawsKit", code: 4, userInfo: [NSLocalizedDescriptionKey: "invalid JSON object"])
            }
            return Self.unwrapApiResponse(dict)
        }
    }

    private func applyAuth(_ request: inout URLRequest) {
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.appid, forHTTPHeaderField: "X-App-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func isSdkApiUrl(_ urlString: String) -> Bool {
        guard let target = URL(string: urlString),
              let base = URL(string: config.serverHost)
        else { return false }
        return target.scheme?.lowercased() == base.scheme?.lowercased()
            && target.host?.lowercased() == base.host?.lowercased()
            && (target.port ?? Self.defaultPort(target.scheme))
            == (base.port ?? Self.defaultPort(base.scheme))
    }

    private static func defaultPort(_ scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return -1
        }
    }

    private static func bootstrapPageFromDict(_ dict: [String: Any]) throws -> RoomBootstrapPage {
        guard let parsed = RoomBootstrapProtocolPayload.parse(dict) else {
            throw NSError(domain: "DrawsKit", code: 7, userInfo: [NSLocalizedDescriptionKey: "invalid room bootstrap payload"])
        }
        let hasMore = dict["has_more"] as? Bool ?? false
        let nextSinceSeq = (dict["next_since_seq"] as? NSNumber)?.int64Value
        return RoomBootstrapPage(
            workspace: parsed.workspace,
            checkpointSeq: parsed.checkpointSeq,
            tail: parsed.tail,
            hasMore: hasMore,
            nextSinceSeq: nextSinceSeq
        )
    }

    private static func unwrapApiResponse(_ value: [String: Any]) -> [String: Any] {
        if let code = value["code"] as? NSNumber, code.intValue == 0, let data = value["data"] {
            if let dict = data as? [String: Any] {
                return dict
            }
            return [:]
        }
        return value
    }

    private static func parseSessionContext(_ json: [String: Any]) -> DrawsKitSessionContext? {
        guard let appId = json["appId"] as? String, !appId.isEmpty,
              let roomId = json["roomId"] as? String, !roomId.isEmpty,
              let userId = json["userId"] as? String, !userId.isEmpty,
              let permissions = json["permissions"] as? [String: Any],
              let canDraw = permissions["canDraw"] as? Bool,
              let canSync = permissions["canSync"] as? Bool,
              let canReportActions = permissions["canReportActions"] as? Bool
        else {
            return nil
        }
        let actionReportJson = json["actionReport"] as? [String: Any]
        let actionReport = actionReportJson.map {
            DrawsKitActionReportConfig(
                enabled: $0["enabled"] as? Bool,
                sampleRate: ($0["sampleRate"] as? NSNumber)?.doubleValue,
                batchSize: ($0["batchSize"] as? NSNumber)?.intValue,
                flushIntervalMs: ($0["flushIntervalMs"] as? NSNumber)?.int64Value
            )
        }
        return DrawsKitSessionContext(
            appId: appId,
            roomId: roomId,
            userId: userId,
            role: json["role"] as? String,
            expiresAt: json["expiresAt"] as? String,
            permissions: DrawsKitSessionPermissions(
                canDraw: canDraw,
                canSync: canSync,
                canReportActions: canReportActions
            ),
            actionReport: actionReport,
            serverTime: (json["serverTime"] as? NSNumber)?.int64Value
        )
    }

    static func fromInitParams(_ params: DrawsKitInitParams) -> RoomApiClient? {
        // Cloud SDK authentication always needs sdk-api, even when no IM adapter is installed.
        guard let serverHost = try? SyncPolicy.resolveServerHost(
            config: params.config,
            imTransport: true
        ) else { return nil }
        let custom = params.config?["customServerConfig"] as? [String: Any]
        let token = (custom?["token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? params.token
        let serverPath = (custom?["serverPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? DrawsKitServerHosts.serverPathDefault
        return RoomApiClient(config: RoomApiClientConfig(
            roomId: params.roomId,
            appid: params.appid,
            token: token,
            serverHost: serverHost,
            serverPath: serverPath
        ))
    }

    private struct RoomBootstrapPage {
        let workspace: [String: Any]?
        let checkpointSeq: Int64
        let tail: [[String: Any]]
        let hasMore: Bool
        let nextSinceSeq: Int64?

        func toDict() -> [String: Any] {
            var dict: [String: Any] = [
                "checkpoint_seq": checkpointSeq,
                "tail": tail,
                "has_more": hasMore,
            ]
            if let workspace {
                dict["workspace"] = workspace
            } else {
                dict["workspace"] = NSNull()
            }
            if let nextSinceSeq {
                dict["next_since_seq"] = nextSinceSeq
            } else {
                dict["next_since_seq"] = NSNull()
            }
            return dict
        }
    }
}
