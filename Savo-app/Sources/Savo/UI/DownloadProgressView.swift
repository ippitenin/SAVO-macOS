import SwiftUI

/// Прогресс загрузки: полоса с фирменной жёлтой риской, проценты,
/// скорость, оставшееся время, этап и кнопка отмены.
struct DownloadProgressView: View {
    let progress: DownloadProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if progress.merging {
                mergingRow
            } else {
                progressBar
                statsRow
            }
            Button(L("action.cancel")) {
                onCancel()
            }
            .dsGlassButton()
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.cardPadding + 8)
        .glassSurface()
    }

    private var progressBar: some View {
        VStack(spacing: 8) {
            if progress.phaseCount > 1 {
                Text(L("progress.phase", progress.phase, progress.phaseCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GeometryReader { geo in
                let fraction = progress.fraction
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(DS.plum.opacity(0.25))
                    if let fraction {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [DS.rose, DS.accent],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: max(10, geo.size.width * fraction))
                        // Фирменная жёлтая риска на фронте прогресса,
                        // как индикатор слайдера в референсе.
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(DS.marker)
                            .frame(width: 3, height: 18)
                            .offset(x: max(10, geo.size.width * fraction) - 1.5)
                    } else {
                        // Неопределённый прогресс: мягкая пульсация полосы.
                        IndeterminateBar()
                    }
                }
            }
            .frame(height: 12)
            .animation(DS.Anim.control, value: progress.fraction)
        }
    }

    private var statsRow: some View {
        HStack {
            Text(percentText)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let speed = progress.speed, speed > 0 {
                    Text(L("progress.speed", ByteCountFormatter.string(
                        fromByteCount: Int64(speed), countStyle: .file)))
                }
                if let eta = progress.eta, eta > 0 {
                    Text(L("progress.eta", etaText(eta)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private var mergingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(L("progress.merging"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var percentText: String {
        guard let fraction = progress.fraction else { return "…" }
        return String(format: "%.0f%%", fraction * 100)
    }

    /// «12:34» или «1:02:03» из секунд.
    private func etaText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

/// Полоса неопределённого прогресса: мягко «дышит» прозрачностью.
/// dsBreathe здесь не годится — symbolEffect работает только с SF Symbols,
/// на Capsule полоса стояла статично. Reduce Motion — без пульсации.
private struct IndeterminateBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(DS.accent.opacity(0.45))
            .opacity(dimmed ? 0.4 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(DS.Anim.pulse) { dimmed = true }
            }
    }
}
