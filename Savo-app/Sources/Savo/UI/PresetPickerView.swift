import SwiftUI

/// Категории пресетов: видео со звуком, только аудио, видео без звука.
enum PresetCategory: String, CaseIterable, Identifiable {
    case video, audio, muted
    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return L("category.video")
        case .audio: return L("category.audio")
        case .muted: return L("category.muted")
        }
    }
}

/// Выбор качества: сегменты категорий, варианты выбранной категории
/// и главная кнопка «Скачать».
struct PresetPickerView: View {
    let info: VideoInfo
    let onDownload: (DownloadPreset) -> Void

    @State private var category: PresetCategory = .video
    @State private var selected: DownloadPreset?
    /// Варианты всех категорий считаются один раз. Вычисляемое свойство
    /// заставляло PresetBuilder перебирать все форматы ролика на каждую
    /// перерисовку — включая анимацию выбора варианта.
    @State private var presetsByCategory: [PresetCategory: [DownloadPreset]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $category) {
                ForEach(PresetCategory.allCases) { cat in
                    Text(cat.title).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if presets.isEmpty {
                // Пустой список раньше молча подставлял аудио — на вкладке
                // «Видео» это скачивало звук вместо видео, ничего не сказав.
                Text(L("preset.noVariants"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 4) {
                    ForEach(presets) { preset in
                        presetRow(preset)
                    }
                }
            }

            ForEach(notices, id: \.self) { notice in
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                if let selection = currentSelection { onDownload(selection) }
            } label: {
                Label(L("action.download"), systemImage: "arrow.down.circle.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .dsProminentButton()
            .controlSize(.large)
            .disabled(currentSelection == nil)
        }
        .padding(DS.Spacing.cardPadding)
        // Материал: высокая карточка прямо под обложкой видео — Liquid Glass
        // у кромок отражал бы её (урок DOKA про высокие карточки).
        .glassSurface(forceMaterial: true)
        .onAppear(perform: buildPresets)
        .onChange(of: category) { _, _ in
            selected = PresetBuilder.defaultPreset(from: presets)
        }
    }

    /// Разовый расчёт вариантов для всех трёх категорий.
    private func buildPresets() {
        guard presetsByCategory.isEmpty else { return }
        presetsByCategory = [
            .video: PresetBuilder.videoPresets(for: info),
            .audio: PresetBuilder.audioPresets(for: info),
            .muted: PresetBuilder.videoOnlyPresets(for: info)
        ]
        selected = PresetBuilder.defaultPreset(from: presetsByCategory[category] ?? [])
    }

    /// Варианты текущей категории.
    private var presets: [DownloadPreset] {
        presetsByCategory[category] ?? []
    }

    /// Выбранный вариант; по умолчанию — максимальный совместимый.
    private var currentSelection: DownloadPreset? {
        if let selected, presets.contains(selected) { return selected }
        return PresetBuilder.defaultPreset(from: presets)
    }

    /// Пояснения под списком: чем грозит выбранный вариант и почему
    /// качество может быть ниже ожидаемого.
    private var notices: [String] {
        guard let selection = currentSelection else { return [] }
        var result: [String] = []
        if let warning = selection.warning {
            result.append(warning)
        }
        // Ступени YouTube, а не высоты кадра: у кадра 2:1 «1080p» — это 960 px.
        guard let selectedTier = selection.qualityTier,
              let topTier = presets.compactMap(\.qualityTier).max() else {
            return result
        }
        if selectedTier < topTier {
            // Не максимум выбрало само приложение — обязано объяснить почему.
            // Ручной выбор пользователя в пояснениях не нуждается.
            if selection == PresetBuilder.defaultPreset(from: presets) {
                result.append(L("preset.loweredForCompat", selectedTier, topTier))
            }
        } else if topTier < 1080 {
            // Максимум взят, но сам ролик выше не публиковался.
            result.append(L("preset.maxAvailable", topTier))
        }
        return result
    }

    private func presetRow(_ preset: DownloadPreset) -> some View {
        let isSelected = preset == currentSelection
        return Button {
            withAnimation(DS.Anim.control) { selected = preset }
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? DS.accent : Color.secondary)
                Text(preset.label)
                    .fontWeight(isSelected ? .semibold : .regular)
                // Жёлтая метка у вариантов, которые не откроются в QuickTime.
                if !preset.quickTimeReady {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DS.marker)
                }
                Spacer()
                Text(preset.sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? DS.accent.opacity(0.14) : .clear)
            )
        }
        .buttonStyle(.plain)
        // Без синего кольца фокуса: выбор уже подсвечен капсулой.
        .focusEffectDisabled()
    }
}
