import Foundation

/// Transcode-service wire contract. See docs/protocol/courseware-manifest.md.
let coursewareSchemaVersion = "1.0"

struct MediaSlot: Decodable {
    enum CodingKeys: String, CodingKey { case mediaId = "media_id", type, url, rect, poster }
    let mediaId: String
    let type: String
    let url: String
    let rect: [String: Double]
    let poster: String?
}

struct CoursewarePage: Decodable {
    enum CodingKeys: String, CodingKey { case url, format, width, height, sourcePage = "source_page", step, remarks, media }
    let url: String
    let format: String
    let width: Double
    let height: Double
    let sourcePage: Int
    let step: Int
    let remarks: String?
    let media: [MediaSlot]
}

struct CoursewarePayload: Decodable {
    let fileId: String
    let title: String?
    let sourceType: String
    let pages: [CoursewarePage]
}

struct H5CoursewarePayload {
    let fileId: String
    let url: String
    let title: String?
}

enum CoursewareMap {
    private struct Response: Decodable {
        let ok: Bool
        let payload: CoursewarePayload?
        let message: String?
    }
    /// DTO conversion only; manifest semantics live in shared Rust.
    static func parseManifest(_ manifest: Any, baseUrl: String?, title: String?) throws -> CoursewarePayload {
        let input: String
        if let raw = manifest as? String { input = raw }
        else if let raw = manifest as? Data { input = String(decoding: raw, as: UTF8.self) }
        else { input = String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self) }
        let data = try NativeEngine.parseCoursewareManifestJson(input, baseUrl: baseUrl, title: title)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.ok, let payload = response.payload else {
            throw NSError(domain: "DrawsKit.Manifest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: response.message ?? "Invalid manifest response"])
        }
        return payload
    }

    static func buildVideoFilePayload(_ url: String, title: String?) -> CoursewarePayload? {
        let normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let fileId = "file-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 0..<1_000_000))"
        let width = MediaDefaults.defaultPageWidth
        let height = MediaDefaults.defaultPageHeight
        return CoursewarePayload(
            fileId: fileId,
            title: title,
            sourceType: MediaDefaults.sourceTypeVideo,
            pages: [
                CoursewarePage(
                    url: "",
                    format: "webp",
                    width: width,
                    height: height,
                    sourcePage: 1,
                    step: 0,
                    remarks: nil,
                    media: [
                        MediaSlot(
                            mediaId: fileId,
                            type: MediaDefaults.kindVideo,
                            url: normalized,
                            rect: ["x": 0, "y": 0, "width": width, "height": height],
                            poster: nil
                        ),
                    ]
                ),
            ]
        )
    }

    static func buildImagesFilePayload(_ urls: [String], title: String?) -> CoursewarePayload? {
        let valid = urls.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !valid.isEmpty else { return nil }
        return CoursewarePayload(
            fileId: "file-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 0..<1_000_000))",
            title: title,
            sourceType: "image",
            pages: valid.enumerated().map { index, url in
                CoursewarePage(
                    url: url,
                    format: formatFromUrl(url),
                    width: 0,
                    height: 0,
                    sourcePage: index + 1,
                    step: 0,
                    remarks: nil,
                    media: []
                )
            }
        )
    }

    static func parseH5FileUrl(_ url: String, title: String?) -> H5CoursewarePayload? {
        let normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return H5CoursewarePayload(
            fileId: "h5-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 0..<1_000_000))",
            url: normalized,
            title: title
        )
    }

    static func manifestBaseUrl(_ manifestUrl: String) -> String {
        guard let url = URL(string: manifestUrl) else { return manifestUrl }
        return url.deletingLastPathComponent().absoluteString
    }

    private static func formatFromUrl(_ url: String) -> String {
        let path = url.split(separator: "?").first.map(String.init) ?? url
        return path.lowercased().hasSuffix(".svg") ? "svg" : "webp"
    }
}

enum CoursewareRead {
    static func isWebViewRenderMode(_ mode: String?) -> Bool {
        mode == EngineDefaults.coursewareRenderModeWebview
    }

    static func getCoursewareLayer(_ frame: [String: Any]?) -> [String: Any]? {
        guard let layers = frame?["layers"] as? [Any] else { return nil }
        for item in layers {
            guard let layer = item as? [String: Any],
                  layer.string("type") == RenderDefaults.renderLayerCourseware else { continue }
            return layer.dict("data")
        }
        return nil
    }

    static func hasWebViewCourseware(_ frame: [String: Any]?) -> Bool {
        guard let cw = getCoursewareLayer(frame) else { return false }
        return isWebViewRenderMode(cw.string("render_mode")) && !cw.string("webview_url").isEmpty
    }

    static func getPageCount(_ frame: [String: Any]?) -> Int {
        guard let cw = getCoursewareLayer(frame) else { return 0 }
        let count = cw.int("page_count")
        if count > 0 { return count }
        return cw.string("image_url").isEmpty ? 0 : 1
    }

    static func getPageIndex(_ frame: [String: Any]?) -> Int {
        getCoursewareLayer(frame)?.int("page_index") ?? 0
    }

    static func getCurrentFileId(_ frame: [String: Any]?) -> String {
        getCoursewareLayer(frame)?.string("resource_id") ?? ""
    }

    static func getCoursewareFiles(_ frame: [String: Any]?) -> [[String: Any]] {
        let workspace = (frame?["session"] as? [String: Any])?["workspace"] as? [String: Any]
        return (workspace?["courseware_files"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    static func getCoursewareFile(_ frame: [String: Any]?, fileId: String) -> [String: Any]? {
        getCoursewareFiles(frame).first { $0.string("file_id") == fileId }
    }

    static func getFileBoardList(_ frame: [String: Any]?, fileId: String) -> [String] {
        (getCoursewareFile(frame, fileId: fileId)?["board_ids"] as? [Any])?
            .compactMap { $0 as? String } ?? []
    }

    static func getThumbnailImages(_ frame: [String: Any]?, fileId: String) -> [String] {
        (getCoursewareFile(frame, fileId: fileId)?["page_urls"] as? [Any])?
            .compactMap { $0 as? String } ?? []
    }

    static func getPPTRemarks(_ frame: [String: Any]?, fileId: String) -> [String] {
        let workspace = (frame?["session"] as? [String: Any])?["workspace"] as? [String: Any]
        let remarks = workspace?["board_remarks"] as? [String: Any]
        return getFileBoardList(frame, fileId: fileId).map { remarks?[$0] as? String ?? "" }
    }
}
