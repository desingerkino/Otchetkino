import SwiftUI
import CoreData

/// Лист редактирования чека (iPhone и Mac): «Закрыть» оставляет чек черновиком, «Сохранить» подтверждает.
struct ReceiptEditorSheet: View {
    @ObservedObject var receipt: RReceipt
    var isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var ctx

    var body: some View {
        NavigationStack {
            ReceiptForm(receipt: receipt)
                .navigationTitle(receipt.noReceipt ? "\(receipt.numberText) · без чека" : "Чек \(receipt.numberText)")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(receipt.isDraft ? "Закрыть" : "Готово") { try? ctx.save(); dismiss() }
                    }
                    if receipt.isDraft {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Сохранить") { receipt.isDraft = false; receipt.touch(); try? ctx.save(); dismiss() }
                                .disabled(receipt.purchaseList.isEmpty)
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(width: 560, height: 720)
        #endif
        .onChange(of: receipt.isDeleted) { deleted in if deleted { dismiss() } }
    }
}

struct ReceiptForm: View {
    @ObservedObject var receipt: RReceipt
    @Environment(\.managedObjectContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var ocr: OCRCoordinator
    @EnvironmentObject private var refresher: DataRefresher
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \RCategory.sortOrder, ascending: true), NSSortDescriptor(keyPath: \RCategory.name, ascending: true)])
    private var categories: FetchedResults<RCategory>

    struct ViewerTarget: Identifiable { let id = UUID(); let photos: [RPhoto]; let index: Int }
    struct ReplaceTarget: Identifiable { let id = UUID(); let photo: RPhoto }

    @State private var viewer: ViewerTarget?
    @State private var replacing: ReplaceTarget?
    @State private var confirmDelete = false
    @State private var showRaw = false

    var body: some View {
        let _ = refresher.tick
        Form {
            statusSection
            photoSection
            Section("Чек") {
                LabeledContent("Номер", value: receipt.numberText)
                DatePicker("Дата покупки", selection: Binding(get: { receipt.date ?? Date() }, set: { receipt.date = $0 }), displayedComponents: .date)
                TextField("Магазин / организация", text: $receipt.store)
                TextField("ИНН продавца", text: $receipt.inn)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Toggle("Без чека", isOn: $receipt.noReceipt)
                TextField("Комментарий к чеку", text: $receipt.comment, axis: .vertical)
            }
            ForEach(Array(receipt.purchaseList.enumerated()), id: \.element.objectID) { idx, item in
                ItemSection(purchase: item, index: idx + 1, categories: Array(categories), project: receipt.project, onDelete: {
                    ctx.delete(item); try? ctx.save()
                })
            }
            Section {
                Button { DataOps.addItem(ctx, to: receipt); try? ctx.save() } label: { Label("Добавить позицию", systemImage: "plus.circle") }
                LabeledContent("Сумма чека") { Text(Money.format(receipt.itemsSum)).font(.headline) }
            } footer: {
                if receipt.purchaseList.count > 1 { Text("Все позиции этого чека имеют общий номер \(receipt.numberText).") }
            }
            if !receipt.rawText.isEmpty {
                Section {
                    DisclosureGroup("Распознанный текст", isExpanded: $showRaw) {
                        Text(receipt.rawText).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Удалить чек", systemImage: "trash") }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .onDisappear { if ctx.hasChanges { try? ctx.save() } }
        .confirmationDialog("Удалить чек \(receipt.numberText) вместе с позициями и фотографиями?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { ctx.delete(receipt); try? ctx.save(); dismiss() }
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
                        receipt.touch(); try? ctx.save()
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

    @ViewBuilder private var statusSection: some View {
        if ocr.running.contains(receipt.objectID) {
            Section { HStack(spacing: 10) { ProgressView(); Text("Распознаём чек…") } }
        } else if receipt.isDraft {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    if ocr.failed.contains(receipt.objectID) {
                        StatusBanner(text: "Чек не удалось уверенно прочитать. Заполните данные вручную — фото сохранено.", icon: "exclamationmark.triangle.fill")
                    } else if !receipt.rawText.isEmpty {
                        StatusBanner(text: "Данные распознаны автоматически. Проверьте дату, магазин и суммы, затем подтвердите.")
                    } else {
                        StatusBanner(text: "Черновик. Заполните данные и подтвердите покупку.")
                    }
                    HStack {
                        Button { receipt.isDraft = false; receipt.touch(); try? ctx.save() } label: { Label("Подтвердить покупку", systemImage: "checkmark.circle.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(receipt.purchaseList.isEmpty)
                        if !receipt.photoList.isEmpty {
                            Button { OCRCoordinator.shared.recognize(receipt) } label: { Label("Распознать заново", systemImage: "text.viewfinder") }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var photoSection: some View {
        Section("Фотографии чека") {
            let photos = receipt.photoList
            if !photos.isEmpty {
                PhotoStrip(photos: photos, height: 120,
                           onOpen: { ph in viewer = ViewerTarget(photos: photos, index: photos.firstIndex(of: ph) ?? 0) },
                           onReplace: { ph in replacing = ReplaceTarget(photo: ph) },
                           onDelete: { ph in ctx.delete(ph); try? ctx.save() })
            }
            PhotoSourceMenu(onPicked: { datas, _ in
                for d in datas { DataOps.addPhoto(ctx, data: d, to: receipt) }
                if receipt.noReceipt { receipt.noReceipt = false }
                try? ctx.save()
                if receipt.rawText.isEmpty && receipt.purchaseList.allSatisfy({ $0.amountKop == 0 }) { OCRCoordinator.shared.recognize(receipt) }
            }, label: { Label(photos.isEmpty ? "Добавить фото чека" : "Добавить ещё фото", systemImage: "camera.badge.ellipsis") })
        }
    }
}

/// Одна товарная позиция чека.
struct ItemSection: View {
    @ObservedObject var purchase: RPurchase
    let index: Int
    let categories: [RCategory]
    let project: RProject?
    let onDelete: () -> Void
    @Environment(\.managedObjectContext) private var ctx
    @State private var showScenes = false
    @State private var viewer: PhotoViewerTarget?
    struct PhotoViewerTarget: Identifiable { let id = UUID(); let photos: [RPhoto]; let index: Int }

    var body: some View {
        Section("Позиция \(index)") {
            TextField("Наименование товара", text: $purchase.title)
            HStack {
                AmountField(title: "Сумма, ₽", kop: Binding(get: { purchase.amountKop }, set: { purchase.amountKop = $0 }))
                Divider()
                TextField("Кол-во", value: $purchase.quantity, format: .number)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .frame(maxWidth: 80)
            }
            Picker("Категория", selection: Binding<NSManagedObjectID?>(get: { purchase.category?.objectID }, set: { id in
                purchase.category = categories.first { $0.objectID == id }
            })) {
                Text("Не выбрана").tag(NSManagedObjectID?.none)
                ForEach(categories, id: \.objectID) { c in Text(c.name).tag(Optional(c.objectID)) }
            }
            Button { showScenes = true } label: {
                HStack {
                    Text("Сцены")
                    Spacer()
                    Text(purchase.scenesText.isEmpty ? "Не выбраны" : purchase.scenesText).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            TextField("Назначение / комментарий (для какой сцены, зачем куплено)", text: $purchase.purpose, axis: .vertical)
            let photos = purchase.itemPhotoList
            if !photos.isEmpty {
                PhotoStrip(photos: photos, height: 70,
                           onOpen: { ph in viewer = PhotoViewerTarget(photos: photos, index: photos.firstIndex(of: ph) ?? 0) },
                           onReplace: { ph in ctx.delete(ph); try? ctx.save() },
                           onDelete: { ph in ctx.delete(ph); try? ctx.save() })
            }
            HStack {
                PhotoSourceMenu(onPicked: { datas, _ in
                    for d in datas { DataOps.addItemPhoto(ctx, data: d, to: purchase) }
                    try? ctx.save()
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
                            try? ctx.save()
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
                        try? ctx.save()
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
