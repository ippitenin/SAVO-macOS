import SwiftUI

extension View {
    /// Непрерывное «дыхание» SF Symbol внутри вью на macOS 15+, ниже — статично.
    /// Работает только с SF Symbols: на фигурах (Capsule и т.п.) эффекта нет.
    @ViewBuilder
    func dsBreathe() -> some View {
        if #available(macOS 15.0, *) {
            symbolEffect(.breathe)
        } else {
            self
        }
    }
}

extension View {
    /// Главная кнопка: сплошная капсула фирменной фуксии на всех версиях.
    /// НЕ `.glassProminent` с `.tint(DS.accent)`: стекло подмешивает к оттенку
    /// фон под кнопкой (цвет мутнеет), а на macOS 27 вдобавок теряется капсула
    /// (урок DOKA, коммит 190f4ce).
    func dsProminentButton() -> some View {
        buttonStyle(DSCapsuleButtonStyle(kind: .prominent))
    }

    /// Вторичная кнопка: та же капсула и те же размеры, что у главной, но с
    /// нейтральной полупрозрачной заливкой. Системный `.glass` выше главной
    /// кнопки — в одном ряду («Показать в Finder» · «Скачать ещё») это бросалось
    /// в глаза, а внутри стеклянной карточки давал «стекло на стекле».
    func dsGlassButton() -> some View {
        buttonStyle(DSCapsuleButtonStyle(kind: .secondary))
    }
}

/// Общий стиль капсульных кнопок: одна метрика на главную и вторичную, чтобы
/// в одном ряду они были ровно одной высоты. Учитывает `.controlSize`
/// (`.small`/`.mini` — компактная, `.large` — крупная, как у «Скачать»);
/// нажатие слегка темнит, наведение слегка высветляет, неактивная — полупрозрачная.
private struct DSCapsuleButtonStyle: ButtonStyle {
    enum Kind { case prominent, secondary }
    let kind: Kind

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovering = false

    private var isCompact: Bool { controlSize == .small || controlSize == .mini }
    private var isLarge: Bool { controlSize == .large || controlSize == .extraLarge }

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        configuration.label
            .font(isCompact ? .subheadline : nil)
            .foregroundStyle(foreground(role: configuration.role))
            .padding(.horizontal, isCompact ? 10 : (isLarge ? 18 : 14))
            .padding(.vertical, isCompact ? 3 : (isLarge ? 8 : 6))
            .background(
                shape
                    .fill(fill)
                    .brightness(configuration.isPressed ? -0.08 : (isHovering ? 0.04 : 0))
            )
            .overlay(shape.strokeBorder(stroke, lineWidth: kind == .prominent ? 0.5 : 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = $0 && isEnabled }
            .animation(DS.Anim.hover, value: isHovering)
    }

    private var fill: Color {
        switch kind {
        case .prominent: DS.accent
        case .secondary: Color.primary.opacity(isHovering ? 0.12 : 0.08)
        }
    }

    private var stroke: Color {
        switch kind {
        case .prominent: .white.opacity(0.18)
        case .secondary: Color.primary.opacity(0.10)
        }
    }

    /// Явный `.foregroundStyle` у лейбла всё равно побеждает: он стоит глубже
    /// по иерархии.
    private func foreground(role: ButtonRole?) -> Color {
        switch kind {
        case .prominent: .white
        case .secondary: role == .destructive ? .red : .primary
        }
    }
}
