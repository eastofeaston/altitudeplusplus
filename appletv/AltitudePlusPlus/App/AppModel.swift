import AVFoundation
import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class AppModel {
    enum Phase {
        case launching
        case signedOut
        case ready
    }

    private(set) var phase: Phase = .launching
    private(set) var isStartingPlayback = false
    /// The video being started, so its card can show a spinner.
    private(set) var startingVideoId: String?
    /// Errors from starting or playing the 24/7 channel (shown on the Live tab).
    var playbackError: String?
    /// Errors from on-demand playback (shown as an alert on the team tabs).
    var onDemandError: String?

    private(set) var location: ResolvedLocation?
    private(set) var isLocating = false
    private(set) var lastEntitlement: JSON?
    private(set) var lastEntitlementDate: Date?
    private(set) var lastStreamURL: URL?

    var profile: DeviceProfile {
        didSet { UserDefaults.standard.set(profile.rawValue, forKey: "deviceProfile") }
    }

    var autoPlayOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoPlayOnLaunch, forKey: "autoPlayOnLaunch") }
    }

    /// Which team's tab comes first after Live.
    var favoriteTeam: Team {
        didSet { UserDefaults.standard.set(favoriteTeam.rawValue, forKey: "favoriteTeam") }
    }

    var orderedTeams: [Team] {
        [favoriteTeam] + Team.allCases.filter { $0 != favoriteTeam }
    }

    let guide = GuideStore()
    let onDemand = OnDemandStore()
    @ObservationIgnored let auth = AuthService()
    @ObservationIgnored let locationService = LocationService()
    @ObservationIgnored private let resolver = StreamResolver()
    @ObservationIgnored private var playback: PlayerSession?
    @ObservationIgnored private var hasAutoPlayed = false

    init() {
        let defaults = UserDefaults.standard
        profile = DeviceProfile(rawValue: defaults.string(forKey: "deviceProfile") ?? "") ?? .appleTV
        autoPlayOnLaunch = defaults.object(forKey: "autoPlayOnLaunch") as? Bool ?? true
        favoriteTeam = Team(rawValue: defaults.string(forKey: "favoriteTeam") ?? "") ?? .avalanche

        onDemand.authorization = { [weak self] in
            guard let self else { return nil }
            if let token = try? await self.auth.validAuthorization(profile: self.profile) { return token }
            return try? await self.auth.anonymousAuthorization(profile: self.profile)
        }
        onDemand.platform = { [weak self] in self?.profile.deviceType ?? DeviceProfile.appleTV.deviceType }
    }

    var session: UserSession? { auth.session }

    // MARK: Lifecycle

    func launch() async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #if DEBUG
        // Lets the home screen be laid out in the simulator without an account.
        if ProcessInfo.processInfo.arguments.contains("-previewHome") {
            if ProcessInfo.processInfo.arguments.contains("-previewError") {
                playbackError = "Preview error message, long enough to wrap onto a second line so the Live page is taller than the screen."
            }
            phase = .ready
            await guide.load()
            isLocating = true
            location = await locationService.resolve(token: try? await auth.anonymousAuthorization(profile: profile))
            isLocating = false
            return
        }
        #endif
        phase = auth.session == nil ? .signedOut : .ready
        #if DEBUG
        // `-playVideo <id>` starts an on-demand video instead of the live channel.
        let args = ProcessInfo.processInfo.arguments
        if phase == .ready, let index = args.firstIndex(of: "-playVideo"), index + 1 < args.count {
            hasAutoPlayed = true
            await play(VideoItem(id: args[index + 1], title: "Debug video"))
        }
        #endif
        async let guideLoad: Void = guide.load()
        if phase == .ready {
            await refreshLocation()
            await guideLoad
            await autoPlayIfNeeded()
        } else {
            await guideLoad
        }
    }

    func didSignIn() async {
        phase = .ready
        await refreshLocation()
        await autoPlayIfNeeded()
    }

    func signOut() {
        playback = nil
        auth.signOut(profile: profile)
        lastEntitlement = nil
        phase = .signedOut
    }

    func refreshLocation() async {
        isLocating = true
        defer { isLocating = false }
        locationService.invalidate()
        let token = try? await auth.validAuthorization(profile: profile)
        location = await locationService.resolve(token: token)
    }

    // MARK: Playback

    private func autoPlayIfNeeded() async {
        guard autoPlayOnLaunch, !hasAutoPlayed else { return }
        hasAutoPlayed = true
        await watchLive()
    }

    func watchLive() async {
        await startPlayback(.live(guide), resolve: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.resolveLiveSource()
        }, reportError: { [weak self] in self?.playbackError = $0 })
    }

    func play(_ video: VideoItem) async {
        startingVideoId = video.id
        defer { startingVideoId = nil }
        await startPlayback(.video(video), resolve: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.resolveVideoSource(video.id)
        }, reportError: { [weak self] in self?.onDemandError = $0 })
    }

    private func startPlayback(
        _ content: PlayerSession.Content,
        resolve: @escaping () async throws -> PlaybackSource,
        reportError: @escaping (String) -> Void
    ) async {
        guard !isStartingPlayback, playback == nil else { return }
        isStartingPlayback = true
        playbackError = nil
        onDemandError = nil
        defer { isStartingPlayback = false }

        do {
            let source = try await resolve()
            if source.fairPlay != nil, !FairPlayKeyDelivery.isSupported {
                throw ViewLiftError(message: "Altitude+ approved the stream, but FairPlay video only plays on a real Apple TV, not in the Simulator.")
            }
            let session = PlayerSession(
                content: content,
                resolveSource: resolve,
                onFinish: { [weak self] error in
                    self?.playback = nil
                    if let error, !(error is CancellationError) {
                        reportError(error.localizedDescription)
                    }
                }
            )
            guard let presenter = Self.topViewController() else {
                throw ViewLiftError(message: "Couldn't open the player.")
            }
            playback = session
            presenter.present(session.controller, animated: true)
            session.start(with: source)
        } catch let error as ViewLiftError where error.code == "SIGNED_OUT" {
            reportError(error.localizedDescription)
            phase = .signedOut
        } catch {
            reportError(error.localizedDescription)
        }
    }

    private func resolveLiveSource() async throws -> PlaybackSource {
        let token = try await auth.validAuthorization(profile: profile)
        let coordinate = await locationService.coordinates()
        let json = try await resolver.fetchLiveEntitlement(token: token, profile: profile, coordinate: coordinate)
        return try source(from: json)
    }

    private func resolveVideoSource(_ videoId: String) async throws -> PlaybackSource {
        let token = try await auth.validAuthorization(profile: profile)
        let coordinate = await locationService.coordinates()
        let json = try await resolver.fetchVideoEntitlement(videoId: videoId, token: token, profile: profile, coordinate: coordinate)
        return try source(from: json)
    }

    private func source(from json: JSON) throws -> PlaybackSource {
        lastEntitlement = json
        lastEntitlementDate = .now
        let source = try StreamResolver.source(from: json, profile: profile, deviceId: auth.deviceId)
        lastStreamURL = source.url
        return source
    }

    /// Fetches the entitlement response without starting playback, for Diagnostics.
    func probeEntitlement() async -> String {
        do {
            let source = try await resolveLiveSource()
            return source.fairPlay == nil ? "OK: unencrypted HLS stream" : "OK: FairPlay stream"
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
