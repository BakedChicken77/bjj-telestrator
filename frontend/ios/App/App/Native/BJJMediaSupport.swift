import Foundation

/// Only parsed, bounded facts cross the inspection boundary. No atom bytes or URLs.
struct BJJMediaDescriptor: Codable, Equatable {
    var codec: String
    var transfer: String
    var primaries: String
    var matrix: String
    var dolbyVision: Bool
    var dolbyProfile: Int?
    var dolbyLevel: Int?
    var compatibilityID: Int?
    var baseLayer: Bool?
    var enhancementLayer: Bool?
    var rpu: Bool?
    var bitDepth: Int?
    var durationSec: Double?
    var width: Int?
    var height: Int?
    var rejectionReason: String?
    var route: String { rejectionReason != nil ? "unsupported" : dolbyVision ? "dolby84_to_sdr" : BJJMediaSupport.hdrTransfers.contains(transfer) ? "hdr_to_sdr" : "native_sdr" }
    var decision: String { rejectionReason == nil ? "supported" : "rejected" }
}

enum BJJMediaSupport {
    static let capability = "media.dolby84-to-sdr.v1"
    static let version = "native-media-v1"
    static let hdrTransfers = ["smpte2084", "arib-std-b67"]
    // A rollback can disable NEW Dolby imports while retained projects remain usable.
    static var dolbyImportsEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "BJJDolbyImportsEnabled") as? Bool ?? true
    }
    static func describe(codec: String, atoms: [String: Any], transfer: String, primaries: String, matrix: String) -> BJJMediaDescriptor {
        let signalled = atoms["dvcC"] != nil || atoms["dvvC"] != nil || ["dvh1", "dvhe"].contains(codec)
        var result = BJJMediaDescriptor(codec: String(codec.prefix(4)),
            transfer: (["bt709", "smpte2084", "arib-std-b67"].contains(transfer) ? transfer : "unknown"),
            primaries: (["bt709", "bt2020"].contains(primaries) ? primaries : "unknown"),
            matrix: (["bt709", "bt2020nc"].contains(matrix) ? matrix : "unknown"), dolbyVision: signalled)
        if let hvc = atoms["hvcC"] as? Data, hvc.count >= 23 {
            result.bitDepth = 8 + Int(hvc[hvc.startIndex + 17] & 7)
        }
        guard signalled else { return result }
        // Dolby configuration version 1.0 has a fixed 24-byte payload. Never
        // interpret a truncated record, unknown version, or contradictory records.
        let records = ["dvcC", "dvvC"].compactMap { atoms[$0] as? Data }
        guard !records.isEmpty, records.count == ["dvcC", "dvvC"].filter({ atoms[$0] != nil }).count,
              records.allSatisfy({ $0 == records[0] }), records[0].count == 24 else {
            result.rejectionReason = "dolby_configuration_missing_or_malformed"; return result
        }
        let bytes = Array(records[0])
        guard bytes[0] == 1, bytes[1] == 0 else {
            result.rejectionReason = "dolby_configuration_version"; return result
        }
        result.dolbyProfile = Int(bytes[2] >> 1)
        result.dolbyLevel = Int((bytes[2] & 1) << 5 | bytes[3] >> 3)
        result.rpu = bytes[3] & 4 != 0
        result.enhancementLayer = bytes[3] & 2 != 0
        result.baseLayer = bytes[3] & 1 != 0
        result.compatibilityID = Int(bytes[4] >> 4)
        guard result.dolbyProfile == 8, result.compatibilityID == 4,
              result.baseLayer == true, result.enhancementLayer == false, result.rpu == true else {
            result.rejectionReason = "dolby_profile_not_qualified"; return result
        }
        guard ["hvc1", "hev1", "dvh1", "dvhe"].contains(codec), result.bitDepth == 10,
              transfer == "arib-std-b67", primaries == "bt2020", matrix == "bt2020nc" else {
            result.rejectionReason = "dolby84_base_layer_metadata"; return result
        }
        return result
    }
    static func require(_ descriptor: BJJMediaDescriptor) throws {
        if descriptor.rejectionReason == "mixed_sample_descriptions" {
            throw BJJError.domain("MEDIA_UNSUPPORTED", "This video changes format within its video track. Choose a complete, consistent copy or share diagnostics. Your original was not changed.")
        }
        guard descriptor.rejectionReason == nil else {
            throw BJJError.domain("MEDIA_DOLBY_UNSUPPORTED", "This Dolby Vision profile cannot be prepared safely yet. Choose a compatible copy from Photos and select the same video there. Photos may take time to prepare it. If that also fails, choose an SDR copy and share diagnostics. Your original video was not changed.")
        }
    }
    static func capabilities(_ media: BJJJSON) -> [String] {
        (BJJColor.isHDR(media) ? [BJJColor.capability] : []) + (media["dolbyVision"] as? Bool == true ? [capability] : [])
    }
    static func validateSavedSource(_ media: BJJJSON, capabilities: [String]) throws {
        if media["dolbyVision"] as? Bool == true {
            guard capabilities.contains(capability), media["dolbyProfile"] as? Int == 8,
                  media["dolbyCompatibilityID"] as? Int == 4, media["dolbyBaseLayer"] as? Bool == true,
                  media["dolbyEnhancementLayer"] as? Bool == false, media["dolbyRPU"] as? Bool == true,
                  media["bitDepth"] as? Int == 10, media["transferFunction"] as? String == "arib-std-b67",
                  media["colorPrimaries"] as? String == "bt2020", media["colorMatrix"] as? String == "bt2020nc" else {
                throw BJJError.domain("CAPABILITY_UNSUPPORTED", "This review needs a supported Dolby Vision decoder. Update Fresh Frame; the saved review is unchanged.")
            }
        } else if capabilities.contains(capability) {
            throw BJJError.invalid("The Dolby Vision source metadata is missing.")
        }
    }
}
