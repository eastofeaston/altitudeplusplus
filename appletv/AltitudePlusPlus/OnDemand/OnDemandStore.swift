import Foundation
import Observation

enum Team: String, CaseIterable, Identifiable {
    case avalanche
    case nuggets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .avalanche: return "Avalanche"
        case .nuggets: return "Nuggets"
        }
    }

    /// Team page on altitudeplus.com.
    var path: String { "/\(rawValue)" }
}

struct VideoItem: Identifiable, Hashable {
    var id: String
    var title: String
    var summary: String?
    var imageURL: URL?
    /// Seconds.
    var runtime: Int?
    var published: Date?

    /// ViewLift's image CDN resizes on request; full-size stills are ~2x the bytes.
    var thumbnailURL: URL? {
        guard let imageURL, var components = URLComponents(url: imageURL, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "impolicy", value: "resize"), URLQueryItem(name: "w", value: "640")]
        return components.url
    }

    var durationText: String? {
        guard let runtime, runtime > 0 else { return nil }
        let hours = runtime / 3600, minutes = (runtime % 3600) / 60, seconds = runtime % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

struct ContentRow: Identifiable, Equatable {
    var id: String
    var title: String
    var items: [VideoItem]
    /// Cursor for the next page of this row, if there is one.
    var next: String?
}

/// On-demand rows for each team page (game replays, postgame, features, news),
/// fetched with the same GraphQL `page` query altitudeplus.com uses, trimmed to
/// the fields the TV app needs.
@Observable
@MainActor
final class OnDemandStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var rows: [Team: [ContentRow]] = [:]
    private(set) var states: [Team: LoadState] = [:]
    @ObservationIgnored private var loadingMore: Set<String> = []
    @ObservationIgnored private let client = ViewLiftClient()
    /// Supplies the token for page requests (user token if signed in, else anonymous).
    @ObservationIgnored var authorization: () async -> String? = { nil }
    /// `EntitlementDevice` value for the current device profile.
    @ObservationIgnored var platform: () -> String = { DeviceProfile.appleTV.deviceType }

    func state(for team: Team) -> LoadState { states[team] ?? .idle }

    func loadIfNeeded(_ team: Team) async {
        switch state(for: team) {
        case .idle, .failed: await load(team)
        case .loading, .loaded: break
        }
    }

    func load(_ team: Team) async {
        states[team] = .loading
        do {
            let modules = try await fetchModules(path: team.path, moduleIds: nil, next: nil)
            var result: [ContentRow] = []
            for module in modules {
                guard var row = Self.row(from: module) else { continue }
                if row.title.isEmpty { row.title = result.isEmpty ? "Latest" : "More" }
                result.append(row)
            }
            rows[team] = result
            states[team] = .loaded
        } catch {
            states[team] = .failed(error.localizedDescription)
        }
    }

    /// Appends the next page of a row. Safe to call repeatedly while scrolling.
    func loadMore(rowId: String, team: Team) async {
        guard let index = rows[team]?.firstIndex(where: { $0.id == rowId }),
              let cursor = rows[team]?[index].next,
              !loadingMore.contains(rowId) else { return }
        loadingMore.insert(rowId)
        defer { loadingMore.remove(rowId) }

        guard let module = try? await fetchModules(path: team.path, moduleIds: [rowId], next: cursor).first,
              let page = Self.row(from: module, keepEmpty: true),
              var row = rows[team]?.first(where: { $0.id == rowId }) else { return }
        let known = Set(row.items.map(\.id))
        row.items += page.items.filter { !known.contains($0.id) }
        // Stop if the server repeats a cursor or returns nothing new.
        row.next = (page.next == cursor || page.items.isEmpty) ? nil : page.next
        if let current = rows[team]?.firstIndex(where: { $0.id == rowId }) {
            rows[team]?[current] = row
        }
    }

    // MARK: Fetching

    private static let query = """
    query ($site: String!, $path: String, $device: Device!, $moduleLimit: Int, $moduleOffset: Int, $countryCode: String,
           $platform: EntitlementDevice, $modules: [String!], $next: String) {
      page(site: $site, path: $path, device: $device, includeContent: true, moduleLimit: $moduleLimit,
           moduleOffset: $moduleOffset, countryCode: $countryCode, platform: $platform, modules: $modules, next: $next) {
        modules {
          id
          moduleType
          ... on CuratedTrayModule { title contentData { ...Item } }
          ... on GeneratedTrayModule { title next contentData { ...Item } }
        }
      }
    }
    fragment Item on Content {
      id
      gist { id title contentType description imageGist { r16x9 } }
      ... on Video { publishDate runtime }
    }
    """

    private func fetchModules(path: String, moduleIds: [String]?, next: String?) async throws -> [JSON] {
        var variables: [String: Any] = [
            "site": AltitudeConfig.site,
            "path": path,
            "device": "APPLETV",
            "moduleLimit": moduleIds == nil ? 30 : 1,
            "moduleOffset": 0,
            "countryCode": "US",
            "platform": platform(),
        ]
        if let moduleIds { variables["modules"] = moduleIds }
        if let next { variables["next"] = next }
        let token = await authorization()
        let data = try await client.graphQL(Self.query, variables: variables, token: token)
        return data["page"]?["modules"]?.array ?? []
    }

    /// Video rows only: games, articles, and talent categories are skipped.
    private static func row(from module: JSON, keepEmpty: Bool = false) -> ContentRow? {
        guard let id = module["id"]?.string, let content = module["contentData"]?.array else { return nil }
        let items = content.compactMap(videoItem(from:))
        guard keepEmpty || !items.isEmpty else { return nil }
        return ContentRow(id: id, title: module["title"]?.string ?? "", items: items, next: module["next"]?.string)
    }

    private static func videoItem(from content: JSON) -> VideoItem? {
        guard let gist = content["gist"], gist["contentType"]?.string == "VIDEO",
              let id = gist["id"]?.string ?? content["id"]?.string,
              let title = gist["title"]?.string else { return nil }
        return VideoItem(
            id: id,
            title: title,
            summary: gist["description"]?.string,
            imageURL: gist["imageGist"]?["r16x9"]?.string.flatMap(URL.init(string:)),
            runtime: content["runtime"]?.double.map { Int($0) },
            published: content["publishDate"]?.double.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
        )
    }
}
