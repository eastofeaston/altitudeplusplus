import Foundation

/// Static values for the Altitude+ tenant on the ViewLift platform.
///
/// Everything here is taken from the public altitudeplus.com web client
/// (`window.app_data`, `window.xApiKey`, and the `/live-24x7` page data).
enum AltitudeConfig {
    static let site = "altitude"
    static let apiBase = URL(string: "https://altitude.api.viewlift.com")!
    static let graphQL = apiBase.appendingPathComponent("graphql")

    /// Public API key the website sends as `x-api-key` on every request.
    static let apiKey = "WX41iaJiOw7hJW8sNbDP5JpVwmjaH6t6y3xbQUsc"

    /// The "24x7 FEED" linear channel (altitudeplus.com/live-24x7).
    static let liveContentId = "a6967d3f-2501-47f1-a7db-92faf7f6872f"
    static let liveChannelId = "de0a3981-03fa-4104-bf95-87735ebe4a8a"
    static let liveChannelTitle = "Altitude Sports"

    /// XMLTV guide for the live channel. Public, no auth required.
    static let epgURL = URL(string: "https://altitude-cached.api.viewlift.com/v4/content/epg/de0a3981-03fa-4104-bf95-87735ebe4a8a/tv.xml?meta=eyJmb3JtYXQiOiJHUkFDRU5PVEVfSlNPTiIsInNvdXJjZVVybCI6Imh0dHBzOi8vZGF0YS50bXNhcGkuY29tL3YxLjEvc3RhdGlvbnMvNjU1OTYvYWlyaW5ncz9hcGlfa2V5PWN4OWM4M2piNXp5enI2NzZxZW13Zm04eiJ9")!
}

/// How the app identifies itself to the entitlement service.
///
/// `appleTV` matches the official tvOS app. `web` mirrors Safari on
/// altitudeplus.com, which also receives FairPlay streams; it is a fallback
/// in case the account's plan or device registration rejects the TV profile.
enum DeviceProfile: String, CaseIterable, Identifiable {
    case appleTV
    case web

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleTV: return "Apple TV"
        case .web: return "Web browser"
        }
    }

    /// `EntitlementDevice` enum value used by GraphQL and `deviceType` query params.
    var deviceType: String {
        switch self {
        case .appleTV: return "ios_apple_tv"
        case .web: return "web_browser"
        }
    }

    /// `contentConsumption` query param on entitlement calls.
    var contentConsumption: String {
        switch self {
        case .appleTV: return "appleTv"
        case .web: return "web"
        }
    }
}
