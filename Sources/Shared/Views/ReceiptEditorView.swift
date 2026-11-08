import SwiftUI
import CoreData

/// Лист редактирования покупки (iPhone и Mac). Все изменения сохраняются сами; «Готово» просто закрывает лист.
struct ReceiptEditorSheet: View {
    @ObservedObject var receipt: RReceipt
    var isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var saver: SaveCoordinator

    var body: some View {
        NavigationStack {
            ReceiptForm(receipt: receipt)
                .navigationTitle(receipt.noReceipt ? "\(receipt.numberText) · без чека" : "Чек \(receipt.numberText)")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { saver.saveNow(); dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(width: 560, height: 720)
        #endif
        .onAppear { saver.setActive([receipt.objectID]) }
        .onDisappear { saver.setActive([]); saver.saveNow() }
        .onChange(of: receipt.isDeleted) { deleted in if deleted { dismiss() } }
    }
}

struct ReceiptForm: View {
    @ObservedObject var receipt: RReceipt
    @Environment(\.managedObjectContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var ocr: OCRCoordinator
    @EnvironmentObject private var refresher: DataRefresher
    @EnvironmentObject private var saver: SaveCoordinator
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \RCategory.sortOrder, ascending: true), NSSortDescriptor(keyPath: \RCategory.name, ascending: true)])
    private var categories: FetchedResults<RCategory>

    struct ViewerTarget: Identifiable { let id = UUID(); let photos: [RPhoto]; let index: Int }
    struct ReplaceTarget: Identifiable { let id = UUID(); let photo: RPhoto }

    @State private var viewer: ViewerTarget?
    @State private var replacing: ReplaceTarget?
    @State private var confirmDelete = false
    @State private var showRaw = false

    private static let dateRowHeight: CGFloat = 34

