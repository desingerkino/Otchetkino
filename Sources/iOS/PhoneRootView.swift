import SwiftUI

struct PhoneRootView: View {
    var body: some View {
        TabView {
            ProjectGate { HomeView(project: $0) }
                .tabItem { Label("Главная", systemImage: "house") }
            ProjectGate { PurchasesView(project: $0) }
                .tabItem { Label("Покупки", systemImage: "list.bullet.rectangle") }
            ProjectGate { ReceiptsView(project: $0) }
                .tabItem { Label("Чеки", systemImage: "doc.text.image") }
            ProjectGate { ReportsView(project: $0) }
                .tabItem { Label("Отчёты", systemImage: "tablecells") }
            ProjectGate { SettingsView(project: $0) }
                .tabItem { Label("Настройки", systemImage: "gearshape") }
        }
    }
}
