import SwiftUI
import CoreData

struct PurchaseFilter: Equatable {
    var text = ""
    var categoryID: NSManagedObjectID?
    var sceneID: NSManagedObjectID?
    /// 0 — все, 1 — только с чеком, 2 — только без чека
    var receiptMode = 0
    var useDates = false
    var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    var to = Date()

    var isActive: Bool { categoryID != nil || sceneID != nil || receiptMode != 0 || useDates }

    func matches(_ p: RPurchase) -> Bool {
        guard let r = p.receipt else { return false }
        if !text.isEmpty {
            let q = text.lowercased()
            let hay = "\(p.title) \(r.store) \(p.purpose) \(r.comment) \(p.categoryName) \(p.scenesText) \(r.numberText)".lowercased()
            if !hay.contains(q) { return false }
        }
        if let c = categoryID, p.category?.objectID != c { return false }
        if let s = sceneID, !p.sceneList.contains(where: { $0.objectID == s }) { return false }
        if receiptMode == 1 && r.noReceipt { return false }
        if receiptMode == 2 && !r.noReceipt { return false }
        if useDates, let d = r.date {
            let cal = Calendar.current
            if d < cal.startOfDay(for: from) || d >= cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))! { return false }
        }
        return true
    }
}

struct FilterSheet: View {
    @Binding var filter: PurchaseFilter
    let project: RProject
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \RCategory.sortOrder, ascending: true)]) private var categories: FetchedResults<RCategory>

    var body: some View {
        NavigationStack {
            Form {
                Section("Категория") {
                    Picker("Категория", selection: $filter.categoryID) {
                        Text("Любая").tag(NSManagedObjectID?.none)
                        ForEach(categories, id: \.objectID) { c in Text(c.name).tag(Optional(c.objectID)) }
                    }
                }
                Section("Сцена") {
                    Picker("Сцена", selection: $filter.sceneID) {
                        Text("Любая").tag(NSManagedObjectID?.none)
                        ForEach(project.sceneList, id: \.objectID) { s in Text(s.displayTitle).tag(Optional(s.objectID)) }
                    }
                }
                Section("Чек") {
                    Picker("Наличие чека", selection: $filter.receiptMode) {
                        Text("Все").tag(0); Text("С чеком").tag(1); Text("Без чека").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Даты") {
                    Toggle("Ограничить по датам", isOn: $filter.useDates)
                    if filter.useDates {
                        DatePicker("С", selection: $filter.from, displayedComponents: .date)
                        DatePicker("По", selection: $filter.to, displayedComponents: .date)
                    }
                }
                Section { Button("Сбросить фильтры", role: .destructive) { let t = filter.text; filter = PurchaseFilter(); filter.text = t } }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Фильтры")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 420, height: 520)
        #endif
    }
}

struct PurchasesView: View {
    @ObservedObject var project: RProject
    @EnvironmentObject private var refresher: DataRefresher
    @Environment(\.managedObjectContext) private var ctx
    @State private var filter = PurchaseFilter()
    @State private var showFilters = false
    @State private var editing: EditTarget?
    @State private var toDelete: RPurchase?

    var body: some View {
        let _ = refresher.tick
        let all = project.confirmedReceipts.flatMap { $0.purchaseList }
        let items = all.filter { filter.matches($0) }.sorted {
            ($0.receipt?.number ?? 0, $0.sortOrder) > ($1.receipt?.number ?? 0, $1.sortOrder)
        }
        NavigationStack {
            List {
                if items.isEmpty {
                    Text(all.isEmpty ? "Покупок пока нет. Нажмите «+», чтобы добавить первую." : "Ничего не найдено по заданным условиям.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(items, id: \.objectID) { p in
                        Button { if let r = p.receipt { editing = EditTarget(receipt: r) } } label: { PurchaseRowView(purchase: p) }
                            .buttonStyle(.plain)
                            .swipeActions { Button("Удалить", role: .destructive) { toDelete = p } }
                    }
                } footer: {
                    if !items.isEmpty { Text("Найдено: \(items.count) · на сумму \(Money.format(items.reduce(0) { $0 + $1.amountKop }))") }
                }
            }
            .searchable(text: $filter.text, prompt: "Поиск по названию, магазину, назначению")
            .navigationTitle("Покупки")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showFilters = true } label: {
                        Label("Фильтры", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    AddPurchaseButton(project: project) { Label("Добавить", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showFilters) { FilterSheet(filter: $filter, project: project) }
            .sheet(item: $editing) { t in ReceiptEditorSheet(receipt: t.receipt, isNew: false) }
            .confirmationDialog("Удалить эту покупку?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { if let p = toDelete { ctx.delete(p); try? ctx.save() }; toDelete = nil }
                Button("Отмена", role: .cancel) { toDelete = nil }
            }
        }
    }
}

struct PurchaseRowView: View {
    @ObservedObject var purchase: RPurchase
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(purchase.title.isEmpty ? "Без названия" : purchase.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(purchase.receipt?.numberText ?? "")
                    if purchase.receipt?.noReceipt == true { Text("· без чека").foregroundStyle(Color.rkAccent) }
                    Text("· \(Fmt.date.string(from: purchase.receipt?.date ?? Date()))")
                }
                .font(.caption).foregroundStyle(.secondary)
                Text([purchase.categoryName, purchase.receipt?.storeText ?? "", purchase.scenesText.isEmpty ? "" : "сц. \(purchase.scenesText)"]
                        .filter { !$0.isEmpty && $0 != "—" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Money.format(purchase.amountKop)).font(.body.weight(.semibold))
        }
        .contentShape(Rectangle())
    }
}