    var body: some View {
        let _ = refresher.tick
        let review = ocr.review[receipt.objectID] ?? []
        ScrollView {
            VStack(spacing: 14) {
                statusBanner(review)
                RKSection("Чек") {
                    // номер слева, дата справа — одна строка, общая высота и центровка по вертикали
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("Номер и дата покупки").font(.caption).foregroundStyle(.secondary)
                            if review.contains("дата") {
                                Text("проверьте").font(.caption2.weight(.semibold)).foregroundStyle(Color.rkWarn)
                            }
                        }
                        HStack(alignment: .center, spacing: 12) {
                            Text(receipt.numberText)
                                .font(.title3.monospacedDigit().weight(.bold))
                                .frame(height: Self.dateRowHeight, alignment: .center)
                            Spacer(minLength: 8)
                            DatePicker("Дата покупки", selection: Binding(get: { receipt.date ?? Date() }, set: { receipt.date = $0 }), displayedComponents: .date)
                                .labelsHidden()
                                #if os(macOS)
                                .datePickerStyle(.field)
                                #endif
                                .fixedSize()
                                .frame(height: Self.dateRowHeight, alignment: .center)
                        }
                    }
                    RKLabeled(title: "Магазин / организация", warn: review.contains("магазин") ? "проверьте" : nil) {
                        StoreField(value: $receipt.store, warn: review.contains("магазин"))
                    }
                    Toggle("Покупка без чека", isOn: $receipt.noReceipt)
                    RKLabeled(title: "Комментарий к чеку") {
                        RKTextField(title: "Комментарий", value: $receipt.comment, axis: .vertical)
                    }
                }
                ForEach(Array(receipt.purchaseList.enumerated()), id: \.element.objectID) { idx, item in
                    ItemSection(purchase: item, index: idx + 1, categories: Array(categories), project: receipt.project,
                                warnAmount: review.contains("сумма"), onDelete: {
                        ctx.delete(item)
                    })
                }
                RKSection {
                    Button { DataOps.addItem(ctx, to: receipt) } label: { Label("Добавить позицию", systemImage: "plus.circle") }
                        .buttonStyle(RKSecondaryButtonStyle())
                    HStack {
                        Text("Сумма чека").foregroundStyle(.secondary)
                        Spacer()
                        Text(Money.format(receipt.itemsSum)).font(.title3.weight(.semibold).monospacedDigit())
                    }
                    if receipt.purchaseList.count > 1 {
                        Text("Все позиции этого чека имеют общий номер \(receipt.numberText).").font(.caption).foregroundStyle(.secondary)
                    }
                }
                photoCard   // фотографии — ниже формы
                if !receipt.rawText.isEmpty {
                    RKSection {
                        DisclosureGroup("Распознанный текст", isExpanded: $showRaw) {
                            Text(receipt.rawText).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Удалить чек", systemImage: "trash") }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 6)
            }
            .padding(14)
        }
        .background(Color.rkBackground)
        .confirmationDialog("Удалить чек \(receipt.numberText) вместе с позициями и фотографиями?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { ctx.delete(receipt); dismiss() }
            Button("Отмена", role: .cancel) {}
        }
        #if os(iOS)
        .fullScreenCover(item: $viewer) { v in PhotoViewer(photos: v.photos, index: v.index) }
        #else
        .sheet(item: $viewer) { v in PhotoViewer(photos: v.photos, index: v.index) }
        #endif
        .sheet(item: $replacing) { target in
            VStack(spacing: 14) {
                Text("Заменить фотографию").font(.headline)
                PhotoSourceMenu(inline: true, onPicked: { datas, _ in
                    if let d = datas.first {
                        target.photo.data = d
                        target.photo.thumb = ImageTools.thumbnailJPEG(from: d)
                        target.photo.fileExtension = ImageTools.fileExtension(for: d)
                        ThumbCache.invalidate(target.photo)
                        receipt.touch()
                    }
                    replacing = nil
                }, label: { EmptyView() })
                .buttonStyle(.bordered).controlSize(.large)
                Button("Отмена") { replacing = nil }
            }
            .padding(24)
            .presentationDetents([.medium])
        }
    }

    // MARK: Разделы

    @ViewBuilder private func statusBanner(_ review: [String]) -> some View {
        if ocr.running.contains(receipt.objectID) {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Распознаём чек…") }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.rkAccent.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if ocr.failed.contains(receipt.objectID) {
            StatusBanner(text: "Чек не удалось уверенно прочитать. Заполните данные вручную — фото сохранено.", icon: "exclamationmark.triangle.fill", tint: .rkWarn)
        } else if !review.isEmpty {
            StatusBanner(text: "Данные распознаны автоматически. Проверьте: \(review.joined(separator: ", ")) — распознавание было неуверенным.",
                         icon: "exclamationmark.triangle.fill", tint: .rkWarn)
        }
    }

    @ViewBuilder private var photoCard: some View {
        RKSection("Фотографии чека") {
            let photos = receipt.photoList
            if !photos.isEmpty {
                PhotoStrip(photos: photos, height: 120,
                           onOpen: { ph in viewer = ViewerTarget(photos: photos, index: photos.firstIndex(of: ph) ?? 0) },
                           onReplace: { ph in replacing = ReplaceTarget(photo: ph) },
                           onDelete: { ph in ctx.delete(ph) })
            }
            HStack(spacing: 10) {
                PhotoSourceMenu(onPicked: { datas, _ in
                    for d in datas { DataOps.addPhoto(ctx, data: d, to: receipt) }
                    if receipt.noReceipt { receipt.noReceipt = false }
                    saver.saveNow()   // фото сразу записывается и связывается с покупкой
                    if receipt.rawText.isEmpty && receipt.purchaseList.allSatisfy({ $0.amountKop == 0 }) { OCRCoordinator.shared.recognize(receipt) }
                }, label: { Label(photos.isEmpty ? "Добавить фото чека" : "Добавить ещё фото", systemImage: "camera.badge.ellipsis") })
                .buttonStyle(RKSecondaryButtonStyle())
                if !photos.isEmpty {
                    Button { OCRCoordinator.shared.recognize(receipt, force: true) } label: { Label("Распознать заново", systemImage: "text.viewfinder") }
                        .buttonStyle(RKSecondaryButtonStyle())
                        .disabled(ocr.running.contains(receipt.objectID))
                }
            }
        }
    }
}

/// Одна товарная позиция чека.
struct ItemSection: View {
    @ObservedObject var purchase: RPurchase
    let index: Int
    let categories: [RCategory]
    let project: RProject?
    var warnAmount = false
    let onDelete: () -> Void
    @Environment(\.managedObjectContext) private var ctx
    @State private var showScenes = false
    @State private var viewer: PhotoViewerTarget?
    struct PhotoViewerTarget: Identifiable { let id = UUID(); let photos: [RPhoto]; let index: Int }

