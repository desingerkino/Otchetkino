import SwiftUI
import CoreData

struct MacRootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var persistence: PersistenceController
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
                VStack(alignment: .leading, spacing: 6) {
                    Button { app.showNewProject = true } label: { Label("Новый проект", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderless)
                    Text(persistence.syncStatus).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.bar)
            }
        } detail: {
            ProjectGate { MacWorkspace(project: $0) }
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
