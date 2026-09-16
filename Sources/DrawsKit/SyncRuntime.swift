import Foundation

@_silgen_name("wb_sync_runtime_create")
private func wb_sync_runtime_create() -> OpaquePointer?

@_silgen_name("wb_sync_runtime_destroy")
private func wb_sync_runtime_destroy(_ handle: OpaquePointer?)

@_silgen_name("wb_sync_runtime_handle_json")
private func wb_sync_runtime_handle_json(
    _ handle: OpaquePointer?,
    _ eventJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_sync_runtime_history_loaded")
private func wb_sync_runtime_history_loaded(_ handle: OpaquePointer?) -> Int32

@_silgen_name("wb_sync_runtime_last_known_seq")
private func wb_sync_runtime_last_known_seq(_ handle: OpaquePointer?) -> UInt64

@_silgen_name("wb_sync_runtime_pending_count")
private func wb_sync_runtime_pending_count(_ handle: OpaquePointer?) -> UInt32

@_silgen_name("wb_sync_merge_bootstrap_page_json")
private func wb_sync_merge_bootstrap_page_json(
    _ aggregateJson: UnsafePointer<CChar>?,
    _ pageJson: UnsafePointer<CChar>?,
    _ previousCursor: Int64,
    _ pageCount: UInt32,
    _ expectedServerSeq: UInt64
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_sync_resolve_server_host_json")
private func wb_sync_resolve_server_host_json(
    _ inputJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_sync_compaction_retry_delay_ms")
private func wb_sync_compaction_retry_delay_ms(_ attempt: UInt32) -> Int64

@_silgen_name("wb_sync_classify_http_error")
private func wb_sync_classify_http_error(_ status: Int32) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_sync_plan_courseware_asset_refresh_json")
private func wb_sync_plan_courseware_asset_refresh_json(
    _ bootstrapJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_sync_apply_courseware_asset_refresh_json")
private func wb_sync_apply_courseware_asset_refresh_json(
    _ bootstrapJson: UnsafePointer<CChar>?,
    _ refreshedFilesJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_sync_rewrite_courseware_content_urls_json")
private func wb_sync_rewrite_courseware_content_urls_json(
    _ bootstrapJson: UnsafePointer<CChar>?,
    _ roomApiBase: UnsafePointer<CChar>?,
    _ roomId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_sync_rewrite_courseware_file_content_urls_json")
private func wb_sync_rewrite_courseware_file_content_urls_json(
    _ fileJson: UnsafePointer<CChar>?,
    _ roomApiBase: UnsafePointer<CChar>?,
    _ roomId: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_sync_is_expired_courseware_asset")
private func wb_sync_is_expired_courseware_asset(
    _ url: UnsafePointer<CChar>?,
    _ reason: UnsafePointer<CChar>?,
    _ status: Int32
) -> Int32

@_silgen_name("wb_sync_courseware_asset_url_has_access_credential")
private func wb_sync_courseware_asset_url_has_access_credential(
    _ url: UnsafePointer<CChar>?
) -> Int32

@_silgen_name("wb_sync_needs_courseware_asset_refresh")
private func wb_sync_needs_courseware_asset_refresh(
    _ url: UnsafePointer<CChar>?,
    _ reason: UnsafePointer<CChar>?,
    _ status: Int32
) -> Int32

@_silgen_name("wb_sync_is_waiting_for_signed_url")
private func wb_sync_is_waiting_for_signed_url(
    _ reason: UnsafePointer<CChar>?
) -> Int32

@_silgen_name("wb_sync_build_outbox_record_json")
private func wb_sync_build_outbox_record_json(
    _ roomId: UnsafePointer<CChar>?,
    _ clientId: UnsafePointer<CChar>?,
    _ envelopeJson: UnsafePointer<CChar>?,
    _ nowMs: UInt64
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_sync_plan_prune_acked_json")
private func wb_sync_plan_prune_acked_json(
    _ recordsJson: UnsafePointer<CChar>?,
    _ roomId: UnsafePointer<CChar>?,
    _ nowMs: UInt64,
    _ maxAgeMs: Int64,
    _ maxCount: Int32
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_license_verify_json")
private func wb_license_verify_json(_ inputJson: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("wb_engine_free_string")
private func wb_sync_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

/// Thin adapter over `drawskit-sdk-sync` (`wb_sync_runtime_*`).
final class SyncRuntime {
    private var handle: OpaquePointer?
    /// The opaque Rust runtime contains mutable state. Its callers span the IM
    /// transport queue, Room API callbacks and the main-loop timers, so keep
    /// the pointer alive and exclusively borrowed for each complete FFI call.
    private let ffiLock = NSLock()

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    /// Hard-fail when FFI is unavailable — no Swift strategy fallback.
    static func create() throws -> SyncRuntime {
        guard let h = wb_sync_runtime_create() else {
            throw NSError(
                domain: "DrawsKit",
                code: 20,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "SyncRuntime unavailable (missing wb_sync_runtime_* in libwhiteboard_ffi)",
                ]
            )
        }
        return SyncRuntime(handle: h)
    }

    @discardableResult
    func handle(_ event: [String: Any]) -> [[String: Any]] {
        ffiLock.lock()
        defer { ffiLock.unlock() }
        guard let handle,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8)
        else { return [] }
        return json.withCString { cstr in
            guard let out = wb_sync_runtime_handle_json(handle, cstr) else { return [] }
            defer { wb_sync_free_string(out) }
            let s = String(cString: out)
            guard let data = s.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [Any]
            else { return [] }
            return payload.compactMap { $0 as? [String: Any] }
        }
    }

    var historyLoaded: Bool {
        ffiLock.lock()
        defer { ffiLock.unlock() }
        guard let handle else { return false }
        return wb_sync_runtime_history_loaded(handle) != 0
    }

    var lastKnownServerSeq: Int64 {
        ffiLock.lock()
        defer { ffiLock.unlock() }
        guard let handle else { return 0 }
        return Int64(wb_sync_runtime_last_known_seq(handle))
    }

    func destroy() {
        ffiLock.lock()
        let oldHandle = handle
        handle = nil
        ffiLock.unlock()
        if let oldHandle { wb_sync_runtime_destroy(oldHandle) }
    }

    deinit { destroy() }
}

enum SyncPolicy {
    /// Matches `drawskit-sdk-sync` COURSEWARE_REFRESH_HTTP_TIMEOUT_MS.
    static let coursewareRefreshHttpTimeoutMs = 15_000
    static let coursewareWaitingForSignedUrl = "courseware asset waiting for signed url"

    struct CoursewareFirstPage {
        let fileId: String
        let url: String
        let format: String
        let pageIndex: Int
    }

    struct CoursewareAssetRefreshPlan {
        let blockingFileIds: [String]
        let deferredBatches: [[String]]
        let blockingTimeoutMs: Int
        let httpTimeoutMs: Int
        let firstPage: CoursewareFirstPage?
        let overlapPrefetch: Bool
        let prefetchFirstPage: Bool
    }

    static func planCoursewareAssetRefresh(_ bootstrap: [String: Any]) throws -> CoursewareAssetRefreshPlan {
        let data = try JSONSerialization.data(withJSONObject: bootstrap)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "DrawsKit", code: 26, userInfo: [NSLocalizedDescriptionKey: "bootstrap utf8"])
        }
        return try json.withCString { ptr in
            guard let out = wb_sync_plan_courseware_asset_refresh_json(ptr) else {
                throw NSError(domain: "DrawsKit", code: 26, userInfo: [NSLocalizedDescriptionKey: "courseware plan failed"])
            }
            defer { wb_sync_free_string(out) }
            let value = String(cString: out)
            guard let outputData = value.data(using: .utf8),
                  let raw = try JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
                throw NSError(domain: "DrawsKit", code: 26, userInfo: [NSLocalizedDescriptionKey: "courseware plan parse"])
            }
            let firstRaw = raw["first_page"] as? [String: Any]
            let firstUrl = (firstRaw?["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstPage = firstUrl.flatMap { url -> CoursewareFirstPage? in
                guard !url.isEmpty else { return nil }
                return CoursewareFirstPage(
                    fileId: firstRaw?["file_id"] as? String ?? "",
                    url: url,
                    format: firstRaw?["format"] as? String ?? "",
                    pageIndex: (firstRaw?["page_index"] as? NSNumber)?.intValue ?? 0
                )
            }
            return CoursewareAssetRefreshPlan(
                blockingFileIds: raw["blocking_file_ids"] as? [String] ?? [],
                deferredBatches: raw["deferred_batches"] as? [[String]] ?? [],
                blockingTimeoutMs: (raw["blocking_timeout_ms"] as? NSNumber)?.intValue ?? 2_000,
                httpTimeoutMs: (raw["http_timeout_ms"] as? NSNumber)?.intValue
                    ?? Self.coursewareRefreshHttpTimeoutMs,
                firstPage: firstPage,
                overlapPrefetch: raw["overlap_prefetch"] as? Bool ?? true,
                prefetchFirstPage: raw["prefetch_first_page"] as? Bool ?? false
            )
        }
    }

    static func rewriteCoursewareContentUrls(
        _ bootstrap: [String: Any],
        roomApiBase: String,
        roomId: String
    ) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: bootstrap)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "DrawsKit", code: 26, userInfo: [NSLocalizedDescriptionKey: "bootstrap utf8"])
        }
        return try json.withCString { bootstrapPtr in
            try roomApiBase.withCString { basePtr in
                try roomId.withCString { roomPtr in
                    guard let out = wb_sync_rewrite_courseware_content_urls_json(
                        bootstrapPtr,
                        basePtr,
                        roomPtr
                    ) else {
                        throw NSError(domain: "DrawsKit", code: 26, userInfo: [NSLocalizedDescriptionKey: "courseware rewrite failed"])
                    }
                    defer { wb_sync_free_string(out) }
                    let value = String(cString: out)
                    guard let outputData = value.data(using: .utf8),
                          let raw = try JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
                        throw NSError(domain: "DrawsKit", code: 26, userInfo: [NSLocalizedDescriptionKey: "courseware rewrite parse"])
                    }
                    return raw
                }
            }
        }
    }

    static func rewriteCoursewareFileContentUrls(
        _ file: [String: Any],
        roomApiBase: String,
        roomId: String
    ) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: file)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "DrawsKit", code: 26, userInfo: [NSLocalizedDescriptionKey: "file utf8"])
        }
        return try json.withCString { filePtr in
            try roomApiBase.withCString { basePtr in
                try roomId.withCString { roomPtr in
                    guard let out = wb_sync_rewrite_courseware_file_content_urls_json(
                        filePtr,
                        basePtr,
                        roomPtr
                    ) else {
                        throw NSError(domain: "DrawsKit", code: 26, userInfo: [NSLocalizedDescriptionKey: "courseware file rewrite failed"])
                    }
                    defer { wb_sync_free_string(out) }
                    let value = String(cString: out)
                    guard let outputData = value.data(using: .utf8),
                          let raw = try JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
                        throw NSError(domain: "DrawsKit", code: 26, userInfo: [NSLocalizedDescriptionKey: "courseware file rewrite parse"])
                    }
                    return raw
                }
            }
        }
    }

    static func applyCoursewareAssetRefresh(
        _ bootstrap: [String: Any],
        refreshedFiles: [[String: Any]]
    ) throws -> [String: Any] {
        let bootstrapData = try JSONSerialization.data(withJSONObject: bootstrap)
        let filesData = try JSONSerialization.data(withJSONObject: refreshedFiles)
        guard let bootstrapJson = String(data: bootstrapData, encoding: .utf8),
              let filesJson = String(data: filesData, encoding: .utf8) else {
            throw NSError(domain: "DrawsKit", code: 27, userInfo: [NSLocalizedDescriptionKey: "courseware merge utf8"])
        }
        return try bootstrapJson.withCString { bootstrapPtr in
            try filesJson.withCString { filesPtr in
                guard let out = wb_sync_apply_courseware_asset_refresh_json(bootstrapPtr, filesPtr) else {
                    throw NSError(domain: "DrawsKit", code: 27, userInfo: [NSLocalizedDescriptionKey: "courseware merge failed"])
                }
                defer { wb_sync_free_string(out) }
                let value = String(cString: out)
                guard let outputData = value.data(using: .utf8),
                      let raw = try JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
                    throw NSError(domain: "DrawsKit", code: 27, userInfo: [NSLocalizedDescriptionKey: "courseware merge parse"])
                }
                return raw
            }
        }
    }

    static func isExpiredCoursewareAsset(url: String, reason: String, status: Int?) -> Bool {
        url.withCString { urlPtr in
            reason.withCString { reasonPtr in
                wb_sync_is_expired_courseware_asset(urlPtr, reasonPtr, Int32(status ?? -1)) != 0
            }
        }
    }

    static func coursewareAssetUrlHasAccessCredential(_ url: String) -> Bool {
        url.withCString { urlPtr in
            wb_sync_courseware_asset_url_has_access_credential(urlPtr) != 0
        }
    }

    static func needsCoursewareAssetRefresh(url: String, reason: String, status: Int?) -> Bool {
        url.withCString { urlPtr in
            reason.withCString { reasonPtr in
                wb_sync_needs_courseware_asset_refresh(urlPtr, reasonPtr, Int32(status ?? -1)) != 0
            }
        }
    }

    static func isWaitingForSignedUrl(_ reason: String) -> Bool {
        reason.withCString { reasonPtr in
            wb_sync_is_waiting_for_signed_url(reasonPtr) != 0
        }
    }

    struct BootstrapMergeState {
        let hasMore: Bool
        let previousCursor: Int64
        let pageCount: UInt32
        let expectedServerSeq: UInt64
        /// Opaque aggregate JSON (not a parsed object graph).
        let aggregateJson: String
        let nextSinceSeq: Int64?
    }

    static func mergeBootstrapPage(
        aggregateJson: String?,
        page: [String: Any],
        previousCursor: Int64,
        pageCount: UInt32,
        expectedServerSeq: UInt64
    ) throws -> BootstrapMergeState {
        let pageData = try JSONSerialization.data(withJSONObject: page)
        guard let pageJson = String(data: pageData, encoding: .utf8) else {
            throw NSError(domain: "DrawsKit", code: 21, userInfo: [NSLocalizedDescriptionKey: "page utf8"])
        }
        var aggregateCStr: [CChar]? = nil
        if let aggregateJson {
            aggregateCStr = aggregateJson.cString(using: .utf8)
        }
        return try pageJson.withCString { pagePtr in
            let out: UnsafeMutablePointer<CChar>?
            if var agg = aggregateCStr {
                out = wb_sync_merge_bootstrap_page_json(
                    &agg, pagePtr, previousCursor, pageCount, expectedServerSeq
                )
            } else {
                out = wb_sync_merge_bootstrap_page_json(
                    nil, pagePtr, previousCursor, pageCount, expectedServerSeq
                )
            }
            guard let out else {
                throw NSError(
                    domain: "DrawsKit",
                    code: 22,
                    userInfo: [NSLocalizedDescriptionKey: "wb_sync_merge_bootstrap_page_json failed"]
                )
            }
            defer { wb_sync_free_string(out) }
            let s = String(cString: out)
            guard let data = s.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw NSError(domain: "DrawsKit", code: 22, userInfo: [NSLocalizedDescriptionKey: "merge parse"])
            }
            guard let opaque = json["aggregate_json"] as? String, !opaque.isEmpty else {
                throw NSError(domain: "DrawsKit", code: 22, userInfo: [NSLocalizedDescriptionKey: "merge missing aggregate_json"])
            }
            let next = json["next_since_seq"]
            let nextSince: Int64? = {
                if next is NSNull { return nil }
                return (next as? NSNumber)?.int64Value
            }()
            return BootstrapMergeState(
                hasMore: json["has_more"] as? Bool ?? false,
                previousCursor: (json["previous_cursor"] as? NSNumber)?.int64Value ?? previousCursor,
                pageCount: UInt32((json["page_count"] as? NSNumber)?.intValue ?? Int(pageCount)),
                expectedServerSeq: UInt64((json["expected_server_seq"] as? NSNumber)?.uint64Value ?? expectedServerSeq),
                aggregateJson: opaque,
                nextSinceSeq: nextSince
            )
        }
    }

    static func compactionRetryDelayMs(attempt: UInt32) -> Int64? {
        let ms = wb_sync_compaction_retry_delay_ms(attempt)
        return ms < 0 ? nil : ms
    }

    /// `nil` status = transport/network failure.
    static func classifyHttpError(status: Int?) -> String {
        let code = Int32(status ?? -1)
        guard let out = wb_sync_classify_http_error(code) else { return "transient" }
        defer { wb_sync_free_string(out) }
        return String(cString: out)
    }

    static func buildOutboxRecord(roomId: String, clientId: String, envelope: [String: Any]) throws -> [String: Any] {
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
        guard let envelopeJson = String(data: envelopeData, encoding: .utf8) else {
            throw NSError(domain: "DrawsKit", code: 24, userInfo: [NSLocalizedDescriptionKey: "envelope utf8"])
        }
        return try roomId.withCString { roomPtr in
            try clientId.withCString { clientPtr in
                try envelopeJson.withCString { envPtr in
                    guard let out = wb_sync_build_outbox_record_json(
                        roomPtr,
                        clientPtr,
                        envPtr,
                        UInt64(Date().timeIntervalSince1970 * 1000)
                    ) else {
                        throw NSError(domain: "DrawsKit", code: 24, userInfo: [NSLocalizedDescriptionKey: "build outbox failed"])
                    }
                    defer { wb_sync_free_string(out) }
                    let s = String(cString: out)
                    guard let data = s.data(using: .utf8),
                          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else {
                        throw NSError(domain: "DrawsKit", code: 24, userInfo: [NSLocalizedDescriptionKey: "build outbox parse"])
                    }
                    return json
                }
            }
        }
    }

    static func planPruneAcked(
        records: [[String: Any]],
        roomId: String,
        maxAgeMs: Int64 = -1,
        maxCount: Int32 = -1
    ) throws -> [String] {
        let data = try JSONSerialization.data(withJSONObject: records)
        guard let recordsJson = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "DrawsKit", code: 25, userInfo: [NSLocalizedDescriptionKey: "records utf8"])
        }
        return try recordsJson.withCString { recPtr in
            try roomId.withCString { roomPtr in
                guard let out = wb_sync_plan_prune_acked_json(
                    recPtr,
                    roomPtr,
                    UInt64(Date().timeIntervalSince1970 * 1000),
                    maxAgeMs,
                    maxCount
                ) else {
                    throw NSError(domain: "DrawsKit", code: 25, userInfo: [NSLocalizedDescriptionKey: "prune plan failed"])
                }
                defer { wb_sync_free_string(out) }
                let s = String(cString: out)
                guard let data = s.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ids = json["drop_op_ids"] as? [String]
                else { return [] }
                return ids
            }
        }
    }

    static func verifyLicenseJson(_ input: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: input)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "DrawsKit", code: 26, userInfo: [NSLocalizedDescriptionKey: "license utf8"])
        }
        return try json.withCString { cstr in
            guard let out = wb_license_verify_json(cstr) else {
                throw NSError(domain: "DrawsKit", code: 26, userInfo: [NSLocalizedDescriptionKey: "license verify failed"])
            }
            defer { wb_sync_free_string(out) }
            let s = String(cString: out)
            guard let outData = s.data(using: .utf8),
                  let payload = try JSONSerialization.jsonObject(with: outData) as? [String: Any]
            else {
                throw NSError(domain: "DrawsKit", code: 26, userInfo: [NSLocalizedDescriptionKey: "license parse"])
            }
            return payload
        }
    }

    static func resolveServerHost(config: [String: Any]?, imTransport: Bool) throws -> String? {
        let custom = config?["customServerConfig"] as? [String: Any]
        let input: [String: Any] = [
            "custom_server_host": custom?["serverHost"] as Any,
            "server_environment": config?["serverEnvironment"] as Any,
            "hosts": [
                "local": DrawsKitServerHosts.local,
                "test": DrawsKitServerHosts.test,
                "production": DrawsKitServerHosts.production,
            ],
            "env_aliases": [
                "local": "local", "dev": "local", "development": "local",
                "test": "test", "staging": "test", "preview": "test",
                "production": "production", "prod": "production", "release": "production",
            ],
            "default_environment": DrawsKitServerHosts.defaultEnvironment,
            "im_transport": imTransport,
        ]
        let data = try JSONSerialization.data(withJSONObject: input)
        guard let json = String(data: data, encoding: .utf8) else { return nil }
        return try json.withCString { cstr in
            guard let out = wb_sync_resolve_server_host_json(cstr) else {
                throw NSError(
                    domain: "DrawsKit",
                    code: 23,
                    userInfo: [NSLocalizedDescriptionKey: "wb_sync_resolve_server_host_json failed"]
                )
            }
            defer { wb_sync_free_string(out) }
            let s = String(cString: out)
            guard let outData = s.data(using: .utf8),
                  let payload = try JSONSerialization.jsonObject(with: outData) as? [String: Any]
            else { return nil }
            let host = payload["host"] as? String
            return host?.isEmpty == false ? host : nil
        }
    }
}
