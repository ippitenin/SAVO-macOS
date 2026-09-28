import SwiftUI

/// Дизайн-токены Savo: единственный источник правды для цветов, радиусов,
/// отступов и анимаций. Палитра — по референсу пользователя: многослойный
/// розовый градиент от глубокой сливы до блеклого небесно-розового.
enum DS {
    /// Фирменный акцент: фуксия (#E0338F). Главные кнопки, выделение, тинты.
    static let accent = Color(red: 0.88, green: 0.20, blue: 0.56)

    /// Цвет свечений фона: тёплая маджента, чуть светлее акцента (#E84F9E).
    static let glow = Color(red: 0.91, green: 0.31, blue: 0.62)

    /// Глубокая слива — тёмное ядро градиента (#4A1042).
    /// Тёмные подложки, ядро mesh-фона.
    static let plum = Color(red: 0.29, green: 0.06, blue: 0.26)

    /// Пыльно-розовый — мягкий вторичный тон (#E58BC0).
    static let rose = Color(red: 0.90, green: 0.55, blue: 0.75)

    /// Фирменная жёлтая риска (#F4D03F) — метка на прогресс-баре,
    /// как жёлтый индикатор слайдера в референсе.
    static let marker = Color(red: 0.96, green: 0.82, blue: 0.25)

    /// Радиусы скруглений. Контролы (кнопки, поля) — капсулы;
    /// контейнеры — концентрично радиусу окна Tahoe (~26 − инсет 10 = 16).
    enum Radius {
        static let card: CGFloat = 16
        static let badge: CGFloat = 12
    }

    /// Отступы и габариты.
    enum Spacing {
        /// Отступ «парящих» элементов от краёв окна.
        static let windowInset: CGFloat = 10
        /// Горизонтальные поля контента.
        static let section: CGFloat = 24
        static let cardPadding: CGFloat = 14
    }

    /// Анимации. Spring-пресеты .smooth/.snappy доступны с macOS 14.
    enum Anim {
        static let section: Animation = .smooth(duration: 0.25)
        static let hover: Animation = .snappy(duration: 0.15)
        /// Отклик контролов: переключение пресетов, кнопки и т.п.
        static let control: Animation = .snappy(duration: 0.2)
        /// Бесконечное «дыхание» неопределённого прогресса (не SF Symbol —
        /// symbolEffect на фигурах не работает).
        static let pulse: Animation = .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }

    /// Палитра mesh-фона: 9 цветов сетки 3×3, слева направо и сверху вниз.
    /// Тёмная тема — сливово-чёрная с маджентовыми проблесками,
    /// светлая — почти белая с розовыми переливами (блеклый небесно-розовый).
    static func meshColors(for scheme: ColorScheme) -> [Color] {
        switch scheme {
        case .dark:
            return [
                Color(red: 0.10, green: 0.03, blue: 0.09),
                Color(red: 0.17, green: 0.04, blue: 0.14),
                Color(red: 0.12, green: 0.03, blue: 0.12),
                Color(red: 0.14, green: 0.04, blue: 0.13),
                Color(red: 0.24, green: 0.06, blue: 0.19),
                Color(red: 0.13, green: 0.04, blue: 0.14),
                Color(red: 0.09, green: 0.03, blue: 0.10),
                Color(red: 0.18, green: 0.05, blue: 0.15),
                Color(red: 0.12, green: 0.04, blue: 0.12)
            ]
        default:
            return [
                Color(red: 0.99, green: 0.95, blue: 0.97),
                Color(red: 0.97, green: 0.91, blue: 0.95),
                Color(red: 0.99, green: 0.96, blue: 0.98),
                Color(red: 0.98, green: 0.93, blue: 0.96),
                Color(red: 0.95, green: 0.87, blue: 0.93),
                Color(red: 0.98, green: 0.94, blue: 0.97),
                Color(red: 0.99, green: 0.96, blue: 0.97),
                Color(red: 0.97, green: 0.90, blue: 0.95),
                Color(red: 0.98, green: 0.95, blue: 0.97)
            ]
        }
    }
}
