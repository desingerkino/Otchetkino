import CoreData
import Foundation

/// Сценарий «Enter — сохранить покупку и создать следующую».
@MainActor
enum PurchaseFlow {
    private static var lastCreated = Date.distantPast
    /// Минимальный интервал между созданиями: защита от двойного и многократного нажатия Enter.
    static var minInterval: TimeInterval = 0.4

    /// Сохраняет текущую покупку и, только если сохранение удалось, создаёт следующую пустую запись.
    /// Ничего не делает, если форма пуста, покупка уже удалена или предыдущее создание было только что.
    @discardableResult
    static func saveAndCreateNext(project: RProject, ctx: NSManagedObjectContext, current: RReceipt?, saver: SaveCoordinator, now: Date = Date()) -> RReceipt? {
        guard now.timeIntervalSince(lastCreated) >= minInterval else { return nil }
        guard let cur = current, !cur.isDeleted, !cur.isBlank else { return nil }   // пустую форму не сохраняем и не плодим
        guard saver.saveNow() else { return nil }                                     // ошибка записи — следующую не создаём
        lastCreated = now
        let next = AddFlow.createManual(project: project, ctx: ctx)
        saver.setActive([next.objectID])
        return next
    }

    /// Для тестов.
    static func resetThrottle() { lastCreated = .distantPast }
}
