import SwiftUI
import CoreData

/// Действие по Enter в однострочных полях формы покупки (на Mac: сохранить и создать следующую покупку).
private struct RKEnterActionKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var rkEnterAction: (() -> Void)? {
        get { self[RKEnterActionKey.self] }
        set { self[RKEnterActionKey.self] = newValue }
    }
}

// MARK: - Текстовое поле с отложенной записью
// Текст сначала лежит в поле, а в данные попадает через короткую паузу, при уходе из поля, при смене записи
// и перед каждым сохранением. Поэтому одна «серия» набора — один шаг отмены, а автосохранение не пишет на каждую букву.

struct RKTextField: View {
    let title: String
    @Binding var value: String
    var axis: Axis = .horizontal
    var warn = false
    var idleDelay: TimeInterval = 0.6
    var autofocus = false

    @Environment(\.rkEnterAction) private var enterAction
    @State private var text = ""
    @State private var work: DispatchWorkItem?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, axis: axis)
            .focused($focused)
            .rkField(focused: focused, warn: warn)
            // Enter в многострочном поле (комментарий, назначение) — это перенос строки, а не создание покупки
            .onSubmit { if axis == .horizontal { commit(); enterAction?() } }
            .onAppear { text = value }
            // фокус ставится после появления поля в иерархии (задача запускается после первой отрисовки), без таймеров
            // только для пустого поля новой позиции: выбор существующей покупки не должен отбирать фокус у таблицы
            .task { if autofocus && value.isEmpty { focused = true } }
            .onChange(of: text) { _ in schedule() }
            .onChange(of: value) { new in if !focused && new != text { text = new } }
            .onChange(of: focused) { f in if !f { commit() } }
            .onDisappear { commit() }
            .onReceive(NotificationCenter.default.publisher(for: .rkFlushEdits)) { _ in commit() }
    }

    private func schedule() {
        work?.cancel()
        let item = DispatchWorkItem { commit() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay, execute: item)
    }

    private func commit() {
        work?.cancel()
        if value != text { value = text }
    }
}

// MARK: - Поле суммы

/// Денежное поле: чёткая рамка, синий контур в фокусе, пробелы между тысячами, знак ₽, выделение при входе.
/// Значение хранится в копейках (Int64) — без ошибок округления.
struct AmountField: View {
    let title: String
    @Binding var kop: Int64
    var warn = false

    @Environment(\.rkEnterAction) private var enterAction
    @State private var text = ""
    @State private var work: DispatchWorkItem?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .onSubmit { commit(); enterAction?() }
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .focused($focused)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Text("₽").foregroundStyle(.secondary)
        }
        .rkField(focused: focused, warn: warn)
        .onAppear { text = display(kop) }
        .onChange(of: text) { new in
            let formatted = Money.formatInput(new)
            if formatted != new { text = formatted; return }
            schedule()
        }
        .onChange(of: kop) { new in if !focused { text = display(new) } }
        .onChange(of: focused) { f in
            if f {
                #if os(macOS)
                DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil) }
                #endif
            } else {
                commit()
                text = display(kop)
            }
        }
        .onDisappear { commit() }
        .onReceive(NotificationCenter.default.publisher(for: .rkFlushEdits)) { _ in commit() }
    }

    private func display(_ value: Int64) -> String { Money.formatInput(Money.editString(value)) }

    private func schedule() {
        work?.cancel()
        let item = DispatchWorkItem { commit() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func commit() {
        work?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let v: Int64 = trimmed.isEmpty ? 0 : (Money.parse(trimmed) ?? kop)
        if v != kop { kop = v }
    }
}

// MARK: - Магазин с подсказками

/// Поле «Магазин»: пока вводите, предлагает названия из справочника («Ав» → «АВИТО»).
struct StoreField: View {
    @Binding var value: String
    var warn = false

    @Environment(\.managedObjectContext) private var ctx
    @Environment(\.rkEnterAction) private var enterAction
    @State private var text = ""
    @State private var suggestions: [String] = []
    @State private var skipNext = false
    @State private var work: DispatchWorkItem?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Магазин / организация", text: $text)
                .focused($focused)
                .rkField(focused: focused, warn: warn)
                // Enter при открытой подсказке выбирает её; без подсказок — как в остальных полях формы
                .onSubmit {
                    if let first = suggestions.first { choose(first) } else { commit(); enterAction?() }
                }
            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { idx, name in
                        Button { choose(name) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "storefront").foregroundStyle(.secondary)
                                Text(name).foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < suggestions.count - 1 { Divider() }
                    }
                }
                .background(Color.rkCard)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.rkBorder, lineWidth: 1))
            }
        }
        .onAppear { text = value }
        .onChange(of: text) { new in
            if skipNext { skipNext = false; return }
            suggestions = focused ? StoreDirectory.suggestions(ctx, for: new) : []
            schedule()
        }
        .onChange(of: value) { new in if !focused && new != text { text = new } }
        .onChange(of: focused) { f in
            if !f {
                commit()
                // небольшая пауза, чтобы успел сработать щелчок по подсказке
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if !focused { suggestions = [] } }
            }
        }
        .onDisappear { commit() }
        .onReceive(NotificationCenter.default.publisher(for: .rkFlushEdits)) { _ in commit() }
    }

    private func choose(_ name: String) {
        skipNext = true
        text = name
        suggestions = []
        commit()
    }

    private func schedule() {
        work?.cancel()
        let item = DispatchWorkItem { commit() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func commit() {
        work?.cancel()
        if value != text { value = text }
    }
}

// MARK: - Строка поиска

/// Собственная строка поиска для верхней панели: ровная, с кнопкой очистки, не «уезжает» при изменении размера окна.
struct RKSearchField: View {
    @Binding var text: String
    var prompt = "Поиск"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Очистить поиск")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.rkField)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(focused ? Color.rkAccent : Color.rkBorder, lineWidth: focused ? 2 : 1))
    }
}
