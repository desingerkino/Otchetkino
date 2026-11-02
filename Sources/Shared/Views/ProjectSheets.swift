import SwiftUI
import CoreData

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var ctx
    @EnvironmentObject private var app: AppState
    @State private var name = ""
    @State private var holder = UserDefaults.standard.string(forKey: "lastHolderName") ?? ""
    @State private var amount: Int64 = 0
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Проект") {
                    TextField("Название фильма / проекта", text: $name)
                    TextField("ФИО подотчётного лица", text: $holder)
                }
                Section("Первая выдача денег") {
                    AmountField(title: "Сумма, ₽ (например, 50 000)", kop: $amount)
                    DatePicker("Дата выдачи", selection: $date, displayedComponents: .date)
                }
                Section { Text("Дополнительные выдачи и возвраты можно добавить позже на главном экране.").font(.footnote).foregroundStyle(.secondary) }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Новый проект")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        let p = DataOps.createProject(ctx, name: name.trimmingCharacters(in: .whitespaces), holder: holder, issued: amount, date: date)
                        UserDefaults.standard.set(holder, forKey: "lastHolderName")
                        app.selectedProjectID = p.uuid?.uuidString ?? ""
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 420)
        #endif
    }
}

struct AdvanceSheet: View {
    let project: RProject
    let kind: Int16
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var ctx
    @State private var amount: Int64 = 0
    @State private var date = Date()
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(title: "Сумма, ₽", kop: $amount)
                    DatePicker("Дата", selection: $date, displayedComponents: .date)
                    TextField("Примечание (необязательно)", text: $note)
                } footer: {
                    Text(kind == 0 ? "Дополнительная выдача увеличивает сумму подотчётных средств." : "Возврат неиспользованных денег уменьшает остаток.")
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(kind == 0 ? "Выдача денег" : "Возврат денег")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Записать") {
                        DataOps.addAdvance(ctx, project: project, kind: kind, amount: amount, date: date, note: note)
                        try? ctx.save()
                        dismiss()
                    }
                    .disabled(amount <= 0)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 330)
        #endif
    }
}

/// Поле ввода суммы в рублях: хранит значение в копейках.
struct AmountField: View {
    let title: String
    @Binding var kop: Int64
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .onAppear { text = Money.editString(kop) }
            .onChange(of: text) { new in
                if new.trimmingCharacters(in: .whitespaces).isEmpty { kop = 0 }
                else if let v = Money.parse(new) { kop = v }
            }
            .onChange(of: kop) { new in
                if !focused { text = Money.editString(new) }
            }
    }
}

struct ProjectsListView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var ctx
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \RProject.createdAt, ascending: false)]) private var projects: FetchedResults<RProject>

    var body: some View {
        NavigationStack {
            List {
                ForEach(projects, id: \.objectID) { p in
                    let t = p.totals()
                    Button {
                        app.selectedProjectID = p.uuid?.uuidString ?? ""
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(p.displayName).font(.headline)
                                    if p.isArchived { Text("архив").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.gray.opacity(0.2)).clipShape(Capsule()) }
                                }
                                Text("Выдано \(Money.format(t.issued)) · остаток \(Money.format(t.balance))").font(.caption).foregroundStyle(t.isOverspent ? Color.rkBad : .secondary)
                            }
                            Spacer()
                            if p.uuid?.uuidString == app.selectedProjectID { Image(systemName: "checkmark").foregroundStyle(Color.rkAccent) }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(p.isArchived ? "Вернуть" : "В архив") { p.isArchived.toggle(); try? ctx.save() }.tint(.gray)
                    }
                }
            }
            .navigationTitle("Проекты")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { dismiss(); app.showNewProject = true } label: { Label("Новый проект", systemImage: "plus") } }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 480)
        #endif
    }
}
