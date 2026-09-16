import Foundation

/// Transcode-service wire contract. See docs/protocol/courseware-manifest.md.
let coursewareSchemaVersion = "1.0"

struct MediaSlot {
    let mediaId: String
    let type: String
    let url: String
    let rect: [String: Double]
    let poster: String?
}

struct CoursewarePage {
    let url: String
    let format: String
    let width: Double
    let height: Double
    let sourcePage: Int
    let step: Int
    let remarks: String?
    let media: [MediaSlot]
}

struct CoursewarePayload {
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

enum ManifestError {
    case notAnObject
    case unsupportedVersion
    case missingFileId
    case emptyPages
    case invalidPage
    case missingBaseUrl
}

enum ManifestParseResult {
    case ok(CoursewarePayload)
    case failure(ManifestError)
}

enum CoursewareMap {
    /// Parses the transcode-service manifest. Relative asset paths resolve against
    /// `baseUrl` (the package root that contains `manifest.json`).
    static func parseManifest(_ manifest: Any?, baseUrl: String? = nil) -> ManifestParseResult {
        guard let map = asDictionary(manifest) else { return .failure(.notAnObject) }
        guard isSupportedSchemaVersion(map["schemaVersion"]) else {
            return .failure(.unsupportedVersion)
        }
        let fileId = (map["coursewareId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !fileId.isEmpty else { return .failure(.missingFileId) }
        guard let slides = map["slides"] as? [Any], !slides.isEmpty else {
            return .failure(.emptyPages)
        }

        let root = baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = buildMediaCatalog(map["media"])
        var pages: [CoursewarePage] = []

        for rawSlide in slides {
            guard let slide = rawSlide as? [String: Any],
                  let steps = slide["steps"] as? [Any] else {
                return .failure(.invalidPage)
            }
            let slideIndex = (slide["slideIndex"] as? NSNumber)?.intValue ?? (pages.count + 1)
            for rawStep in steps {
                guard let step = rawStep as? [String: Any],
                      let asset = stepAsset(step) else {
                    return .failure(.invalidPage)
                }
                guard let url = resolveAssetUrl(asset.src, baseUrl: root) else {
                    return .failure(.missingBaseUrl)
                }
                let stepIndex = (step["stepIndex"] as? NSNumber)?.intValue ?? 0
                guard let media = mediaForStep(
                    catalog: catalog,
                    slideIndex: slideIndex,
                    stepIndex: stepIndex,
                    visibleMediaIds: step["visibleMediaIds"],
                    pageWidth: asset.width,
                    pageHeight: asset.height,
                    baseUrl: root
                ) else {
                    return .failure(.missingBaseUrl)
                }
                pages.append(
                    CoursewarePage(
                        url: url,
                        format: asset.format,
                        width: asset.width,
                        height: asset.height,
                        sourcePage: slideIndex,
                        step: stepIndex,
                        remarks: nil,
                        media: media
                    )
                )
            }
        }

        guard !pages.isEmpty else { return .failure(.emptyPages) }
        let source = map["source"] as? [String: Any]
        let title = (source?["fileName"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        } ?? fileId
        return .ok(
            CoursewarePayload(
                fileId: fileId,
                title: title,
                sourceType: sourceTypeFromFileType(source?["fileType"] as? String),
                pages: pages
            )
        )
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

    static func errorMessage(_ error: ManifestError) -> String {
        switch error {
        case .unsupportedVersion:
            return "Unsupported courseware schemaVersion (expected \(coursewareSchemaVersion))"
        case .missingFileId:
            return "Courseware manifest is missing a server-issued coursewareId"
        case .emptyPages:
            return "Courseware manifest has no slides/steps"
        case .invalidPage:
            return "Courseware manifest contains a step without a renderable asset"
        case .missingBaseUrl:
            return "Courseware manifest uses relative asset paths; pass baseUrl (package root)"
        case .notAnObject:
            return "Courseware manifest must be an object"
        }
    }

    static func manifestBaseUrl(_ manifestUrl: String) -> String {
        guard let url = URL(string: manifestUrl) else { return manifestUrl }
        return url.deletingLastPathComponent().absoluteString
    }

    static func resolveAssetUrl(_ src: String, baseUrl: String?) -> String? {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.hasPrefix("data:") || trimmed.hasPrefix("file:") {
            return trimmed
        }
        guard let baseUrl, !baseUrl.isEmpty else { return nil }
        let root = baseUrl.hasSuffix("/") ? baseUrl : baseUrl + "/"
        guard let base = URL(string: root),
              let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL else {
            return nil
        }
        return resolved.absoluteString
    }

    private static func asDictionary(_ manifest: Any?) -> [String: Any]? {
        switch manifest {
        case let map as [String: Any]:
            return map
        case let text as String:
            return text.data(using: .utf8).flatMap(decodeJsonObject)
        case let data as Data:
            return decodeJsonObject(data)
        default:
            return nil
        }
    }

    private static func decodeJsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func isSupportedSchemaVersion(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber:
            return number.doubleValue == 1.0
        case let text as String:
            return text == "1" || text == "1.0" || text.range(of: #"^1\.\d+$"#, options: .regularExpression) != nil
        default:
            return false
        }
    }

    private static func sourceTypeFromFileType(_ fileType: String?) -> String {
        switch fileType?.lowercased() {
        case "ppt", "pptx": return "ppt"
        case "pdf": return "pdf"
        case "doc", "docx": return "doc"
        default: return "image"
        }
    }

    private struct StepAsset {
        let src: String
        let width: Double
        let height: Double
        let format: String
    }

    private static func stepAsset(_ step: [String: Any]) -> StepAsset? {
        if let svg = step["svg"] as? [String: Any],
           let src = svg["src"] as? String, !src.isEmpty {
            return StepAsset(
                src: src,
                width: (svg["width"] as? NSNumber)?.doubleValue ?? 0,
                height: (svg["height"] as? NSNumber)?.doubleValue ?? 0,
                format: "svg"
            )
        }
        if let webp = step["webp"] as? [String: Any],
           let src = webp["src"] as? String, !src.isEmpty {
            return StepAsset(
                src: src,
                width: (webp["width"] as? NSNumber)?.doubleValue ?? 0,
                height: (webp["height"] as? NSNumber)?.doubleValue ?? 0,
                format: "webp"
            )
        }
        return nil
    }

    private struct MediaCatalogEntry {
        let mediaId: String
        let type: String
        let src: String
        let poster: String?
        let placements: [[String: Any]]
    }

    private static func buildMediaCatalog(_ raw: Any?) -> [String: MediaCatalogEntry] {
        guard let list = raw as? [Any] else { return [:] }
        var catalog: [String: MediaCatalogEntry] = [:]
        for item in list {
            guard let map = item as? [String: Any],
                  let mediaId = map["mediaId"] as? String, !mediaId.isEmpty,
                  let src = map["src"] as? String, !src.isEmpty else { continue }
            let placements = (map["placements"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            catalog[mediaId] = MediaCatalogEntry(
                mediaId: mediaId,
                type: (map["type"] as? String) == "audio" ? "audio" : "video",
                src: src,
                poster: map["poster"] as? String,
                placements: placements
            )
        }
        return catalog
    }

    private static func mediaForStep(
        catalog: [String: MediaCatalogEntry],
        slideIndex: Int,
        stepIndex: Int,
        visibleMediaIds: Any?,
        pageWidth: Double,
        pageHeight: Double,
        baseUrl: String?
    ) -> [MediaSlot]? {
        let ids = (visibleMediaIds as? [Any])?.compactMap { $0 as? String } ?? []
        var slots: [MediaSlot] = []
        let width = pageWidth > 0 ? pageWidth : 1
        let height = pageHeight > 0 ? pageHeight : 1
        for mediaId in ids {
            guard let entry = catalog[mediaId] else { continue }
            guard let placement = entry.placements.first(where: { item in
                guard (item["slideIndex"] as? NSNumber)?.intValue == slideIndex else { return false }
                let visible = item["visibleSteps"] as? [Any]
                if visible == nil || visible?.isEmpty == true { return true }
                return visible?.contains(where: { ($0 as? NSNumber)?.intValue == stepIndex }) == true
            }) else { continue }
            guard let url = resolveAssetUrl(entry.src, baseUrl: baseUrl) else { return nil }
            var poster: String?
            if let rawPoster = entry.poster {
                guard let resolved = resolveAssetUrl(rawPoster, baseUrl: baseUrl) else { return nil }
                poster = resolved
            }
            slots.append(
                MediaSlot(
                    mediaId: mediaId,
                    type: entry.type,
                    url: url,
                    rect: [
                        "x": ((placement["x"] as? NSNumber)?.doubleValue ?? 0) * width,
                        "y": ((placement["y"] as? NSNumber)?.doubleValue ?? 0) * height,
                        "width": ((placement["width"] as? NSNumber)?.doubleValue ?? 0) * width,
                        "height": ((placement["height"] as? NSNumber)?.doubleValue ?? 0) * height,
                    ],
                    poster: poster
                )
            )
        }
        return slots
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
