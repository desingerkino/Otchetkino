import SwiftUI
import CoreData
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Миниатюры

private final class CGBox { let image: CGImage; init(_ i: CGImage) { image = i } }

enum ThumbCache {
    private static let cache = NSCache<NSManagedObjectID, CGBox>()
    static func image(for photo: RPhoto) -> CGImage? {
        if let b = cache.object(forKey: photo.objectID) { return b.image }
        guard let d = photo.thumb ?? photo.data, let cg = ImageTools.cgImage(from: d, maxPixel: 900) else { return nil }
        cache.setObject(CGBox(cg), forKey: photo.objectID)
        return cg
    }
    static func invalidate(_ photo: RPhoto) { cache.removeObject(forKey: photo.objectID) }
}

struct PhotoThumb: View {
    @ObservedObject var photo: RPhoto
    var height: CGFloat = 90
    var body: some View {
        Group {
            if let cg = ThumbCache.image(for: photo) {
                Image(decorative: cg, scale: 1).resizable().scaledToFill()
            } else {
                ZStack { Color.gray.opacity(0.15); Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .frame(width: height * 0.75, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.gray.opacity(0.25), lineWidth: 0.5))
    }
}

/// Лента фотографий с меню «открыть / заменить / удалить».
struct PhotoStrip: View {
    let photos: [RPhoto]
    var height: CGFloat = 100
    let onOpen: (RPhoto) -> Void
    let onReplace: (RPhoto) -> Void
    let onDelete: (RPhoto) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(photos, id: \.objectID) { ph in
                    PhotoThumb(photo: ph, height: height)
                        .onTapGesture { onOpen(ph) }
                        .overlay(alignment: .topTrailing) {
                            Menu {
                                Button { onOpen(ph) } label: { Label("Открыть", systemImage: "arrow.up.left.and.arrow.down.right") }
                                Button { onReplace(ph) } label: { Label("Заменить…", systemImage: "arrow.triangle.2.circlepath") }
                                Button(role: .destructive) { onDelete(ph) } label: { Label("Удалить", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.black.opacity(0.55))
                                    .font(.title3)
                                    .padding(4)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Просмотр в полном размере

struct PhotoViewer: View {
    let photos: [RPhoto]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let cg = image {
                Image(decorative: cg, scale: 1)
                    .resizable().scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = max(1, min(8, baseScale * $0)) }
                            .onEnded { _ in baseScale = scale; if scale == 1 { offset = .zero; baseOffset = .zero } }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { v in if scale > 1 { offset = CGSize(width: baseOffset.width + v.translation.width, height: baseOffset.height + v.translation.height) } }
                            .onEnded { _ in baseOffset = offset }
                    )
                    .onTapGesture(count: 2) { reset(toggle: true) }
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    if photos.count > 1 {
                        Button { step(-1) } label: { Image(systemName: "chevron.left.circle.fill") }.disabled(index == 0)
                        Text("\(index + 1) из \(photos.count)").foregroundStyle(.white).font(.callout)
                        Button { step(1) } label: { Image(systemName: "chevron.right.circle.fill") }.disabled(index >= photos.count - 1)
                    }
                    Spacer()
                    Button { zoom(0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { zoom(-0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                        .keyboardShortcut(.cancelAction)
                }
                .font(.title2)
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .padding()
                Spacer()
            }
        }
        .task(id: index) { await load() }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 640)
        #endif
    }

    private func zoom(_ delta: CGFloat) {
        scale = max(1, min(8, scale - delta)); baseScale = scale
        if scale == 1 { offset = .zero; baseOffset = .zero }
    }
    private func reset(toggle: Bool) {
        withAnimation { scale = (toggle && scale == 1) ? 2.5 : 1; baseScale = scale; if scale == 1 { offset = .zero; baseOffset = .zero } }
    }
    private func step(_ d: Int) {
        let n = index + d
        guard photos.indices.contains(n) else { return }
        index = n; scale = 1; baseScale = 1; offset = .zero; baseOffset = .zero
    }
    private func load() async {
        image = nil
        guard photos.indices.contains(index), let data = photos[index].data else { return }
        let cg = await Task.detached(priority: .userInitiated) { ImageTools.cgImage(from: data, maxPixel: 6000) }.value
        image = cg
    }
}

// MARK: - Чтение файлов

enum FileImport {
    static func readImages(_ urls: [URL]) -> [Data] {
        var result: [Data] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let type = UTType(filenameExtension: url.pathExtension), !type.conforms(to: .image) { continue }
            if let d = try? Data(contentsOf: url), CGImageSourceCheck(d) { result.append(d) }
        }
        return result
    }
    private static func CGImageSourceCheck(_ d: Data) -> Bool { ImageTools.cgImage(from: d, maxPixel: 16) != nil }
}

// MARK: - Источник фотографий

enum PhotoSourceKind { case scan, other }

/// Меню «добавить фото». На iPhone: сканер документов, камера, галерея, файлы. На Mac: выбор файлов.
struct PhotoSourceMenu<Label: View>: View {
    var inline = false
    var manualTitle: String? = nil
    var onManual: (() -> Void)? = nil
    let onPicked: ([Data], PhotoSourceKind) -> Void
    @ViewBuilder var label: () -> Label

    @State private var showFiles = false
    #if os(iOS)
    @State private var showScanner = false
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var items: [PhotosPickerItem] = []
    #endif

    var body: some View {
        container
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    let datas = FileImport.readImages(urls)
                    if !datas.isEmpty { onPicked(datas, .other) }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView { datas in showScanner = false; if !datas.isEmpty { onPicked(datas, .scan) } }.ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPickerView { data in showCamera = false; if let d = data { onPicked([d], .other) } }.ignoresSafeArea()
            }
            .photosPicker(isPresented: $showPhotos, selection: $items, maxSelectionCount: 30, matching: .images)
            .onChange(of: items) { newItems in
                guard !newItems.isEmpty else { return }
                Task {
                    var datas: [Data] = []
                    for it in newItems { if let d = try? await it.loadTransferable(type: Data.self) { datas.append(d) } }
                    items = []
                    if !datas.isEmpty { onPicked(datas, .other) }
                }
            }
            #endif
    }

    @ViewBuilder private var container: some View {
        if inline {
            VStack(spacing: 10) { buttons }
        } else {
            Menu { buttons } label: { label() }
        }
    }

    @ViewBuilder private var buttons: some View {
        #if os(iOS)
        if DocumentScannerView.isSupported {
            Button { showScanner = true } label: { Label("Сканировать чек", systemImage: "doc.viewfinder") }
        }
        if CameraPickerView.isSupported {
            Button { showCamera = true } label: { Label("Снять фото", systemImage: "camera") }
        }
        Button { showPhotos = true } label: { Label("Выбрать из галереи", systemImage: "photo.on.rectangle") }
        Button { showFiles = true } label: { Label("Выбрать из файлов", systemImage: "folder") }
        #else
        Button { showFiles = true } label: { Label("Выбрать файлы…", systemImage: "photo.on.rectangle") }
        #endif
        if let manual = onManual {
            Divider()
            Button { manual() } label: { Label(manualTitle ?? "Без чека — вручную", systemImage: "square.and.pencil") }
        }
    }
}

// MARK: - Создание покупок из фотографий

enum AddFlow {
    /// Создаёт черновики чеков из фотографий и запускает распознавание. Возвращает созданные чеки.
    @MainActor
    static func create(from datas: [Data], kind: PhotoSourceKind, project: RProject, ctx: NSManagedObjectContext) -> [RReceipt] {
        var created: [RReceipt] = []
        if kind == .scan {
            created.append(DataOps.createReceipt(ctx, project: project, photos: datas, noReceipt: false))
        } else {
            for d in datas { created.append(DataOps.createReceipt(ctx, project: project, photos: [d], noReceipt: false)) }
        }
        try? ctx.save()
        for r in created { OCRCoordinator.shared.recognize(r) }
        return created
    }

    @MainActor
    static func createManual(project: RProject, ctx: NSManagedObjectContext) -> RReceipt {
        let r = DataOps.createReceipt(ctx, project: project, photos: [], noReceipt: true)
        DataOps.addItem(ctx, to: r)
        try? ctx.save()
        return r
    }
}

/// Большая кнопка «+ Добавить покупку» с выбором источника и переходом к проверке.
struct AddPurchaseButton<Label: View>: View {
    let project: RProject
    @Environment(\.managedObjectContext) private var ctx
    @EnvironmentObject private var app: AppState
    @State private var editing: EditTarget?
    @ViewBuilder var label: () -> Label

    var body: some View {
        PhotoSourceMenu(manualTitle: "Без чека — вручную", onManual: {
            editing = EditTarget(receipt: AddFlow.createManual(project: project, ctx: ctx))
        }, onPicked: { datas, kind in
            let made = AddFlow.create(from: datas, kind: kind, project: project, ctx: ctx)
            if made.count == 1 { editing = EditTarget(receipt: made[0]) }
            else if made.count > 1 { app.alertMessage = "Добавлено чеков: \(made.count). Они появились в разделе «Чеки» как черновики — откройте каждый, проверьте распознанные данные и подтвердите." }
        }, label: label)
        .sheet(item: $editing) { target in ReceiptEditorSheet(receipt: target.receipt, isNew: true) }
    }
}
