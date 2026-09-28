import AppKit
import SwiftUI

/// Финальная панель: галочка, имя файла, «Показать в Finder» и «Скачать ещё».
struct DonePanelView: View {
    let filePath: String
    let info: VideoInfo
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            VStack(spacing: 4) {
                Text(L("done.title"))
                    .font(.headline)
                Text((filePath as NSString).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: filePath)]
                    )
                } label: {
                    Label(L("done.showInFinder"), systemImage: "folder")
                }
                .dsProminentButton()
                Button(L("done.downloadMore")) {
                    onReset()
                }
                .dsGlassButton()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.cardPadding + 8)
        .glassSurface(shadow: true)
    }
}
