import SwiftUI
import Charts
import CoreData

struct HomeView: View {
    @ObservedObject var project: RProject
    @EnvironmentObject private var refresher: DataRefresher
    @State private var showProjects = false
    @State private var advanceKind: Int16?
    @State private var editing: EditTarget?

    var body: some View {
        let _ = refresher.tick
        let t = project.totals()
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    summaryCard(t)
                    AddPurchaseButton(project: project) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("ДОБАВИТЬ ПОКУПКУ").fontWeight(.bold)
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .foregroundStyle(.white)
                        .background(Color.rkAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    HStack(spacing: 12) {
                        Button { advanceKind = 0 } label: { Label("Выдача", systemImage: "arrow.down.circle").frame(maxWidth: .infinity) }
                        Button { advanceKind = 1 } label: { Label("Возврат", systemImage: "arrow.uturn.backward.circle").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.bordered).controlSize(.large)

                    if t.draftCount > 0 {
                        StatusBanner(text: "Черновиков, ожидающих проверки: \(t.draftCount). Они не входят в итоги. Откройте раздел «Чеки».", icon: "tray.full.fill")
                    }
                    chartCard
                    recentCard
                }
                .padding()
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(Color.rkBackground)
            .navigationTitle("Главная")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showProjects = true } label: { Label("Проекты", systemImage: "square.stack.3d.up") }
                }
            }
            .sheet(isPresented: $showProjects) { ProjectsListView() }
            .sheet(item: Binding(get: { advanceKind.map { KindBox(kind: $0) } }, set: { advanceKind = $0?.kind })) { box in
                AdvanceSheet(project: project, kind: box.kind)
            }
        }
    }

    struct KindBox: Identifiable { let kind: Int16; var id: Int16 { kind } }

    private func summaryCard(_ t: ProjectTotals) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ПРОЕКТ").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(project.displayName).font(.title2.weight(.bold))
            if !project.holder.isEmpty { Text(project.holder).font(.subheadline).foregroundStyle(.secondary) }
            Divider()
            HStack(alignment: .top) {
                MetricTile(title: "Выдано", value: Money.format(t.issued))
                MetricTile(title: "Потрачено", value: Money.format(t.spent))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(t.isOverspent ? "ПЕРЕРАСХОД" : "ОСТАТОК").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(Money.format(t.balance)).font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(t.isOverspent ? Color.rkBad : Color.primary)
                if t.returned > 0 { Text("Возвращено: \(Money.format(t.returned))").font(.footnote).foregroundStyle(.secondary) }
            }
            if t.issued > 0 {
                ProgressView(value: min(1, max(0, Double(t.spent + t.returned) / Double(t.issued))))
                    .tint(t.isOverspent ? Color.rkBad : Color.rkAccent)
            }
            Divider()
            HStack {
                MetricTile(title: "Покупок", value: "\(t.purchaseCount)")
                MetricTile(title: "Чеков", value: "\(t.receiptCount)")
                MetricTile(title: "Без чеков", value: "\(t.noReceiptPurchases)")
            }
        }
        .card()
    }

    @ViewBuilder private var chartCard: some View {
        let cats = project.categoryTotals()
        if !cats.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Расходы по категориям").font(.headline)
                Chart(cats.prefix(8)) { c in
                    BarMark(x: .value("Сумма", Money.double(c.amount)), y: .value("Категория", c.name))
                        .foregroundStyle(Color.rkAccent.gradient)
                        .annotation(position: .trailing) { Text(Money.format(c.amount, symbol: false)).font(.caption2).foregroundStyle(.secondary) }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(min(cats.count, 8)) * 34 + 10)
            }
            .card()
        }
        let points = project.cumulativeSpending()
        if points.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                Text("Динамика расходов").font(.headline)
                Chart(points) { p in
                    AreaMark(x: .value("Дата", p.date), y: .value("Сумма", p.total)).foregroundStyle(Color.rkAccent.opacity(0.18))
                    LineMark(x: .value("Дата", p.date), y: .value("Сумма", p.total)).foregroundStyle(Color.rkAccent)
                }
                .frame(height: 150)
            }
            .card()
        }
    }

    @ViewBuilder private var recentCard: some View {
        let recent = project.confirmedReceipts.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(5)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Последние покупки").font(.headline)
                ForEach(Array(recent), id: \.objectID) { r in
                    Button { editing = EditTarget(receipt: r) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.purchaseList.first?.title.isEmpty == false ? r.purchaseList[0].title : r.storeText).lineLimit(1)
                                Text("\(r.numberText) · \(Fmt.date.string(from: r.date ?? Date()))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Money.format(r.itemsSum)).fontWeight(.semibold)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .card()
            .sheet(item: $editing) { target in ReceiptEditorSheet(receipt: target.receipt, isNew: false) }
        }
    }
}
