import Foundation

struct LicenseRuntimeBinding {
    var domain: String? = nil
    var androidPackage: String? = nil
    var iosBundleId: String? = nil
    var harmonyBundleName: String? = nil
    var desktopAppId: String? = nil
}

enum LicenseVerifyResult {
    case ok([String: Any])
    case err(code: String, message: String)
}

/// Offline license verification — policy in `drawskit-sdk-license` via FFI.
enum LicenseVerifier {
    static func verify(
        license: String?,
        appid: String,
        binding: LicenseRuntimeBinding,
        nowSec: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> LicenseVerifyResult {
        let input: [String: Any] = [
            "license": license as Any,
            "appid": appid,
            "binding": [
                "domain": binding.domain as Any,
                "androidPackage": binding.androidPackage as Any,
                "iosBundleId": binding.iosBundleId as Any,
                "harmonyBundleName": binding.harmonyBundleName as Any,
                "desktopAppId": binding.desktopAppId as Any,
            ],
            "keys": [[
                "kid": LicensePublicKeyGenerated.kid,
                "publicKeyHex": LicensePublicKeyGenerated.publicKeyHex,
            ]],
            "nowSec": nowSec,
        ]
        do {
            let json = try SyncPolicy.verifyLicenseJson(input)
            if json["ok"] as? Bool == true, let claims = json["claims"] as? [String: Any] {
                return .ok(claims)
            }
            return .err(
                code: json["code"] as? String ?? "malformed",
                message: json["message"] as? String ?? "license verify failed"
            )
        } catch {
            return .err(code: "crypto_unavailable", message: error.localizedDescription)
        }
    }
}
