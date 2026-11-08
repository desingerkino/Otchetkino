import SwiftUI

// MARK: - Палитра
// Спокойная светлая палитра без чистого белого: приглушённые серые поверхности, графит для текста, синий для основных действий.

extension Color {
    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if os(iOS)
        return Color(uiColor: UIColor { trait in
            let c = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        }))
        #endif
    }

    /// Приятный синий — основные действия, фокус, выбранные элементы.
    static let rkAccent = dynamic(light: (0.145, 0.388, 0.922), dark: (0.36, 0.55, 1.0))
    /// Зелёный — положительный остаток, успешное сохранение.
    static let rkGood = dynamic(light: (0.13, 0.55, 0.30), dark: (0.30, 0.78, 0.50))
    /// Оранжевый — предупреждения и поля, требующие проверки.
    static let rkWarn = dynamic(light: (0.89, 0.52, 0.08), dark: (1.0, 0.66, 0.25))
    /// Красный — ошибки и перерасход.
    static let rkBad = dynamic(light: (0.78, 0.22, 0.18), dark: (1.0, 0.45, 0.40))
    /// Приглушённый фон рабочей области (#F0F1F3).
    static let rkBackground = dynamic(light: (0.941, 0.945, 0.953), dark: (0.105, 0.108, 0.118))
    /// Поверхность панелей и карточек (#F3F4F6).
    static let rkCard = dynamic(light: (0.953, 0.957, 0.965), dark: (0.15, 0.155, 0.17))
    /// Мягкий фон полей ввода.
    static let rkField = dynamic(light: (0.902, 0.910, 0.925), dark: (0.205, 0.21, 0.225))
    /// Тонкие границы полей и карточек.
    static let rkBorder = dynamic(light: (0.73, 0.75, 0.78), dark: (0.33, 0.34, 0.37))
    /// Едва заметный фон заголовков дней и выбранных блоков.
    /// Чередование строк таблицы: нечётные #E9EAED, чётные #D9DCE1.
    static let rkRowOdd = dynamic(light: (0.914, 0.918, 0.929), dark: (0.15, 0.155, 0.17))
    static let rkRowEven = dynamic(light: (0.851, 0.863, 0.882), dark: (0.19, 0.195, 0.21))
    /// Фон заголовков дат (#E3E5E9) и шапки таблицы.
    static let rkDateHeader = dynamic(light: (0.890, 0.898, 0.914), dark: (0.17, 0.175, 0.19))
    static let rkSoft = dynamic(light: (0.890, 0.898, 0.914), dark: (0.19, 0.195, 0.21))
}

// MARK: - Кнопки

/// Основная кнопка: синяя, округлая, с состояниями наведения и нажатия.
struct RKPrimaryButtonStyle: ButtonStyle {
    var tint: Color = .rkAccent
    func makeBody(configuration: Configuration) -> some View {
        RKPrimaryButtonBody(configuration: configuration, tint: tint)
    }
}

private struct RKPrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    var body: some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(configuration.isPressed ? 0.72 : (hover ? 0.90 : 1.0))))
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { hover = $0 }
    }
}

/// Второстепенная кнопка: мягкий синий фон.
struct RKSecondaryButtonStyle: ButtonStyle {
    var tint: Color = .rkAccent
    func makeBody(configuration: Configuration) -> some View {
        RKSecondaryButtonBody(configuration: configuration, tint: tint)
    }
}

private struct RKSecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    var body: some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(configuration.isPressed ? 0.24 : (hover ? 0.17 : 0.11))))
            .opacity(enabled ? 1 : 0.5)
            .onHover { hover = $0 }
    }
}

// MARK: - Поля

struct RKFieldModifier: ViewModifier {
    var focused: Bool
    var warn: Bool = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(Color.rkField)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(focused ? Color.rkAccent : (warn ? Color.rkWarn : Color.rkBorder), lineWidth: (focused || warn) ? 2 : 1)
            )
    }
}

extension View {
    /// Единый вид поля ввода: тонкая граница, мягкий фон, синий контур при фокусе, оранжевый — если поле нужно проверить.
    func rkField(focused: Bool = false, warn: Bool = false) -> some View { modifier(RKFieldModifier(focused: focused, warn: warn)) }
}

// MARK: - Карточки и подписи

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.rkCard)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.rkBorder.opacity(0.6), lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
}

/// Раздел формы: тонкая рамка без теней.
struct RKSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: () -> Content
    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = title {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            }
            content()
        }
        .card()
    }
}

/// Поле с подписью сверху.
struct RKLabeled<Content: View>: View {
    let title: String
    var warn: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if let warn = warn {
                    Text(warn).font(.caption2.weight(.semibold)).foregroundStyle(Color.rkWarn)
                }
            }
            content()
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var tint: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(tint ?? .primary).minimumScaleFactor(0.6).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusBanner: View {
    let text: String
    var icon: String = "info.circle.fill"
    var tint: Color = .rkAccent
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
