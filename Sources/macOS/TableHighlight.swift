import SwiftUI
import AppKit

/// Отключает системную подсветку выбранных строк у NSTableView под списком SwiftUI.
/// Причина «промежуточного эффекта»: пока строка нажата, AppKit сам рисует свою подсветку (свой фон и белый текст),
/// и только после этого срабатывает наш синий фон. Выбор, клавиатурная навигация и фокус полей остаются — убирается только отрисовка.
/// Цвет выбранной строки целиком задаётся приложением (`listRowBackground`), поэтому он меняется сразу и без второго слоя.
struct NoSelectionHighlight: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Finder)?.apply() }

    final class Finder: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func layout() { super.layout(); apply() }

        /// Ближайшая таблица среди «соседей»: поднимаемся по иерархии, пока не найдём контейнер с NSTableView.
        func apply() {
            var node: NSView? = superview
            var depth = 0
            while let n = node, depth < 6 {
                if let table = Self.firstTable(in: n) {
                    Self.configure(table)
                    return
                }
                node = n.superview
                depth += 1
            }
        }

        static func configure(_ table: NSTableView) {
            if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
            if table.focusRingType != .none { table.focusRingType = .none }
        }

        static func firstTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews { if let table = firstTable(in: sub) { return table } }
            return nil
        }
    }
}
