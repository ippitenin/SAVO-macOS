import SwiftUI

/// Карточка видео: обложка 16:9, название, канал и длительность.
struct VideoCardView: View {
    let info: VideoInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if !info.channelName.isEmpty {
                        Text(info.channelName)
                    }
                    if let duration = info.durationText {
                        if !info.channelName.isEmpty {
                            Text("·")
                        }
                        Text(duration)
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .padding(DS.Spacing.cardPadding)
        .glassSurface(shadow: true)
    }

    private var thumbnail: some View {
        AsyncImage(url: info.thumbnailURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    DS.plum.opacity(0.35)
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous))
    }
}