    var body: some View {
        RKSection("Позиция \(index)") {
            RKLabeled(title: "Наименование товара") {
                RKTextField(title: "Что куплено", value: $purchase.title)
            }
            HStack(alignment: .top, spacing: 12) {
                RKLabeled(title: "Сумма", warn: warnAmount ? "проверьте" : nil) {
                    AmountField(title: "0", kop: Binding(get: { purchase.amountKop }, set: { purchase.amountKop = $0 }), warn: warnAmount)
                }
                RKLabeled(title: "Кол-во") {
                    RKTextField(title: "1", value: Binding(get: { quantityText }, set: { setQuantity($0) }))
                        .frame(maxWidth: 90)
                }
            }
            RKLabeled(title: "Категория") {
                Picker("Категория", selection: Binding<NSManagedObjectID?>(get: { purchase.category?.objectID }, set: { id in
                    purchase.category = categories.first { $0.objectID == id }
                })) {
                    Text("Не выбрана").tag(NSManagedObjectID?.none)
                    ForEach(categories, id: \.objectID) { c in Text(c.name).tag(Optional(c.objectID)) }
                }
                .labelsHidden()
            }
            RKLabeled(title: "Сцены") {
                Button { showScenes = true } label: {
                    HStack {
                        Text(purchase.scenesText.isEmpty ? "Не выбраны" : purchase.scenesText).foregroundStyle(purchase.scenesText.isEmpty ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .rkField()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            RKLabeled(title: "Назначение / комментарий") {
                RKTextField(title: "Для какой сцены, зачем куплено", value: $purchase.purpose, axis: .vertical)
            }
            let photos = purchase.itemPhotoList
            if !photos.isEmpty {
                PhotoStrip(photos: photos, height: 70,
                           onOpen: { ph in viewer = PhotoViewerTarget(photos: photos, index: photos.firstIndex(of: ph) ?? 0) },
                           onReplace: { ph in ctx.delete(ph) },
                           onDelete: { ph in ctx.delete(ph) })
            }
            HStack {
                PhotoSourceMenu(onPicked: { datas, _ in
                    for d in datas { DataOps.addItemPhoto(ctx, data: d, to: purchase) }
                }, label: { Label("Фото товара", systemImage: "photo.badge.plus") })
                Spacer()
                Button(role: .destructive) { onDelete() } label: { Label("Удалить позицию", systemImage: "trash") }
            }
            .buttonStyle(.borderless)
        }
        .sheet(isPresented: $showScenes) {
            if let project = project { SceneSelectionSheet(purchase: purchase, project: project) }
        }
        #if os(iOS)
        .fullScreenCover(item: $viewer) { v in PhotoViewer(photos: v.photos, index: v.index) }
        #else
        .sheet(item: $viewer) { v in PhotoViewer(photos: v.photos, index: v.index) }
        #endif
    }

    private var quantityText: String {
        let q = purchase.quantity
        if q == q.rounded() { return String(Int(q)) }
        return String(q).replacingOccurrences(of: ".", with: ",")
    }

    private func setQuantity(_ text: String) {
        let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let v = Double(normalized), v > 0 { if purchase.quantity != v { purchase.quantity = v } }
        else if normalized.isEmpty { if purchase.quantity != 1 { purchase.quantity = 1 } }
    }
}

struct SceneSelectionSheet: View {
    @ObservedObject var purchase: RPurchase
    @ObservedObject var project: RProject
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var ctx
    @State private var newCode = ""
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(project.sceneList, id: \.objectID) { s in
                        let selected = purchase.sceneList.contains(s)
                        Button {
                            let set = purchase.mutableSetValue(forKey: "scenes")
                            if selected { set.remove(s) } else { set.add(s) }
                        } label: {
                            HStack {
                                Text(s.displayTitle)
                                Spacer()
                                if selected { Image(systemName: "checkmark").foregroundStyle(Color.rkAccent) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    if project.sceneList.isEmpty { Text("Сцен пока нет. Добавьте первую ниже — покупку можно привязать сразу к нескольким сценам.") }
                }
                Section("Новая сцена") {
                    HStack {
                        TextField("№", text: $newCode).frame(width: 60)
                        TextField("Описание (например, квартира героя)", text: $newTitle)
                    }
                    Button("Добавить и выбрать") {
                        let s = RScene(context: ctx)
                        s.code = newCode.trimmingCharacters(in: .whitespaces)
                        s.title = newTitle.trimmingCharacters(in: .whitespaces)
                        s.sortOrder = Int32(project.sceneList.count)
                        s.project = project
                        purchase.mutableSetValue(forKey: "scenes").add(s)
                        newCode = ""; newTitle = ""
                    }
                    .disabled(newCode.trimmingCharacters(in: .whitespaces).isEmpty && newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Сцены")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 440, height: 480)
        #endif
    }
}
