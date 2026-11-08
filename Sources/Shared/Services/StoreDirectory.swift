import CoreData
import Foundation

/// Справочник магазинов: запоминает названия, подсказывает при вводе, объединяет дубли.
/// В чеках название по-прежнему хранится обычным текстом (RReceipt.store), поэтому старые данные,
/// резервные копии и синхронизация не меняются: справочник только помогает вводить одинаково.
enum StoreDirectory {
    private static let ru = Locale(identifier: "ru_RU")

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Ключ сравнения: без регистра, без лишних пробелов, «ё» = «е».
    static func key(_ s: String) -> String {
        clean(s).lowercased(with: ru).replacingOccurrences(of: "ё", with: "е")
    }

    static func all(_ ctx: NSManagedObjectContext) -> [RStore] {
        let req = NSFetchRequest<RStore>(entityName: "RStore")
        return (try? ctx.fetch(req)) ?? []
    }

    static func find(_ ctx: NSManagedObjectContext, name: String) -> RStore? {
        let k = key(name)
        guard !k.isEmpty else { return nil }
        return all(ctx).first { key($0.name) == k }
    }

    /// Сколько чеков у каждого магазина (ключ — `key(name)`).
    static func counts(_ ctx: NSManagedObjectContext) -> [String: Int] {
        let req = NSFetchRequest<RReceipt>(entityName: "RReceipt")
        var map: [String: Int] = [:]
        for r in (try? ctx.fetch(req)) ?? [] {
            let k = key(r.store)
            if !k.isEmpty { map[k, default: 0] += 1 }
        }
        return map
    }

    /// Подсказки по введённому началу: сначала начинающиеся с текста, затем содержащие; чаще используемые выше.
    static func suggestions(_ ctx: NSManagedObjectContext, for text: String, limit: Int = 6) -> [String] {
        let k = key(text)
        guard !k.isEmpty else { return [] }
        var starts: [RStore] = [], contains: [RStore] = []
        for s in all(ctx) {
            let sk = key(s.name)
            if sk == k && s.name == clean(text) { continue }
            if sk.hasPrefix(k) { starts.append(s) } else if sk.contains(k) { contains.append(s) }
        }
        func order(_ a: RStore, _ b: RStore) -> Bool {
            if a.useCount != b.useCount { return a.useCount > b.useCount }
            return (a.lastUsedAt ?? .distantPast) > (b.lastUsedAt ?? .distantPast)
        }
        return Array((starts.sorted(by: order) + contains.sorted(by: order)).prefix(limit).map { $0.name })
    }

    /// Запоминает название. Если такое уже есть (в любом регистре) — возвращает существующее каноническое написание.
    @discardableResult
    static func remember(_ ctx: NSManagedObjectContext, name: String, countUse: Bool = true) -> String {
        let cleaned = clean(name)
        guard !cleaned.isEmpty else { return cleaned }
        if let existing = find(ctx, name: cleaned) {
            if countUse { existing.useCount += 1 }
            existing.lastUsedAt = Date()
            return existing.name
        }
        let s = RStore(context: ctx)
        s.name = cleaned
        s.useCount = countUse ? 1 : 0
        return cleaned
    }

    /// Чеки с названием, совпадающим с данным без учёта регистра.
    static func receipts(_ ctx: NSManagedObjectContext, matching name: String) -> [RReceipt] {
        let k = key(name)
        let req = NSFetchRequest<RReceipt>(entityName: "RReceipt")
        let all = (try? ctx.fetch(req)) ?? []
        return all.filter { key($0.store) == k }
    }

    /// Переименовывает магазин и обновляет название во всех его чеках. Если новое имя уже есть в справочнике — объединяет.
    static func rename(_ ctx: NSManagedObjectContext, store: RStore, to newName: String) {
        let target = clean(newName)
        guard !target.isEmpty else { return }
        if let other = find(ctx, name: target), other != store { merge(ctx, source: store, into: other); return }
        for r in receipts(ctx, matching: store.name) { r.store = target; r.touch() }
        store.name = target
    }

    /// Объединяет два написания: все чеки получают название «основного», лишняя запись удаляется. Покупки и фото не затрагиваются.
    static func merge(_ ctx: NSManagedObjectContext, source: RStore, into target: RStore) {
        guard source != target else { return }
        for r in receipts(ctx, matching: source.name) { r.store = target.name; r.touch() }
        target.useCount += source.useCount
        if let d = source.lastUsedAt, d > (target.lastUsedAt ?? .distantPast) { target.lastUsedAt = d }
        ctx.delete(source)
    }

    /// Удаляет только запись справочника; названия в чеках остаются как были.
    static func remove(_ ctx: NSManagedObjectContext, store: RStore) { ctx.delete(store) }

    /// Первичное наполнение из уже введённых чеков + устранение дублей справочника (в том числе после синхронизации).
    static func seedAndDedupe(_ ctx: NSManagedObjectContext) {
        // 1) дубли самого справочника
        let sorted = all(ctx).sorted {
            let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
            if a != b { return a < b }
            return ($0.uuid?.uuidString ?? "") < ($1.uuid?.uuidString ?? "")
        }
        var keepers: [String: RStore] = [:]
        for s in sorted {
            let k = key(s.name)
            if k.isEmpty { ctx.delete(s); continue }
            if let keeper = keepers[k] {
                keeper.useCount += s.useCount
                ctx.delete(s)
            } else {
                keepers[k] = s
            }
        }
        // 2) названия из существующих чеков
        let req = NSFetchRequest<RReceipt>(entityName: "RReceipt")
        let receipts = (try? ctx.fetch(req)) ?? []
        var counts: [String: (name: String, n: Int32)] = [:]
        for r in receipts {
            let name = clean(r.store)
            let k = key(name)
            guard !k.isEmpty else { continue }
            if keepers[k] != nil { continue }
            counts[k] = (counts[k]?.name ?? name, (counts[k]?.n ?? 0) + 1)
        }
        for (_, v) in counts {
            let s = RStore(context: ctx)
            s.name = v.name
            s.useCount = v.n
        }
    }
}
