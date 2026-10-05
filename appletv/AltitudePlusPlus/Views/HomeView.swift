import SwiftUI

/// One screen: what's on now, a big Watch Live button, and what's next.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var watchLiveFocused: Bool
    private let topID = "top"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = model.guide.program(at: context.date)
            // A scroll view gets the tab bar and overscan insets automatically,
            // and lets the page grow when an error message is showing.
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 36) {
                        hero(now: now, date: context.date)
                        upNext(after: context.date)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollClipDisabled()
                // tvOS only brings the tab bar back when the page is scrolled to
                // the top, and nothing above Watch Live can take focus. If the
                // page is taller than the screen, returning from Up Next would
                // leave it part-scrolled and the tab bar unreachable.
                .onChange(of: watchLiveFocused) { _, focused in
                    if focused {
                        withAnimation { proxy.scrollTo(topID, anchor: .top) }
                    }
                }
            }
            .background(alignment: .topTrailing) { backdrop(for: now) }
        }
        .task { await model.guide.loadIfStale() }
    }

    private func hero(now: Program?, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Text("LIVE")
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.red, in: Capsule())
                Text(AltitudeConfig.liveChannelTitle.uppercased() + " · 24/7")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .id(topID)

            Text(now?.title ?? "Altitude Sports Live")
                .font(.system(size: 54, weight: .bold))
                .lineLimit(2)

            if let now {
                Text([now.subtitle, now.timeRange].compactMap { $0 }.joined(separator: " · "))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                ProgressView(value: date.timeIntervalSince(now.start), total: now.end.timeIntervalSince(now.start))
                    .tint(Theme.accent)
                    .frame(width: 600)
                if let summary = now.summary {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }

            HStack(spacing: 30) {
                Button {
                    Task { await model.watchLive() }
                } label: {
                    HStack(spacing: 16) {
                        if model.isStartingPlayback, model.startingVideoId == nil {
                            ProgressView()
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(model.isStartingPlayback && model.startingVideoId == nil ? "Starting…" : "Watch Live")
                    }
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 320)
                }
                .focused($watchLiveFocused)
                // Not disabled while starting: a disabled button loses tvOS focus.
                // watchLive() already ignores repeat presses.
            }
            .padding(.top, 10)

            if let error = model.playbackError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 1200, alignment: .leading)
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private func upNext(after date: Date) -> some View {
        let programs = model.guide.upcoming(after: date, limit: 10)
        if !programs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Up Next")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 40) {
                        ForEach(programs) { program in
                            ProgramCard(program: program)
                        }
                    }
                    .padding(.vertical, 24)
                }
                .scrollClipDisabled()
                .fixedSize(horizontal: false, vertical: true)
            }
            .focusSection()
        }
    }

    @ViewBuilder
    private func backdrop(for program: Program?) -> some View {
        if let url = program?.imageURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.clear
            }
            .frame(width: 1100, height: 620)
            .clipped()
            .mask(
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

private struct ProgramCard: View {
    let program: Program

    var body: some View {
        Button {} label: {
            VStack(alignment: .leading, spacing: 0) {
                AsyncImage(url: program.imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.white.opacity(0.06))
                }
                .frame(width: 360, height: 203)
                .clipped()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(program.start.formatted(date: .omitted, time: .shortened))
                        if program.isGame {
                            Text("GAME")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(program.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2, reservesSpace: true)
                }
                .padding(16)
                .frame(width: 360, alignment: .leading)
            }
        }
        .buttonStyle(.card)
    }
}
