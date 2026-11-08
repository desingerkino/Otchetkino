import SwiftUI
import CoreData

struct ReceiptsView: View {
    @ObservedObject var project: RProject
    @EnvironmentObject private var refresher: DataRefresher
    @Environment(\.managedObjectContext) private var ctx
    @State private var query = ""
    @State private var editing: EditTarget?
    @State private var toDelete: RReceipt?

    var body: some View {
        let _ = refresher.tick
        let q = query.lowercased()
        let receipts = project.receiptList.reversed().filter {
            q.isEmpty || "\($0.numberText) \($0.store) \($0.comment) \($0.purchaseList.map { $0.title }.joined(separator: " "))".lowercased().contains(q)
        }
        NavigationStack {
            List {
                if receipts.isEmpty {
                    Text(project.receiptList.isEmpty ? "Чеков пока нет." : "Ничего не найдено.").foregroundStyle(.secondary)
                }
                ForEach(receipts, id: \.objectID) { r in
                    Button { editing = EditTarget(receipt: r) } label: { ReceiptRowView(receipt: r) }
                        .buttonStyle(.plain)
                        .swipeActions { Button("Удалить", role: .destructive) { toDelete = r } }
                }
            }
            .searchable(text: $query, prompt: "Номер, магазин, товар")
            .navigationTitle("Чеки")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) { AddPurchaseButton(project: project) { Label("Добавить", systemImage: "plus") } }
            }
            .sheet(item: $editing) { t in ReceiptEditorSheet(receipt: t.receipt, isNew: false) }
            .alert("Удалить покупку \(toDelete?.numberText ?? "") вместе со всеми данными и фотографиями чека?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
                Button("Отмена", role: .cancel) { toDelete = nil }
                Button("Удалить", role: .destructive) { if let r = toDelete { DataOps.deleteReceipts(ctx, [r]); try? ctx.save() }; toDelete = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct ReceiptRowView: View {
    @ObservedObject var receipt: RReceipt
    var body: some View {
        HStack(spacing: 12) {
            if let ph = receipt.photoList.first {
                PhotoThumb(photo: ph, height: 56)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15))
                    Image(systemName: receipt.noReceipt ? "square.and.pencil" : "doc").foregroundStyle(.secondary)
                }
                .frame(width: 42, height: 56)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(receipt.numberText).font(.headline)
                    if receipt.noReceipt { Text("без чека").font(.caption).foregroundStyle(.secondary) }
                }
                Text(receipt.storeText).lineLimit(1)
                Text("\(Fmt.date.string(from: receipt.date ?? Date())) · позиций: \(receipt.purchaseList.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Money.format(receipt.itemsSum)).fontWeight(.semibold)
        }
        .contentShape(Rectangle())
    }
}
