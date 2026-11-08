import SwiftUI
import CoreData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import PDFKit
#endif

enum ReportKind {
    case excel, pdf
    var fileExtension: String { self == .excel ? "xlsx" : "pdf" }
    var title: String { self == .excel ? "Excel" : "PDF" }
    var contentType: UTType { self == .excel ? (UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data) : .pdf }
}

struct BinaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .pdf, UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct GeneratedReport: Identifiable {
    let id = UUID()
    let kind: ReportKind
    let url: URL
    let data: Data
    let filename: String
}

@MainActor
final class ReportController: ObservableObject {
    @Published var busy: ReportKind?
    @Published var last: GeneratedReport?
    @Published var errorText: String?
    @Published var exportDoc: BinaryDocument?
    @Published var exportType: UTType = .data
    @Published var exportName = ""
    @Published var showExporter = false

    enum After { case none, save, print }

    func generate(_ kind: ReportKind, project: RProject, from: Date?, to: Date?, container: NSPersistentContainer, after: After = .none) async {
        guard busy == nil else { return }
        busy = kind
        errorText = nil
        defer { busy = nil }
        try? project.managedObjectContext?.save()
        guard let snap = await ReportService.makeSnapshot(container: container, projectID: project.objectID, from: from, to: to) else {
            errorText = "Не удалось собрать данные проекта."
            return
        }
        if snap.receipts.isEmpty {
            errorText = "В проекте нет подтверждённых покупок за выбранный период — отчёт был бы пустым."
            return
        }
        let data: Data = await Task.detached(priority: .userInitiated) {
            kind == .excel ? XLSXBuilder.build(snap) : PDFBuilder.build(snap)
        }.value
        let name = "Отчёт — \(Fmt.fileSafe(snap.projectName)).\(kind.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic) } catch { errorText = "Не удалось записать файл: \(error.localizedDescription)"; return }
        let report = GeneratedReport(kind: kind, url: url, data: data, filename: name)
        last = report
        switch after {
        case .save: save(report)
        case .print: printReport(report)
        case .none: break
        }
    }

    func save(_ report: GeneratedReport) {
        exportDoc = BinaryDocument(data: report.data)
        exportType = report.kind.contentType
        exportName = (report.filename as NSString).deletingPathExtension
        showExporter = true
    }

    func printReport(_ report: GeneratedReport) {
        #if os(macOS)
        let pdfData: Data
        if report.kind == .pdf { pdfData = report.data } else { errorText = "Печатать можно PDF-версию отчёта."; return }
        guard let doc = PDFDocument(data: pdfData) else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = .landscape
        if let op = doc.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) {
            op.showsPrintPanel = true
            op.run()
        }
        #endif
    }
}

struct ReportExporterModifier: ViewModifier {
    @ObservedObject var controller: ReportController
    func body(content: Content) -> some View {
        content.fileExporter(isPresented: $controller.showExporter, document: controller.exportDoc, contentType: controller.exportType,
                             defaultFilename: controller.exportName) { _ in }
    }
}

extension View {
    func reportExporter(_ controller: ReportController) -> some View { modifier(ReportExporterModifier(controller: controller)) }
}

struct ReportsView: View {
    @ObservedObject var project: RProject
    @EnvironmentObject private var persistence: PersistenceController
    @EnvironmentObject private var refresher: DataRefresher
    @StateObject private var controller = ReportController()
    @State private var useDates = false
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var to = Date()

    var body: some View {
        let _ = refresher.tick
        let t = project.totals(from: useDates ? from : nil, to: useDates ? to : nil)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Отчёт для продюсера").font(.headline)
                        Text("Excel-файл с четырьмя листами: сводка, детализация расходов, реестр чеков и фотографии чеков. Фотографии вставляются прямо в файл — он остаётся полным после переноса на другой компьютер.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Divider()
                        HStack {
                            MetricTile(title: "Выдано", value: Money.format(t.issued))
                            MetricTile(title: "Потрачено", value: Money.format(t.spent))
                            MetricTile(title: t.isOverspent ? "Перерасход" : "Остаток", value: Money.format(t.balance), tint: t.isOverspent ? Color.rkBad : nil)
                        }
                        Toggle("Только за период", isOn: $useDates)
                        if useDates {
                            DatePicker("С", selection: $from, displayedComponents: .date)
                            DatePicker("По", selection: $to, displayedComponents: .date)
                        }
                    }
                    .card()

                    VStack(spacing: 12) {
                        ForEach([ReportKind.excel, .pdf], id: \.title) { kind in
                            Button {
                                Task { await controller.generate(kind, project: project, from: useDates ? from : nil, to: useDates ? to : nil, container: persistence.container) }
                            } label: {
                                HStack {
                                    if controller.busy == kind { ProgressView().controlSize(.small) } else { Image(systemName: kind == .excel ? "tablecells" : "doc.richtext") }
                                    Text(kind == .excel ? "Сформировать отчёт (Excel)" : "Сформировать PDF").fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(kind == .excel ? Color.rkAccent : Color.gray)
                            .controlSize(.large)
                            .disabled(controller.busy != nil)
                        }
                        if let err = controller.errorText { StatusBanner(text: err, icon: "exclamationmark.triangle.fill", tint: .rkBad) }
                    }

                    if let report = controller.last {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Готово: \(report.filename)", systemImage: "checkmark.seal.fill").foregroundStyle(Color.rkGood).font(.headline)
                            Text("Размер: \(ByteCountFormatter.string(fromByteCount: Int64(report.data.count), countStyle: .file))").font(.footnote).foregroundStyle(.secondary)
                            HStack {
                                ShareLink(item: report.url) { Label("Отправить", systemImage: "square.and.arrow.up") }
                                Button { controller.save(report) } label: { Label("Сохранить…", systemImage: "folder") }
                                #if os(macOS)
                                if report.kind == .pdf { Button { controller.printReport(report) } label: { Label("Печать", systemImage: "printer") } }
                                #endif
                            }
                            .buttonStyle(.bordered)
                            Text("Отправить можно через AirDrop, Telegram, Почту и другие приложения из меню «Поделиться».").font(.caption).foregroundStyle(.secondary)
                        }
                        .card()
                    }
                }
                .padding()
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(Color.rkBackground)
            .navigationTitle("Отчёты")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .reportExporter(controller)
        }
    }
}
