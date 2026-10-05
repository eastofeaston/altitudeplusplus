import CoreLocation
import Foundation

struct FairPlayInfo: Equatable {
    var certificateURL: URL
    var licenseURL: URL
    var licenseToken: String?
}

struct PlaybackSource: Equatable {
    var url: URL
    var fairPlay: FairPlayInfo?
}

struct EntitlementError: LocalizedError {
    var code: String
    var serverMessage: String?

    var errorDescription: String? {
        let upper = code.uppercased()
        if upper.contains("GEO") || upper.contains("COUNTRY") || upper.contains("HBA") {
            return "Altitude+ says this location is outside its viewing territory. Check Settings → Location."
        }
        switch upper {
        case "SVOD_TVE_SUBSCRIPTION_NOT_FOUND", "SUBSCRIPTION_NOT_FOUND", "FORBIDDEN":
            return "This account doesn't have an active Altitude+ subscription."
        case "CANT_ACCESS_TVE_CONTENT":
            return "Your TV provider login doesn't include this channel."
        default:
            return serverMessage ?? "Altitude+ wouldn't start the stream (\(code))."
        }
    }
}

/// Turns ViewLift entitlement responses into something AVPlayer can play.
///
/// Live (`/v3/entitlement/linearchannel`) and on-demand (`/entitlement/video/status`)
/// responses share a shape: `<contentType>.streamingInfo.videoAssets`, where
/// `contentType` is `linearchannel` or `video`.
///
/// - DRM content (the live channel, full game replays) has one entry per DRM
///   system (`fairPlay`, `widevine`, `playReady`). The FairPlay entry has the HLS
///   `url`, a `certificateUrl`, ViewLift's license proxy `licenseUrl`
///   (`/v1/license/fairplay/acquire`, backed by Axinom), and a `licenseToken`
///   valid for about 12 hours across key rotations. Apple platforms use the
///   FairPlay entry, exactly like Safari on altitudeplus.com.
/// - Clips (recaps, features, news) are unencrypted, with a plain `hls` URL.
struct StreamResolver {
    private let client = ViewLiftClient()

    /// Requests the live channel entitlement. Errors in the body (subscription,
    /// territory) come back as JSON with an `errorCode`, so this only throws on
    /// transport failures.
    func fetchLiveEntitlement(
        token: String,
        profile: DeviceProfile,
        coordinate: CLLocationCoordinate2D?
    ) async throws -> JSON {
        var query: [String: String?] = [
            "id": AltitudeConfig.liveContentId,
            "channelId": AltitudeConfig.liveChannelId,
            "ssaiDisable": "false",
        ]
        query.merge(Self.deviceQuery(profile: profile, coordinate: coordinate)) { $1 }
        return try await client.get("v3/entitlement/linearchannel", query: query, token: token)
    }

    /// Requests playback for one on-demand video.
    func fetchVideoEntitlement(
        videoId: String,
        token: String,
        profile: DeviceProfile,
        coordinate: CLLocationCoordinate2D?
    ) async throws -> JSON {
        var query: [String: String?] = ["id": videoId]
        query.merge(Self.deviceQuery(profile: profile, coordinate: coordinate)) { $1 }
        return try await client.get("entitlement/video/status", query: query, token: token)
    }

    private static func deviceQuery(profile: DeviceProfile, coordinate: CLLocationCoordinate2D?) -> [String: String?] {
        [
            "deviceType": profile.deviceType,
            "contentConsumption": profile.contentConsumption,
            "latitude": coordinate.map { String($0.latitude) },
            "longitude": coordinate.map { String($0.longitude) },
        ]
    }

    static func source(from json: JSON, profile: DeviceProfile, deviceId: String) throws -> PlaybackSource {
        if let code = json["errorCode"]?.string ?? json["code"]?.string {
            throw EntitlementError(code: code, serverMessage: json["errorMessage"]?.string ?? json["message"]?.string)
        }
        // The playable assets live at `linearchannel.streamingInfo.videoAssets`
        // (the web player reads `response[contentType].streamingInfo`). Each entry
        // in `linearchannel.channels[]` carries a placeholder copy with blank
        // license URLs, so only fall back to a generic search if that path is missing.
        let contentType = json["linearchannel"] != nil ? "linearchannel" : (json["contentType"]?.string ?? "video")
        guard let assets = json[contentType]?["streamingInfo"]?["videoAssets"] ?? json.first("videoAssets") else {
            if json["playable"]?.bool == false {
                throw ViewLiftError(message: "Altitude+ says this video isn't available to play right now.")
            }
            throw ViewLiftError(message: "Altitude+ returned no stream for this video.")
        }

        let fairPlayEntry = [assets["fairPlayCmaf"], assets["fairPlay"]]
            .compactMap { $0 }
            .first { $0["url"]?.string != nil }

        if let entry = fairPlayEntry,
           let url = entry["url"]?.string.flatMap({ URL(string: expandMacros($0, deviceId: deviceId, profile: profile)) }),
           let certificate = entry["certificateUrl"]?.string.flatMap(URL.init(string:)),
           let license = entry["licenseUrl"]?.string.flatMap(URL.init(string:)) {
            let info = FairPlayInfo(certificateURL: certificate, licenseURL: license, licenseToken: entry["licenseToken"]?.string)
            return PlaybackSource(url: url, fairPlay: info)
        }

        let drmEnabled = json[contentType]?["drmEnabled"]?.bool ?? json.first("drmEnabled")?.bool ?? false
        if !drmEnabled,
           let hls = assets["hls"]?.string,
           let url = URL(string: expandMacros(hls, deviceId: deviceId, profile: profile)) {
            return PlaybackSource(url: url, fairPlay: nil)
        }

        throw ViewLiftError(message: "Altitude+ didn't offer a FairPlay stream for this device. Try Settings → Device profile → Web browser.")
    }

    /// The web player substitutes `VIEWLIFT_*` ad macros before loading a URL.
    /// Altitude+ has no ads configured, but fill the common ones in case they appear.
    static func expandMacros(_ url: String, deviceId: String, profile: DeviceProfile) -> String {
        guard url.contains("VIEWLIFT_") else { return url }
        let now = Date().timeIntervalSince1970
        let values: [String: String] = [
            "VIEWLIFT_CACHEBUSTER": String(Int(now)),
            "VIEWLIFT_TIMESTAMP": String(Int(now)),
            "VIEWLIFT_TIMESTAMP_MS": String(Int(now * 1000)),
            "VIEWLIFT_DEVICE_ID": deviceId,
            "VIEWLIFT_DID": deviceId,
            "VIEWLIFT_DEVICETYPE": profile.deviceType,
            "VIEWLIFT_WIDTH": "1920",
            "VIEWLIFT_HEIGHT": "1080",
            "VIEWLIFT_AUTOPLAY": "1",
            "VIEWLIFT_MUTE": "0",
            "VIEWLIFT_DNT": "1",
        ]
        var result = url
        for (macro, value) in values.sorted(by: { $0.key.count > $1.key.count }) {
            result = result.replacingOccurrences(of: macro, with: value)
        }
        // Blank any macro we don't know about rather than sending the placeholder.
        return result.replacingOccurrences(of: "VIEWLIFT_[A-Z0-9_]+", with: "", options: .regularExpression)
    }
}
