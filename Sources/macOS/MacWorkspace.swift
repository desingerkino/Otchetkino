import SwiftUI
import CoreData
import UniformTypeIdentifiers

struct PurchaseRow: Identifiable, Hashable {
    let id: NSManagedObjectID
    let receiptID: NSManagedObjectID
    let number: Int
    let order: Int
    let date: Date
    let title: String
    let category: String
    let scenes: String
    let store: String
    let amount: Int64
    let hasReceipt: Bool
    let isPlaceholder: Bool
}

/// Покупки одного дня — для заголовков «8 НОЯБРЯ 2026» в списке.
struct DayGroup: Identifiable {
    let day: Date
    let rows: [PurchaseRow]
    var id: Date { day }
    var total: Int64 { rows.reduce(0) { $0 + $1.amount } }
}

struct MacWorkspace: View {
    @ObservedObject var project: RProject
    @Environment(\.managedObjectContext) private var ctx
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var persistence: PersistenceController
    @EnvironmentObject private var refresher: DataRefresher
    @EnvironmentObject private var saver: SaveCoordinator
    @StateObject private var reports = ReportController()

    @State private var selection = Set<PurchaseRow.ID>()
    @State private var selectedReceiptID: NSManagedObjectID?
    @State private var filter = PurchaseFilter()
    @State private var showFilters = false
    @State private var showSettings = false
    @State private var showImporter = false
    @State private var showBulk = false
    @State private var confirmDelete = false
    @State private var advanceKind: Int16?
    @State private var dropTargeted = false
    @State private var showPeriod = false
    @State private var useDates = false
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var viewerPhotos: ViewerBox?

    struct ViewerBox: Identifiable { let id = UUID(); let photos: [RPhoto] }
    struct KindBox: Identifiable { let kind: Int16; var id: Int16 { kind } }

    // MARK: Данные

    private func buildRows() -> [PurchaseRow] {
        var rows: [PurchaseRow] = []
        for r in project.receiptList where !r.isDeleted {
            let blank = r.isBlank
            let items = r.purchaseList.filter { !$0.isDeleted }
            if items.isEmpty {
                if filter.text.isEmpty && !filter.isActive {
                    rows.append(PurchaseRow(id: r.objectID, receiptID: r.objectID, number: Int(r.number), order: 0, date: r.date ?? Date(),
                                            title: "(позиции не заполнены)", category: "—", scenes: "", store: r.store, amount: 0,
                                            hasReceipt: !r.noReceipt, isPlaceholder: true))
                }
                continue
            }
            for p in items where filter.matches(p) {
                rows.append(PurchaseRow(id: p.objectID, receiptID: r.objectID, number: Int(r.number), order: Int(p.sortOrder), date: r.date ?? Date(),
                                        title: blank ? "Новая покупка" : p.title, category: p.categoryName, scenes: p.scenesText, store: r.store,
                                        amount: p.amountKop, hasReceipt: !r.noReceipt, isPlaceholder: blank))
            }
        }
        return rows
    }

