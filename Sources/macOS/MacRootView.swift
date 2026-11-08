import SwiftUI
import CoreData

struct MacRootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var persistence: PersistenceController
    @EnvironmentObject private var saver: SaveCoordinator
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \RProject.createdAt, ascending: false)]) private var projects: FetchedResults<RProject>

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<String?>(get: { app.selectedProjectID }, set: { app.selectedProjectID = $0 ?? "" })) {
                Section("Проекты") {
                    ForEach(projects, id: \.objectID) { p in
                        SidebarProjectRow(project: p).tag(p.uuid?.uuidString ?? "")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Button { app.showNewProject = true } label: { Label("Новый проект", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderless)
                    Text(persistence.syncStatus).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SaveButton()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.bar)
            }
        } detail: {
            ProjectGate { MacWorkspace(project: $0) }
        }
        .onChange(of: app.selectedProjectID) { _ in saver.saveNow() }   // смена проекта сохраняет текущие изменения
    }
}

/// Постоянная кнопка «Сохранить» внизу левой панели. Дополняет автосохранение, но не обязательна для работы.
struct SaveButton: View {
    @EnvironmentObject private var saver: SaveCoordinator

    private var title: String {
        switch saver.state {
        case .dirty: return "Сохранить"
        case .saving: return "Сохранение…"
        case .saved: return "Сохранено"
        case .failed: return "Ошибка сохранения"
        }
    }
    private var icon: String {
        switch saver.state {
        case .dirty: return "square.and.arrow.down"
        case .saving: return "arrow.triangle.2.circlepath"
        case .saved: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
    private var tint: Color {
        switch saver.state {
        case .dirty: return .rkAccent
        case .saving: return .rkAccent
        case .saved: return .rkGood
        case .failed: return .rkBad
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { _ = saver.saveNow() } label: {
                Label(title, systemImage: icon).frame(maxWidth: .infinity)
            }
            .buttonStyle(RKPrimaryButtonStyle(tint: tint))
            .disabled(saver.state == .saving)
            .help("Сохранить все изменения сейчас (⌘S). Обычно не нужно: приложение сохраняет само.")
            if case .failed(let message) = saver.state {
                Text("Данные не потеряны, они остаются в приложении. \(message)")
                    .font(.caption2).foregroundStyle(Color.rkBad).fixedSize(horizontal: false, vertical: true)
            } else if let at = saver.lastSavedAt, saver.state == .saved {
                Text("Записано в \(DateFormatter.localizedString(from: at, dateStyle: .none, timeStyle: .short))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct SidebarProjectRow: View {
    @ObservedObject var project: RProject
    @EnvironmentObject private var refresher: DataRefresher
    var body: some View {
        let _ = refresher.tick
        let t = project.totals()
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(project.displayName).fontWeight(.medium).lineLimit(1)
                if project.isArchived { Image(systemName: "archivebox").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Остаток \(Money.format(t.balance))").font(.caption).foregroundStyle(t.isOverspent ? Color.rkBad : .secondary)
        }
        .padding(.vertical, 2)
    }
}
