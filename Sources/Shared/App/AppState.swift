import SwiftUI
import CoreData
import Combine

final class AppState: ObservableObject {
    @Published var selectedProjectID: String {
        didSet { UserDefaults.standard.set(selectedProjectID, forKey: "selectedProjectID") }
    }
    @Published var showNewProject = false
    @Published var alertMessage: String?

    init() {
        selectedProjectID = UserDefaults.standard.string(forKey: "selectedProjectID") ?? ""
    }
}

/// Сообщает экранам, что данные изменились (в том числе вложенные объекты и изменения из iCloud).
final class DataRefresher: ObservableObject {
    @Published var tick = 0
    private var cancellable: AnyCancellable?
    init(context: NSManagedObjectContext) {
        cancellable = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextObjectsDidChange, object: context)
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.tick += 1 }
    }
}

/// Цель для показа редактора чека в листе.
struct EditTarget: Identifiable {
    let id = UUID()
    let receipt: RReceipt
}
