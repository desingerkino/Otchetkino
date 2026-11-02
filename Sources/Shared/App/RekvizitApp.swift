import SwiftUI
import CoreData

@main
struct RekvizitApp: App {
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var appState = AppState()
    @StateObject private var refresher = DataRefresher(context: PersistenceController.shared.viewContext)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistence.viewContext)
                .environmentObject(persistence)
                .environmentObject(appState)
                .environmentObject(refresher)
                .environmentObject(OCRCoordinator.shared)
                .tint(Color.rkAccent)
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var persistence: PersistenceController
    @EnvironmentObject private var app: AppState

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
                persistence.save()
                BackupService.autoBackupIfNeeded(container: persistence.container)
            }
        }
        .task { BackupService.autoBackupIfNeeded(container: persistence.container) }
        #if os(macOS)
        .frame(minWidth: 1120, minHeight: 660)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in persistence.save() }
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
