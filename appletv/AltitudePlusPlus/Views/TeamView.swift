import SwiftUI

/// On-demand rows for one team: replays, postgame, features, news.
struct TeamView: View {
    let team: Team
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let store = model.onDemand

        Group {
            switch store.state(for: team) {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 30) {
                    Text("Couldn't load \(team.title) videos")
                        .font(.title3.weight(.semibold))
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await store.load(team) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 44) {
                        ForEach(store.rows[team] ?? []) { row in
                            RowView(team: team, row: row)
                        }
                    }
                    .padding(.vertical, 30)
                }
                .scrollClipDisabled()
            }
        }
        .task { await store.loadIfNeeded(team) }
        .alert(
            "Can't Play Video",
            isPresented: Binding(
                get: { model.onDemandError != nil },
                set: { if !$0 { model.onDemandError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(model.onDemandError ?? "") }
        )
    }
}

private struct RowView: View {
    let team: Team
    let row: ContentRow
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(.headline)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 40) {
                    ForEach(Array(row.items.enumerated()), id: \.element.id) { index, video in
                        VideoCard(video: video, isStarting: model.startingVideoId == video.id) {
                            Task { await model.play(video) }
                        }
                        .onAppear {
                            // Fetch the next page as the end of the row comes into view.
                            if index >= row.items.count - 3, row.next != nil {
                                Task { await model.onDemand.loadMore(rowId: row.id, team: team) }
                            }
                        }
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

private struct VideoCard: View {
    let video: VideoItem
    let isStarting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                AsyncImage(url: video.thumbnailURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.white.opacity(0.06))
                }
                .frame(width: 400, height: 225)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if let duration = video.durationText {
                        Text(duration)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                            .padding(10)
                    }
                }
                .overlay {
                    if isStarting {
                        ZStack {
                            Color.black.opacity(0.5)
                            ProgressView()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let published = video.published {
                        Text(published.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(video.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2, reservesSpace: true)
                }
                .padding(16)
                .frame(width: 400, alignment: .leading)
            }
        }
        .buttonStyle(.card)
    }
}
