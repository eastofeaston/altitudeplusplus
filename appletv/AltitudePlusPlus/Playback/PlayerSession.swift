import AVKit
import SwiftUI
import UIKit

/// Owns one full-screen playback session (the 24/7 channel or an on-demand
/// video): the AVPlayerViewController, the FairPlay key session, info-panel
/// metadata, and automatic recovery.
@MainActor
final class PlayerSession: NSObject, AVPlayerViewControllerDelegate {
    enum Content {
        case live(GuideStore)
        case video(VideoItem)
    }

    let controller = AVPlayerViewController()
    private let player = AVPlayer()
    private let content: Content
    private let resolveSource: () async throws -> PlaybackSource
    private let onFinish: (Error?) -> Void

    private var keyDelivery: FairPlayKeyDelivery?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var metadataTask: Task<Void, Never>?
    /// Bumped on every load so failures from a replaced item or key session are ignored.
    private var generation = 0
    private var isRecovering = false
    private var lastRecovery: Date?
    private var finished = false

    init(content: Content,
         resolveSource: @escaping () async throws -> PlaybackSource,
         onFinish: @escaping (Error?) -> Void) {
        self.content = content
        self.resolveSource = resolveSource
        self.onFinish = onFinish
        super.init()

        controller.player = player
        controller.delegate = self
        if case .live(let guide) = content {
            let upNext = UIHostingController(rootView: UpNextPanel(guide: guide))
            upNext.title = "Up Next"
            upNext.preferredContentSize = CGSize(width: 0, height: 420)
            controller.customInfoViewControllers = [upNext]
        }
    }

    func start(with source: PlaybackSource) {
        load(source)
        player.play()
        scheduleMetadataUpdates()
    }

    private func load(_ source: PlaybackSource, resumeAt resumeTime: CMTime? = nil) {
        generation += 1
        let loadGeneration = generation
        let asset = AVURLAsset(url: source.url)
        if let fairPlay = source.fairPlay {
            guard FairPlayKeyDelivery.isSupported else {
                finish(ViewLiftError(message: "FairPlay video only plays on a real Apple TV."))
                return
            }
            let delivery = FairPlayKeyDelivery(info: fairPlay)
            delivery.onFailure = { [weak self] error in self?.handleFailure(error, generation: loadGeneration) }
            delivery.attach(to: asset)
            keyDelivery = delivery
        } else {
            keyDelivery = nil
        }

        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = currentMetadata()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let error = item.error
            Task { @MainActor in self?.handleFailure(error, generation: loadGeneration) }
        }
        if case .video = content {
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.finish(nil) }
            }
        }
        player.replaceCurrentItem(with: item)
        if let resumeTime, resumeTime.isValid, resumeTime.seconds > 1 {
            player.seek(to: resumeTime)
        }
    }

    /// Streams can fail when the license token or session expires.
    /// Re-resolve (fresh token, fresh license) and reload, resuming on-demand
    /// video where it stopped. A key failure and the item failure usually arrive
    /// together, so one recovery covers both. If a fresh stream fails again
    /// within a minute, give up and show the error.
    private func handleFailure(_ error: Error?, generation failedGeneration: Int) {
        guard !finished, !isRecovering, failedGeneration == generation else { return }
        if let lastRecovery, lastRecovery.timeIntervalSinceNow > -60 {
            finish(error ?? ViewLiftError(message: "Playback stopped unexpectedly."))
            return
        }
        isRecovering = true
        lastRecovery = .now
        let position: CMTime? = if case .video = content { player.currentTime() } else { nil }
        Task {
            defer { isRecovering = false }
            do {
                let source = try await resolveSource()
                guard !finished else { return }
                load(source, resumeAt: position)
                player.play()
            } catch {
                finish(error)
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        metadataTask?.cancel()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        keyDelivery = nil
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true) { [onFinish] in onFinish(error) }
        } else {
            onFinish(error)
        }
    }

    // MARK: Info panel metadata

    private func currentMetadata(artwork: Data? = nil) -> [AVMetadataItem] {
        switch content {
        case .live(let guide):
            let program = guide.program()
            return metadata(
                title: program?.title ?? AltitudeConfig.liveChannelTitle,
                subtitle: program.map { "\(AltitudeConfig.liveChannelTitle) · \($0.timeRange)" },
                description: program?.subtitle ?? program?.summary,
                artwork: artwork
            )
        case .video(let video):
            return metadata(
                title: video.title,
                subtitle: video.published?.formatted(date: .abbreviated, time: .omitted),
                description: video.summary,
                artwork: artwork
            )
        }
    }

    private func scheduleMetadataUpdates() {
        metadataTask?.cancel()
        switch content {
        case .video(let video):
            metadataTask = Task { [weak self] in
                guard let url = video.thumbnailURL,
                      let (data, _) = try? await URLSession.shared.data(from: url),
                      let self, !Task.isCancelled else { return }
                self.player.currentItem?.externalMetadata = self.currentMetadata(artwork: data)
            }
        case .live(let guide):
            // Follow the guide: refresh the title and artwork as programs change.
            metadataTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await guide.loadIfStale()
                    let now = guide.program()
                    self.player.currentItem?.externalMetadata = self.currentMetadata()
                    if let url = now?.imageURL,
                       let (data, _) = try? await URLSession.shared.data(from: url),
                       now == guide.program() {
                        self.player.currentItem?.externalMetadata = self.currentMetadata(artwork: data)
                    }
                    let wake = now?.end.timeIntervalSinceNow ?? 300
                    try? await Task.sleep(for: .seconds(max(30, min(wake + 5, 1800))))
                }
            }
        }
    }

    private func metadata(title: String, subtitle: String?, description: String?, artwork: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        add(.commonIdentifierTitle, title as NSString)
        add(.iTunesMetadataTrackSubTitle, subtitle.map { $0 as NSString })
        add(.commonIdentifierDescription, description.map { $0 as NSString })
        if let artwork {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtwork
            item.value = artwork as NSData
            item.dataType = kCMMetadataBaseDataType_JPEG as String
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        return items
    }

    // MARK: AVPlayerViewControllerDelegate

    nonisolated func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor in self.finish(nil) }
    }
}

/// Shown in the swipe-down info panel while watching.
private struct UpNextPanel: View {
    let guide: GuideStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 40) {
                    ForEach(guide.upcoming(after: context.date, limit: 6)) { program in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(program.start.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(program.title)
                                .font(.headline)
                                .lineLimit(2)
                            if let subtitle = program.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(width: 360, alignment: .leading)
                        .padding(24)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .focusable()
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
        }
    }
}
