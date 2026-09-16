import Foundation
import CryptoKit
import zlib

/// Cloud bootstrap workspace body: fetch `workspace_url`, verify SHA-256 of gzip bytes,
/// gunzip to WorkspaceExport JSON (same contract as sdk-api / smoke-room-persistence).
enum WorkspaceBlob {
    static let encodingGzip = "gzip"

    /// gzip member header ID1 / ID2 (RFC 1952).
    private static let gzipMagicId1: UInt8 = 0x1f
    private static let gzipMagicId2: UInt8 = 0x8b

    static func hydrateBootstrapPage(_ dict: [String: Any]) throws -> [String: Any] {
        var out = dict
        if let url = dict["workspace_url"] as? String, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out["workspace"] = try fetchWorkspaceFromSigned(dict)
            return out
        }
        if out["workspace"] == nil {
            out["workspace"] = NSNull()
        }
        return out
    }

    static func fetchWorkspaceFromSigned(_ payload: [String: Any]) throws -> [String: Any] {
        guard let urlString = payload["workspace_url"] as? String,
              !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: urlString)
        else {
            throw NSError(
                domain: "DrawsKit",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "missing workspace_url"]
            )
        }
        if let encoding = payload["workspace_encoding"] as? String,
           !encoding.isEmpty,
           encoding != encodingGzip
        {
            throw NSError(
                domain: "DrawsKit",
                code: 32,
                userInfo: [NSLocalizedDescriptionKey: "unexpected workspace_encoding=\(encoding)"]
            )
        }
        let body = try Data(contentsOf: url)
        let jsonData: Data
        if isGzipBytes(body) {
            if let checksum = payload["workspace_checksum"] as? String, !checksum.isEmpty {
                let actual = sha256Hex(body)
                if actual != checksum {
                    throw NSError(
                        domain: "DrawsKit",
                        code: 31,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "workspace checksum mismatch expected=\(checksum) actual=\(actual)",
                        ]
                    )
                }
            }
            jsonData = try gunzip(body)
        } else {
            // Transparent Content-Encoding decode: wire gzip checksum not applicable.
            jsonData = body
        }
        guard let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw NSError(
                domain: "DrawsKit",
                code: 33,
                userInfo: [NSLocalizedDescriptionKey: "workspace gzip JSON must be an object"]
            )
        }
        return object
    }

    private static func isGzipBytes(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[data.startIndex] == gzipMagicId1
            && data[data.index(after: data.startIndex)] == gzipMagicId2
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// inflateInit2 windowBits = 15 + 16 → gzip wrapper.
    private static func gunzip(_ data: Data) throws -> Data {
        let gzipWindowBits: Int32 = 15 + 16
        var stream = z_stream()
        var status = inflateInit2_(&stream, gzipWindowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw NSError(
                domain: "DrawsKit",
                code: 34,
                userInfo: [NSLocalizedDescriptionKey: "workspace gunzip init failed"]
            )
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        try data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) in
            guard let srcBase = srcRaw.bindMemory(to: Bytef.self).baseAddress else {
                throw NSError(
                    domain: "DrawsKit",
                    code: 34,
                    userInfo: [NSLocalizedDescriptionKey: "workspace gunzip empty input"]
                )
            }
            stream.next_in = UnsafeMutablePointer(mutating: srcBase)
            stream.avail_in = uInt(data.count)
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            repeat {
                try buffer.withUnsafeMutableBytes { dstRaw in
                    guard let dstBase = dstRaw.bindMemory(to: Bytef.self).baseAddress else {
                        throw NSError(
                            domain: "DrawsKit",
                            code: 34,
                            userInfo: [NSLocalizedDescriptionKey: "workspace gunzip buffer"]
                        )
                    }
                    stream.next_out = dstBase
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    if status != Z_OK && status != Z_STREAM_END {
                        throw NSError(
                            domain: "DrawsKit",
                            code: 34,
                            userInfo: [NSLocalizedDescriptionKey: "workspace gunzip failed status=\(status)"]
                        )
                    }
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        output.append(dstBase, count: produced)
                    }
                }
            } while status != Z_STREAM_END
        }
        return output
    }
}
