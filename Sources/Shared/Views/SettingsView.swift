import SwiftUI
import CoreData
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var project: RProject
    @EnvironmentObject private var persistence: PersistenceController
    @EnvironmentObject private var refresher: DataRefresher
    @EnvironmentObject private var app: AppState
    @Environment(\.managedObjectContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    var isSheet = false
    @AppStorage(PersistenceController.iCloudPrefKey) private var iCloudEnabled = true
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \RCategory.sortOrder, ascending: true), NSSortDescriptor(keyPath: \RCategory.name, ascending: true)])
    private var categories: FetchedResults<RCategory>

    @State private var advanceKind: Int16?
    @State private var confirmRenumber = false
    @State private var confirmDeleteProject = false
    @State private var backups: [URL] = BackupService.existingBackups()
    @State private var backupMessage: String?
    @State private var showRestore = false
    @State private var newCategory = ""

    struct KindBox: Identifiable { let kind: Int16; var id: Int16 { kind } }

    var body: some View {
        let _ = refresher.tick
        NavigationStack {
            Form {
                Section("Проект") {
                    TextField("Название фильма / проекта", text: $project.name)
                    TextField("ФИО подотчётного лица", text: $project.holder)
                    Toggle("Архивный проект", isOn: $project.isArchived)
                }
                moneySection
                scenesSection
                categoriesSection
                Section {
                    Button("Перенумеровать чеки по порядку") { confirmRenumber = true }
                } header: { Text("Нумерация чеков") } footer: {
                    Text("Номера присваиваются автоматически и не повторяются. Если вы удалили чек из середины списка, можно привести номера в порядок: по дате покупки, без пропусков.")
                }
                syncSection
                backupSection
                Section {
                    Button("Удалить проект целиком", role: .destructive) { confirmDeleteProject = true }
                } footer: { Text("Будут удалены все чеки, фотографии, выдачи и сцены этого проекта.") }
                Section("О приложении") {
                    LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Настройки")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if isSheet { ToolbarItem(placement: .confirmationAction) { Button("Готово") { try? ctx.save(); dismiss() } } }
            }
            .onDisappear { persistence.save() }
            .sheet(item: Binding(get: { advanceKind.map { KindBox(kind: $0) } }, set: { advanceKind = $0?.kind })) { box in
                AdvanceSheet(project: project, kind: box.kind)
            }
            .confirmationDialog("Перенумеровать все чеки проекта?", isPresented: $confirmRenumber, titleVisibility: .visible) {
                Button("Перенумеровать") { DataOps.renumber(ctx, project: project) }
                Button("Отмена", role: .cancel) {}
            }
            .confirmationDialog("Удалить проект «\(project.displayName)» со всеми данными?", isPresented: $confirmDeleteProject, titleVisibility: .visible) {
                Button("Удалить навсегда", role: .destructive) {
                    ctx.delete(project); try? ctx.save(); app.selectedProjectID = ""; dismiss()
                }
                Button("Отмена", role: .cancel) {}
            }
            .fileImporter(isPresented: $showRestore, allowedContentTypes: [.zip]) { result in
                guard case .success(let url) = result else { return }
                Task {
                    do {
                        let n = try await BackupService.restore(from: url, container: persistence.container)
                        backupMessage = n == 0 ? "Все данные из копии уже есть в приложении." : "Восстановлено записей: \(n)."
                    } catch { backupMessage = "Не удалось восстановить: \(error.localizedDescription)" }
                }
            }
        }
        #if os(macOS)
        .frame(width: 600, height: 760)
        #endif
    }

    // MARK: Деньги

    private var moneySection: some View {
        let t = project.totals()
        return Section {
            LabeledContent("Выдано", value: Money.format(t.issued))
            LabeledContent("Возвращено", value: Money.format(t.returned))
            LabeledContent("Потрачено", value: Money.format(t.spent))
            LabeledContent(t.isOverspent ? "Перерасход" : "Остаток") {
                Text(Money.format(t.balance)).fontWeight(.bold).foregroundStyle(t.isOverspent ? Color.rkBad : .primary)
            }
            ForEach(project.advanceList, id: \.objectID) { a in
                HStack {
                    Image(systemName: a.kind == 0 ? "arrow.down.circle.fill" : "arrow.uturn.backward.circle.fill").foregroundStyle(a.kind == 0 ? Color.rkGood : Color.rkAccent)
                    VStack(alignment: .leading) {
                        Text(a.kind == 0 ? "Выдача" : "Возврат")
                        Text("\(Fmt.date.string(from: a.date ?? Date()))\(a.note.isEmpty ? "" : " · " + a.note)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Money.format(a.amountKop))
                    Button(role: .destructive) { ctx.delete(a); try? ctx.save() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            HStack {
                Button { advanceKind = 0 } label: { Label("Добавить выдачу", systemImage: "plus.circle") }
                Spacer()
                Button { advanceKind = 1 } label: { Label("Вернуть деньги", systemImage: "arrow.uturn.backward.circle") }
            }
            .buttonStyle(.borderless)
        } header: { Text("Деньги") } footer: {
            Text("Остаток = выдано − потрачено − возвращено.")
        }
    }

    // MARK: Сцены и категории

    private var scenesSection: some View {
        Section {
            ForEach(project.sceneList, id: \.objectID) { s in SceneEditRow(scene: s) }
            Button {
                let s = RScene(context: ctx)
                s.project = project
                s.sortOrder = Int32(project.sceneList.count)
                s.code = String(format: "%02d", project.sceneList.count + 1)
                try? ctx.save()
            } label: { Label("Добавить сцену", systemImage: "plus.circle") }
                .buttonStyle(.borderless)
        } header: { Text("Сцены") } footer: {
            Text("Одну покупку можно привязать к нескольким сценам.")
        }
    }

    private var categoriesSection: some View {
        Section("Категории расходов") {
            ForEach(categories, id: \.objectID) { c in CategoryEditRow(category: c) }
            HStack {
                TextField("Новая категория", text: $newCategory)
                Button("Добавить") {
                    let name = newCategory.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let c = RCategory(context: ctx)
                    c.name = name
                    c.sortOrder = Int32(categories.count)
                    newCategory = ""
                    try? ctx.save()
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: iCloud и копии

    private var syncSection: some View {
        Section {
            Toggle("Синхронизация через iCloud", isOn: $iCloudEnabled)
            Text(persistence.syncStatus).font(.footnote).foregroundStyle(.secondary)
        } header: { Text("Синхронизация iPhone и Mac") } footer: {
            Text("Данные и оригиналы фотографий хранятся на устройстве и синхронизируются с iCloud. Без интернета приложение работает как обычно, изменения уйдут при подключении. Изменение переключателя вступает в силу после перезапуска приложения.")
        }
    }

    private var backupSection: some View {
        Section {
            Button {
                Task {
                    do {
                        let url = try await BackupService.create(container: persistence.container)
                        BackupService.prune(keep: 7)
                        backups = BackupService.existingBackups()
                        backupMessage = "Копия создана: \(url.lastPathComponent)"
                    } catch { backupMessage = "Не удалось создать копию: \(error.localizedDescription)" }
                }
            } label: { Label("Создать резервную копию сейчас", systemImage: "externaldrive.badge.plus") }
            ForEach(backups.prefix(5), id: \.self) { url in
                HStack {
                    Text(url.deletingPathExtension().lastPathComponent).font(.footnote).lineLimit(1)
                    Spacer()
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                }
            }
            Button { showRestore = true } label: { Label("Восстановить из копии…", systemImage: "arrow.counterclockwise") }
            if let m = backupMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Резервные копии") } footer: {
            Text("Копия (данные + оригиналы фото) создаётся автоматически раз в сутки, хранятся последние 7. Восстановление добавляет только то, чего нет в приложении, и ничего не затирает.")
        }
    }
}

struct SceneEditRow: View {
    @ObservedObject var scene: RScene
    @Environment(\.managedObjectContext) private var ctx
    var body: some View {
        HStack {
            TextField("№", text: $scene.code).frame(width: 56)
            TextField("Описание (квартира героя)", text: $scene.title)
            Button(role: .destructive) { ctx.delete(scene); try? ctx.save() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }
}

struct CategoryEditRow: View {
    @ObservedObject var category: RCategory
    @Environment(\.managedObjectContext) private var ctx
    var body: some View {
        HStack {
            TextField("Название", text: $category.name)
            Button(role: .destructive) { ctx.delete(category); try? ctx.save() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }
}
