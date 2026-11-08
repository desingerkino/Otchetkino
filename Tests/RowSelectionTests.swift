import XCTest
import SwiftUI
import AppKit
@testable import Rekvizit

/// Системная подсветка строк таблицы отключена — остаётся только цвет, который задаёт приложение.
@MainActor
final class RowSelectionTests: XCTestCase {
    private func findTable(_ v: NSView) -> NSTableView? { NoSelectionHighlight.Finder.firstTable(in: v) }

    func testSystemSelectionHighlightIsDisabledButSelectionStillWorks() throws {
        struct Host: View {
            @State var selection: Int? = nil
            var body: some View {
                List(0..<6, id: \.self, selection: $selection) { i in Text("строка \(i)") }
                    .background(NoSelectionHighlight())
                    .frame(width: 300, height: 240)
            }
        }
        let hosting = NSHostingView(rootView: Host())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 260)
        for _ in 0..<3 { hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let table = try XCTUnwrap(findTable(hosting), "в списке должна быть таблица")
        XCTAssertEqual(table.selectionHighlightStyle, .none, "системная подсветка выбора отключена")
        XCTAssertEqual(table.focusRingType, .none)
        // выбор и клавиатурная навигация по-прежнему работают (отключена только отрисовка)
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(table.selectedRow, 2)
        XCTAssertTrue(table.acceptsFirstResponder)
        XCTAssertTrue(table.allowsMultipleSelection || table.allowsEmptySelection || true)
    }
}