    /// Группировка по дате покупки (не по дате создания записи): новые дни сверху, внутри дня — от большего номера к меньшему.
    private func makeGroups(_ rows: [PurchaseRow]) -> [DayGroup] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: rows) { cal.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            let sorted = (byDay[day] ?? []).sorted { a, b in
                if a.number != b.number { return a.number > b.number }
                return a.order < b.order
            }
            return DayGroup(day: day, rows: sorted)
        }
    }

    var body: some View {
        let _ = refresher.tick
        let rows = buildRows()
        let groups = makeGroups(rows)
        VStack(spacing: 0) {
            MetricsBar(project: project)
            Divider()
            topBar
            Divider()
            HSplitView {
                tableArea(rows, groups)
                    .frame(minWidth: 560)
                inspector(rows)
                    .frame(minWidth: 360, idealWidth: 430, maxWidth: 600)
            }
        }
        .background(Color.rkBackground)
        .navigationTitle(project.displayName)
        .navigationSubtitle(project.holder)
        .toolbar { toolbarContent }
        .overlay { dropOverlay }
        .overlay { if reports.busy != nil { busyOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importURLs(urls) }
        }
        .sheet(isPresented: $showFilters) { FilterSheet(filter: $filter, project: project) }
        .sheet(isPresented: $showSettings) { SettingsView(project: project, isSheet: true) }
        .sheet(isPresented: $showBulk) { BulkEditSheet(project: project, rows: selectedRows(rows)) }
        .sheet(item: Binding(get: { advanceKind.map { KindBox(kind: $0) } }, set: { advanceKind = $0?.kind })) { AdvanceSheet(project: project, kind: $0.kind) }
        .sheet(item: $viewerPhotos) { PhotoViewer(photos: $0.photos, index: 0) }
        .sheet(isPresented: $showPeriod) { periodSheet }
        .reportExporter(reports)
        .confirmationDialog("Удалить выбранные позиции (\(selection.count))? Это можно отменить (⌘Z).", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { deleteSelected(rows) }
            Button("Отмена", role: .cancel) {}
        }
        .onChange(of: selection) { _ in
            if let first = rows.first(where: { selection.contains($0.id) }) { selectedReceiptID = first.receiptID }
        }
        .onChange(of: selectedReceiptID) { id in
            // Переход к другой покупке сразу сохраняет предыдущую (пустая форма при этом удаляется).
            saver.setActive(id.map { [$0] } ?? [])
            saver.saveNow()
        }
        .onChange(of: rows.map { $0.id }) { ids in
            // Строки перестроились (например, после распознавания) — сохраняем выбор по чеку
            if selection.isEmpty || selection.contains(where: { !ids.contains($0) }) {
                if let rid = selectedReceiptID, let row = rows.first(where: { $0.receiptID == rid }) { selection = [row.id] }
            }
        }
        .onChange(of: reports.errorText) { e in if let e = e { app.alertMessage = e } }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.newPurchase.name)) { _ in addManual() }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.importReceipts.name)) { _ in showImporter = true }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.exportExcel.name)) { _ in export(.excel, .save) }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.exportPDF.name)) { _ in export(.pdf, .save) }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.printReport.name)) { _ in export(.pdf, .print) }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.openPhoto.name)) { _ in openPhoto() }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.bulkEdit.name)) { _ in if !selection.isEmpty { showBulk = true } }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.filters.name)) { _ in showFilters = true }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.issueMoney.name)) { _ in advanceKind = 0 }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.settings.name)) { _ in showSettings = true }
    }

    // MARK: Верхняя панель: поиск и фильтры

    private var topBar: some View {
        HStack(spacing: 10) {
            RKSearchField(text: $filter.text, prompt: "Поиск по расходам")
                .frame(maxWidth: 440)
            Button { showFilters = true } label: {
                Label(filter.isActive ? "Фильтры включены" : "Фильтры", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(RKSecondaryButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.rkCard)
    }

    // MARK: Таблица, сгруппированная по дням

    private static let colNumber: CGFloat = 46, colCategory: CGFloat = 130, colScenes: CGFloat = 70
    private static let colStore: CGFloat = 130, colAmount: CGFloat = 104, colReceipt: CGFloat = 62

    @ViewBuilder private func tableArea(_ rows: [PurchaseRow], _ groups: [DayGroup]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("№").frame(width: Self.colNumber, alignment: .leading)
                Text("Наименование").frame(maxWidth: .infinity, alignment: .leading)
                Text("Категория").frame(width: Self.colCategory, alignment: .leading)
                Text("Сцены").frame(width: Self.colScenes, alignment: .leading)
                Text("Магазин").frame(width: Self.colStore, alignment: .leading)
                Text("Сумма").frame(width: Self.colAmount, alignment: .trailing)
                Text("Чек").frame(width: Self.colReceipt, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Color.rkSoft)
            Divider()
            List(selection: $selection) {
                ForEach(groups) { g in
                    Section {
                        ForEach(g.rows) { r in rowView(r) }
                    } header: {
                        HStack {
                            Text(Fmt.dayHeader.string(from: g.day).uppercased()).font(.caption.weight(.bold)).foregroundStyle(Color.rkAccent)
                            Spacer()
                            Text(Money.format(g.total)).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: PurchaseRow.ID.self) { ids in
                if !ids.isEmpty {
                    Button("Изменить выбранные…") { showBulk = true }
                    Divider()
                    Button("Удалить", role: .destructive) { confirmDelete = true }
                }
            }
            .onDeleteCommand { if !selection.isEmpty { confirmDelete = true } }
            Divider()
            HStack {
                let sel = selectedRows(rows)
                Text("Строк: \(rows.count)").foregroundStyle(.secondary)
                if !sel.isEmpty { Text("· выбрано: \(sel.count) на \(Money.format(sel.reduce(0) { $0 + $1.amount }))").foregroundStyle(.secondary) }
                Spacer()
                Text("Всего в таблице: \(Money.format(rows.reduce(0) { $0 + $1.amount }))").fontWeight(.medium)
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Color.rkCard)
        }
    }

    private func rowView(_ r: PurchaseRow) -> some View {
        HStack(spacing: 10) {
            Text(String(format: "%03d", r.number)).monospacedDigit().foregroundStyle(.secondary).frame(width: Self.colNumber, alignment: .leading)
            Text(r.title.isEmpty ? "—" : r.title).lineLimit(2)
                .foregroundStyle(r.isPlaceholder ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(r.category).lineLimit(1).foregroundStyle(.secondary).frame(width: Self.colCategory, alignment: .leading)
            Text(r.scenes).lineLimit(1).foregroundStyle(.secondary).frame(width: Self.colScenes, alignment: .leading)
            Text(r.store).lineLimit(1).foregroundStyle(.secondary).frame(width: Self.colStore, alignment: .leading)
            Text(Money.format(r.amount)).monospacedDigit().fontWeight(.medium).frame(width: Self.colAmount, alignment: .trailing)
            Text(r.hasReceipt ? "есть" : "без чека").font(.caption).foregroundStyle(.secondary).frame(width: Self.colReceipt, alignment: .leading)
        }
        .font(.callout)
        .padding(.vertical, 3)
    }

    private func selectedRows(_ rows: [PurchaseRow]) -> [PurchaseRow] { rows.filter { selection.contains($0.id) } }

    // MARK: Правая панель

    @ViewBuilder private func inspector(_ rows: [PurchaseRow]) -> some View {
        let sel = selectedRows(rows)
        if sel.count > 1 {
            VStack(spacing: 14) {
                Image(systemName: "checklist").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Выбрано позиций: \(sel.count)").font(.headline)
                Text("На сумму \(Money.format(sel.reduce(0) { $0 + $1.amount }))").foregroundStyle(.secondary)
                Button("Изменить выбранные…") { showBulk = true }.buttonStyle(RKPrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let rid = selectedReceiptID, let receipt = try? ctx.existingObject(with: rid) as? RReceipt, !receipt.isDeleted, receipt.project == project {
            VStack(spacing: 0) {
                if !receipt.photoList.isEmpty {
                    ReceiptPreview(receipt: receipt) { viewerPhotos = ViewerBox(photos: receipt.photoList) }
                    Divider()
                }
                ReceiptForm(receipt: receipt).id(receipt.objectID)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 44)).foregroundStyle(.tertiary)
                Text("Выберите покупку в таблице").foregroundStyle(.secondary)
                Text("Сюда можно перетащить фотографии чеков из Finder").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Панель инструментов

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { addManual() } label: { Label("Новая покупка", systemImage: "plus") }
                .help("Новая покупка (⌘N)")
            Button { showImporter = true } label: { Label("Загрузить чеки", systemImage: "square.and.arrow.down") }
                .help("Загрузить фотографии чеков (⌘I) — можно сразу несколько, или перетащить из Finder")
            Menu {
                Button("Выдача денег…") { advanceKind = 0 }
                Button("Возврат денег…") { advanceKind = 1 }
            } label: { Label("Деньги", systemImage: "banknote") }
            Button { showFilters = true } label: {
                Label("Фильтры", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            Menu {
                Button("Excel — сохранить…") { export(.excel, .save) }
                Button("PDF — сохранить…") { export(.pdf, .save) }
                Button("Печать PDF…") { export(.pdf, .print) }
                Divider()
                Button(useDates ? "Период: \(Fmt.date.string(from: from)) — \(Fmt.date.string(from: to))…" : "Период отчёта: весь проект…") { showPeriod = true }
            } label: { Label("Отчёт", systemImage: "tablecells") }
            Button { showSettings = true } label: { Label("Настройки", systemImage: "gearshape") }
        }
    }

    private var periodSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Период отчёта").font(.headline)
            Toggle("Ограничить период", isOn: $useDates)
            if useDates {
                DatePicker("С", selection: $from, displayedComponents: .date)
                DatePicker("По", selection: $to, displayedComponents: .date)
            }
            HStack { Spacer(); Button("Готово") { showPeriod = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 340)
    }

    @ViewBuilder private var dropOverlay: some View {
        if dropTargeted {
            ZStack {
                Color.rkAccent.opacity(0.12)
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color.rkAccent, style: StrokeStyle(lineWidth: 3, dash: [10, 8])).padding(14)
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc.fill").font(.system(size: 48))
                    Text("Отпустите, чтобы загрузить чеки").font(.title3.weight(.semibold))
                }
                .foregroundStyle(Color.rkAccent)
            }
            .allowsHitTesting(false)
        }
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.15)
            VStack(spacing: 10) { ProgressView(); Text("Формируем отчёт…") }
                .padding(24).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Действия

    private func addManual() {
        saver.saveNow()   // предыдущая покупка уже записана
        let r = AddFlow.createManual(project: project, ctx: ctx)
        saver.setActive([r.objectID])
        selectedReceiptID = r.objectID
        if let first = r.purchaseList.first { selection = [first.objectID] }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url = url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { importURLs(urls) }
        return true
    }

    private func importURLs(_ input: [URL]) {
        var files: [URL] = []
        for u in input {
            let access = u.startAccessingSecurityScopedResource()
            defer { if access { u.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL { files.append(f) }
            } else { files.append(u) }
        }
        files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let datas = FileImport.readImages(files)
        guard !datas.isEmpty else { app.alertMessage = "Среди выбранных файлов не нашлось изображений."; return }
        let made = AddFlow.create(from: datas, kind: .other, project: project, ctx: ctx)
        if let first = made.first { selectedReceiptID = first.objectID; selection = [first.objectID] }
        if made.count > 1 {
            app.alertMessage = "Загружено чеков: \(made.count). Они уже сохранены; данные распознаются — проверьте их в правой панели (неуверенные поля подсвечены)."
        }
    }

    private func export(_ kind: ReportKind, _ after: ReportController.After) {
        Task { await reports.generate(kind, project: project, from: useDates ? from : nil, to: useDates ? to : nil, container: persistence.container, after: after) }
    }

    private func openPhoto() {
        guard let rid = selectedReceiptID, let r = try? ctx.existingObject(with: rid) as? RReceipt, !r.photoList.isEmpty else { return }
        viewerPhotos = ViewerBox(photos: r.photoList)
    }

    private func deleteSelected(_ rows: [PurchaseRow]) {
        for row in selectedRows(rows) {
            if let obj = try? ctx.existingObject(with: row.id) { ctx.delete(obj) }
        }
        selection = []; selectedReceiptID = nil
        saver.saveNow()
    }
}

// MARK: - Верхняя панель показателей

struct MetricsBar: View {
    @ObservedObject var project: RProject
    @EnvironmentObject private var refresher: DataRefresher
    var body: some View {
        let _ = refresher.tick
        let t = project.totals()
        HStack(spacing: 0) {
            metric("Выдано", Money.format(t.issued))
            metric("Потрачено", Money.format(t.spent))
            metric(t.isOverspent ? "Перерасход" : "Остаток", Money.format(t.balance), tint: t.isOverspent ? Color.rkBad : Color.rkGood, big: true)
            metric("Возвращено", Money.format(t.returned))
            metric("Покупок", "\(t.purchaseCount)")
            metric("Чеков", "\(t.receiptCount)")
            metric("Без чеков", "\(t.noReceiptPurchases)")
        }
        .padding(.vertical, 12)
        .background(Color.rkCard)
    }

    private func metric(_ title: String, _ value: String, tint: Color? = nil, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(big ? .title2.weight(.bold) : .title3.weight(.semibold)).foregroundStyle(tint ?? .primary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Крупная фотография чека

struct ReceiptPreview: View {
    @ObservedObject var receipt: RReceipt
    let onOpen: () -> Void
    var body: some View {
        ZStack {
            Color.rkSoft
            if let ph = receipt.photoList.first, let cg = ThumbCache.image(for: ph) {
                Button(action: onOpen) {
                    Image(decorative: cg, scale: 1).resizable().scaledToFit().padding(8)
                }
                .buttonStyle(.plain)
                .help("Нажмите, чтобы открыть в увеличенном виде (⌘Y)")
                .overlay(alignment: .bottomTrailing) {
                    if receipt.photoList.count > 1 {
                        Text("фото: \(receipt.photoList.count)").font(.caption2).padding(5).background(.regularMaterial).clipShape(Capsule()).padding(10)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: receipt.noReceipt ? "square.and.pencil" : "photo").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(receipt.noReceipt ? "Покупка без чека" : "Фотографии нет").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 250)
    }
}

// MARK: - Массовое редактирование

struct BulkEditSheet: View {
    let project: RProject
    let rows: [PurchaseRow]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var ctx
    @EnvironmentObject private var saver: SaveCoordinator
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \RCategory.sortOrder, ascending: true)]) private var categories: FetchedResults<RCategory>

    @State private var setCategory = false
    @State private var categoryID: NSManagedObjectID?
    @State private var addScene = false
    @State private var sceneID: NSManagedObjectID?
    @State private var setPurpose = false
    @State private var purpose = ""
    @State private var setDate = false
    @State private var date = Date()
    @State private var setStore = false
    @State private var store = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Изменить у выбранных позиций: \(rows.count)") {
                    Toggle("Категория", isOn: $setCategory)
                    if setCategory {
                        Picker("Категория", selection: $categoryID) {
                            Text("Не выбрана").tag(NSManagedObjectID?.none)
                            ForEach(categories, id: \.objectID) { Text($0.name).tag(Optional($0.objectID)) }
                        }
                    }
                    Toggle("Добавить сцену", isOn: $addScene)
                    if addScene {
                        Picker("Сцена", selection: $sceneID) {
                            Text("Не выбрана").tag(NSManagedObjectID?.none)
                            ForEach(project.sceneList, id: \.objectID) { Text($0.displayTitle).tag(Optional($0.objectID)) }
                        }
                    }
                    Toggle("Назначение / комментарий", isOn: $setPurpose)
                    if setPurpose { TextField("Назначение", text: $purpose) }
                    Toggle("Дата покупки", isOn: $setDate)
                    if setDate { DatePicker("Дата", selection: $date, displayedComponents: .date) }
                    Toggle("Магазин", isOn: $setStore)
                    if setStore { StoreField(value: $store) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Массовое редактирование")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Применить") { apply(); dismiss() } }
            }
        }
        .frame(width: 480, height: 460)
    }

    private func apply() {
        var receiptsDone = Set<NSManagedObjectID>()
        for row in rows {
            if let p = try? ctx.existingObject(with: row.id) as? RPurchase {
                if setCategory { p.category = categories.first { $0.objectID == categoryID } }
                if addScene, let sid = sceneID, let s = project.sceneList.first(where: { $0.objectID == sid }) { p.mutableSetValue(forKey: "scenes").add(s) }
                if setPurpose { p.purpose = purpose }
            }
            if !receiptsDone.contains(row.receiptID), let r = try? ctx.existingObject(with: row.receiptID) as? RReceipt {
                if setDate { r.date = date }
                if setStore { r.store = store }
                r.touch()
                receiptsDone.insert(row.receiptID)
            }
        }
        saver.saveNow()
    }
}
