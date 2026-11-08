import SwiftUI
import CoreData

@main
struct RekvizitApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var appState = AppState()
    @StateObject private var refresher = DataRefresher(context: PersistenceController.shared.viewContext)
    @StateObject private var saver = SaveCoordinator.shared
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistence.viewContext)
                .environmentObject(persistence)
                .environmentObject(appState)
                .environmentObject(refresher)
                .environmentObject(saver)
                .environmentObject(OCRCoordinator.shared)
                .tint(Color.rkAccent)
        }
        #if os(macOS)
        .defaultSize(width: 1360, height: 820)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Сохранить") { _ = SaveCoordinator.shared.saveNow() }.keyboardShortcut("s")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Отменить") { UndoRouter.undo() }.keyboardShortcut("z")
                Button("Повторить") { UndoRouter.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("Новая покупка") { AppCommand.post(.newPurchase) }.keyboardShortcut("n")
                Button("Загрузить чеки из файлов…") { AppCommand.post(.importReceipts) }.keyboardShortcut("i")
                Divider()
                Button("Отчёт Excel…") { AppCommand.post(.exportExcel) }.keyboardShortcut("e")
                Button("Отчёт PDF…") { AppCommand.post(.exportPDF) }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Печать отчёта…") { AppCommand.post(.printReport) }.keyboardShortcut("p")
            }
            CommandMenu("Покупки") {
                Button("Увеличить фото чека") { AppCommand.post(.openPhoto) }.keyboardShortcut("y")
                Button("Изменить выбранные…") { AppCommand.post(.bulkEdit) }.keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Фильтры…") { AppCommand.post(.filters) }.keyboardShortcut("f", modifiers: [.command, .option])
                Button("Деньги: выдача…") { AppCommand.post(.issueMoney) }.keyboardShortcut("m")
                Button("Настройки проекта…") { AppCommand.post(.settings) }.keyboardShortcut(",")
            }
        }
        #endif
    }
}

enum AppCommand: String {
    case newPurchase, importReceipts, exportExcel, exportPDF, printReport, openPhoto, bulkEdit, filters, issueMoney, settings
    var name: Notification.Name { Notification.Name("rk.cmd." + rawValue) }
    static func post(_ c: AppCommand) { NotificationCenter.default.post(name: c.name, object: nil) }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var persistence: PersistenceController
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var saver: SaveCoordinator

    var body: some View {
        Group {
            #if os(iOS)
            PhoneRootView()
            #else
            MacRootView()
            #endif
        }
        .sheet(isPresented: $app.showNewProject) { NewProjectSheet() }
        .alert("Реквизит", isPresented: Binding(get: { app.alertMessage != nil }, set: { if !$0 { app.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(app.alertMessage ?? "") }
        .alert("Не удалось открыть базу данных", isPresented: Binding(get: { persistence.loadError != nil }, set: { _ in })) {
            Button("OK", role: .cancel) {}
        } message: { Text(persistence.loadError ?? "") }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                _ = saver.saveNow()
                BackupService.autoBackupIfNeeded(container: persistence.container)
            }
        }
        .task { BackupService.autoBackupIfNeeded(container: persistence.container) }
        #if os(macOS)
        .frame(minWidth: 1120, minHeight: 660)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in _ = saver.saveNow() }
        #endif
    }
}

/// Показывает содержимое для выбранного проекта или предложение создать первый.
struct ProjectGate<Content: View>: View {
    @EnvironmentObject private var app: AppState
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \RProject.createdAt, ascending: false)]) private var projects: FetchedResults<RProject>
    let content: (RProject) -> Content

    private var current: RProject? {
        projects.first { $0.uuid?.uuidString == app.selectedProjectID }
            ?? projects.first { !$0.isArchived }
            ?? projects.first
    }

    var body: some View {
        if let p = current {
            content(p).id(p.objectID)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "banknote").font(.system(size: 54)).foregroundStyle(Color.rkAccent)
                Text("Создайте первый финансовый проект").font(.title3.weight(.semibold))
                Text("Укажите название фильма и сумму, выданную продюсером. Остальное приложение посчитает само.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
                Button { app.showNewProject = true } label: { Label("Новый проект", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.rkBackground)
        }
    }
}

#if os(macOS)
import AppKit

/// Закрытие приложения: сначала принудительное сохранение; если не удалось — предупреждение, а не молчаливая потеря данных.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let saver = SaveCoordinator.shared
        if saver.saveNow() { return .terminateNow }
        while true {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Не удалось сохранить изменения"
            alert.informativeText = "\(saver.errorText)\n\nДанные не потеряны — они остаются в приложении. Повторите сохранение."
            alert.addButton(withTitle: "Повторить сохранение")
            alert.addButton(withTitle: "Не закрывать")
            alert.addButton(withTitle: "Закрыть без сохранения")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if saver.saveNow() { return .terminateNow }
            case .alertSecondButtonReturn:
                return .terminateCancel
            default:
                return .terminateNow
            }
        }
    }
}

/// Отмена и повтор: в текстовом поле работает обычная отмена ввода, в остальных случаях — отмена действий приложения над данными.
@MainActor
enum UndoRouter {
    private static var fieldEditor: NSTextView? {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable else { return nil }
        return tv
    }

    static func undo() {
        if let tv = fieldEditor, tv.undoManager?.canUndo == true { tv.undoManager?.undo(); return }
        let ctx = PersistenceController.shared.viewContext
        _ = SaveCoordinator.shared.saveNow()
        guard let um = ctx.undoManager, um.canUndo else { return }
        while um.groupingLevel > 0 { um.endUndoGrouping() }
        um.undo()
    }

    static func redo() {
        if let tv = fieldEditor, tv.undoManager?.canRedo == true { tv.undoManager?.redo(); return }
        let ctx = PersistenceController.shared.viewContext
        guard let um = ctx.undoManager, um.canRedo else { return }
        while um.groupingLevel > 0 { um.endUndoGrouping() }
        um.redo()
    }
}
#endif
