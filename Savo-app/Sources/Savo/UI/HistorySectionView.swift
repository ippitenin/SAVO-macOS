import AppKit
import SwiftUI

/// Секция «История» под hero-зоной: последние скачивания с быстрым
/// «Показать в Finder». Пустая история — секции нет.
struct HistorySectionView: View {
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        if !history.records.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("history.title"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("history.clear")) {
                        history.clear()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .focusEffectDisabled()
                }
                .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    ForEach(history.records.prefix(20)) { record in
                        HistoryRow(record: record)
                        if record.id != history.records.prefix(20).last?.id {
                            CardDivider()
                        }
                    }
                }
                .padding(.vertical, 4)
                // Материал, а не Liquid Glass: высокая карточка (до 20 строк)
                // в ScrollView на macOS 26+ получала серую плиту на весь
                // viewport и отражала соседей у кромок (уроки DOKA).
                .glassSurface(forceMaterial: true)
            }
        }
    }
}

/// Строка истории: мини-обложка, название, пресет и дата.
private struct HistoryRow: View {
    let record: DownloadRecord
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if record.fileExists {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: record.filePath)]
                    )
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovering ? DS.accent : Color.secondary)
                .focusEffectDisabled()
                .help(L("done.showInFinder"))
            }
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if record.fileExists {
                Button(L("done.showInFinder")) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: record.filePath)]
                    )
                }
            }
            Button(L("history.delete"), role: .destructive) {
                HistoryStore.shared.delete(record)
            }
        }
    }

    private var subtitle: String {
        var parts = [record.presetLabel]
        if let size = record.fileSizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        parts.append(record.date.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private var thumbnail: some View {
        AsyncImage(url: record.thumbnailURL.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                DS.plum.opacity(0.3)
            }
        }
        .frame(width: 56, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
