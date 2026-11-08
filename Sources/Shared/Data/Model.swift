import CoreData

// MARK: - Управляемые объекты
// Модель описана в коде (без .xcdatamodeld): так её проще держать общей для iOS и macOS.
// Для CloudKit: все атрибуты либо необязательные, либо с значением по умолчанию; связи необязательные и с обратными.

@objc(RProject) public class RProject: NSManagedObject {
    @NSManaged public var uuid: UUID?
    @NSManaged public var name: String
    @NSManaged public var holder: String
    @NSManaged public var createdAt: Date?
    @NSManaged public var startDate: Date?
    @NSManaged public var endDate: Date?
    @NSManaged public var isArchived: Bool
    @NSManaged public var advances: NSSet?
    @NSManaged public var scenes: NSSet?
    @NSManaged public var receipts: NSSet?
}

@objc(RAdvance) public class RAdvance: NSManagedObject {
    @NSManaged public var uuid: UUID?
    /// 0 — выдача, 1 — возврат неиспользованных денег
    @NSManaged public var kind: Int16
    @NSManaged public var amountKop: Int64
    @NSManaged public var date: Date?
    @NSManaged public var note: String
    @NSManaged public var createdAt: Date?
    @NSManaged public var project: RProject?
}

@objc(RScene) public class RScene: NSManagedObject {
    @NSManaged public var uuid: UUID?
    @NSManaged public var code: String
    @NSManaged public var title: String
    @NSManaged public var sortOrder: Int32
    @NSManaged public var createdAt: Date?
    @NSManaged public var project: RProject?
    @NSManaged public var purchases: NSSet?
}

@objc(RCategory) public class RCategory: NSManagedObject {
    @NSManaged public var uuid: UUID?
    @NSManaged public var name: String
    @NSManaged public var sortOrder: Int32
    @NSManaged public var createdAt: Date?
    @NSManaged public var purchases: NSSet?
}

@objc(RReceipt) public class RReceipt: NSManagedObject {
    @NSManaged public var uuid: UUID?
    @NSManaged public var number: Int32
    @NSManaged public var date: Date?
    @NSManaged public var store: String
    @NSManaged public var inn: String
    @NSManaged public var comment: String
    @NSManaged public var rawText: String
    @NSManaged public var noReceipt: Bool
    /// Устарело (версия 1.x): раньше отмечало неподтверждённый чек. Начиная с 2.0 не используется и всегда false;
    /// атрибут оставлен, чтобы не менять схему хранилища и синхронизацию iCloud.
    @NSManaged public var isDraft: Bool
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var project: RProject?
    @NSManaged public var purchases: NSSet?
    @NSManaged public var photos: NSSet?
}

@objc(RPurchase) public class RPurchase: NSManagedObject {
    @NSManaged public var uuid: UUID?
    @NSManaged public var title: String
    @NSManaged public var amountKop: Int64
    @NSManaged public var quantity: Double
    @NSManaged public var purpose: String
    @NSManaged public var sortOrder: Int32
    @NSManaged public var createdAt: Date?
    @NSManaged public var receipt: RReceipt?
    @NSManaged public var category: RCategory?
    @NSManaged public var scenes: NSSet?
    @NSManaged public var photos: NSSet?
}

/// Справочник магазинов. Названия в чеках остаются обычным текстом (store), справочник лишь подсказывает и объединяет написания.
@objc(RStore) public class RStore: NSManagedObject {
    @NSManaged public var uuid: UUID?
    @NSManaged public var name: String
    @NSManaged public var createdAt: Date?
    @NSManaged public var lastUsedAt: Date?
    @NSManaged public var useCount: Int32
}

@objc(RPhoto) public class RPhoto: NSManagedObject {
    @NSManaged public var uuid: UUID?
    /// Оригинал файла без перекодирования (HEIC/JPEG/PNG как есть).
    @NSManaged public var data: Data?
    @NSManaged public var thumb: Data?
    @NSManaged public var fileExtension: String
    @NSManaged public var sortOrder: Int32
    @NSManaged public var createdAt: Date?
    @NSManaged public var receipt: RReceipt?
    @NSManaged public var purchase: RPurchase?
}

extension RProject { public override func awakeFromInsert() { super.awakeFromInsert(); setPrimitiveValue(UUID(), forKey: "uuid"); setPrimitiveValue(Date(), forKey: "createdAt") } }
extension RAdvance { public override func awakeFromInsert() { super.awakeFromInsert(); setPrimitiveValue(UUID(), forKey: "uuid"); setPrimitiveValue(Date(), forKey: "createdAt"); setPrimitiveValue(Date(), forKey: "date") } }
extension RScene { public override func awakeFromInsert() { super.awakeFromInsert(); setPrimitiveValue(UUID(), forKey: "uuid"); setPrimitiveValue(Date(), forKey: "createdAt") } }
extension RCategory { public override func awakeFromInsert() { super.awakeFromInsert(); setPrimitiveValue(UUID(), forKey: "uuid"); setPrimitiveValue(Date(), forKey: "createdAt") } }
extension RReceipt { public override func awakeFromInsert() { super.awakeFromInsert(); setPrimitiveValue(UUID(), forKey: "uuid"); setPrimitiveValue(Date(), forKey: "createdAt"); setPrimitiveValue(Date(), forKey: "updatedAt"); setPrimitiveValue(Date(), forKey: "date") } }
extension RPurchase { public override func awakeFromInsert() { super.awakeFromInsert(); setPrimitiveValue(UUID(), forKey: "uuid"); setPrimitiveValue(Date(), forKey: "createdAt") } }
extension RStore { public override func awakeFromInsert() { super.awakeFromInsert(); setPrimitiveValue(UUID(), forKey: "uuid"); setPrimitiveValue(Date(), forKey: "createdAt"); setPrimitiveValue(Date(), forKey: "lastUsedAt") } }
extension RPhoto { public override func awakeFromInsert() { super.awakeFromInsert(); setPrimitiveValue(UUID(), forKey: "uuid"); setPrimitiveValue(Date(), forKey: "createdAt") } }

// MARK: - Описание модели

enum ModelBuilder {
    static let model: NSManagedObjectModel = build()

    private static func attr(_ name: String, _ type: NSAttributeType, def: Any? = nil, external: Bool = false) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        if let def = def {
            a.defaultValue = def
            a.isOptional = false
        } else {
            a.isOptional = true
        }
        a.allowsExternalBinaryDataStorage = external
        return a
    }
    private static func str(_ n: String) -> NSAttributeDescription { attr(n, .stringAttributeType, def: "") }
    private static func uuid() -> NSAttributeDescription { attr("uuid", .UUIDAttributeType) }
    private static func date(_ n: String) -> NSAttributeDescription { attr(n, .dateAttributeType) }
    private static func int16(_ n: String) -> NSAttributeDescription { attr(n, .integer16AttributeType, def: 0) }
    private static func int32(_ n: String) -> NSAttributeDescription { attr(n, .integer32AttributeType, def: 0) }
    private static func int64(_ n: String) -> NSAttributeDescription { attr(n, .integer64AttributeType, def: 0) }
    private static func bool(_ n: String) -> NSAttributeDescription { attr(n, .booleanAttributeType, def: false) }

    private static func entity(_ name: String, _ cls: AnyClass) -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = name
        e.managedObjectClassName = NSStringFromClass(cls)
        return e
    }

    private static func rel(_ name: String, to dest: NSEntityDescription, many: Bool, rule: NSDeleteRule) -> NSRelationshipDescription {
        let r = NSRelationshipDescription()
        r.name = name
        r.destinationEntity = dest
        r.minCount = 0
        r.maxCount = many ? 0 : 1
        r.deleteRule = rule
        r.isOptional = true
        return r
    }

    private static func pair(_ a: NSRelationshipDescription, _ b: NSRelationshipDescription) {
        a.inverseRelationship = b
        b.inverseRelationship = a
    }

    private static func build() -> NSManagedObjectModel {
        let project = entity("RProject", RProject.self)
        let advance = entity("RAdvance", RAdvance.self)
        let scene = entity("RScene", RScene.self)
        let category = entity("RCategory", RCategory.self)
        let receipt = entity("RReceipt", RReceipt.self)
        let purchase = entity("RPurchase", RPurchase.self)
        let photo = entity("RPhoto", RPhoto.self)
        let store = entity("RStore", RStore.self)

        project.properties = [uuid(), str("name"), str("holder"), date("createdAt"), date("startDate"), date("endDate"), bool("isArchived")]
        advance.properties = [uuid(), int16("kind"), int64("amountKop"), date("date"), str("note"), date("createdAt")]
        scene.properties = [uuid(), str("code"), str("title"), int32("sortOrder"), date("createdAt")]
        category.properties = [uuid(), str("name"), int32("sortOrder"), date("createdAt")]
        receipt.properties = [uuid(), int32("number"), date("date"), str("store"), str("inn"), str("comment"), str("rawText"),
                              bool("noReceipt"), bool("isDraft"), date("createdAt"), date("updatedAt")]
        purchase.properties = [uuid(), str("title"), int64("amountKop"), attr("quantity", .doubleAttributeType, def: 1.0),
                               str("purpose"), int32("sortOrder"), date("createdAt")]
        photo.properties = [uuid(), attr("data", .binaryDataAttributeType, external: true), attr("thumb", .binaryDataAttributeType, external: true),
                            str("fileExtension"), int32("sortOrder"), date("createdAt")]

        // project <-> advances / scenes / receipts
        let pAdv = rel("advances", to: advance, many: true, rule: .cascadeDeleteRule)
        let aProj = rel("project", to: project, many: false, rule: .nullifyDeleteRule)
        pair(pAdv, aProj)
        let pScn = rel("scenes", to: scene, many: true, rule: .cascadeDeleteRule)
        let sProj = rel("project", to: project, many: false, rule: .nullifyDeleteRule)
        pair(pScn, sProj)
        let pRec = rel("receipts", to: receipt, many: true, rule: .cascadeDeleteRule)
        let rProj = rel("project", to: project, many: false, rule: .nullifyDeleteRule)
        pair(pRec, rProj)
        project.properties += [pAdv, pScn, pRec]
        advance.properties += [aProj]
        scene.properties += [sProj]
        receipt.properties += [rProj]

        // receipt <-> purchases / photos
        let rPur = rel("purchases", to: purchase, many: true, rule: .cascadeDeleteRule)
        let pPurRec = rel("receipt", to: receipt, many: false, rule: .nullifyDeleteRule)
        pair(rPur, pPurRec)
        let rPho = rel("photos", to: photo, many: true, rule: .cascadeDeleteRule)
        let phoRec = rel("receipt", to: receipt, many: false, rule: .nullifyDeleteRule)
        pair(rPho, phoRec)
        receipt.properties += [rPur, rPho]
        purchase.properties += [pPurRec]
        photo.properties += [phoRec]

        // purchase <-> category / scenes / photos
        let cPur = rel("purchases", to: purchase, many: true, rule: .nullifyDeleteRule)
        let pCat = rel("category", to: category, many: false, rule: .nullifyDeleteRule)
        pair(cPur, pCat)
        category.properties += [cPur]
        purchase.properties += [pCat]
        let sPur = rel("purchases", to: purchase, many: true, rule: .nullifyDeleteRule)
        let pScenes = rel("scenes", to: scene, many: true, rule: .nullifyDeleteRule)
        pair(sPur, pScenes)
        scene.properties += [sPur]
        purchase.properties += [pScenes]
        let pPho = rel("photos", to: photo, many: true, rule: .cascadeDeleteRule)
        let phoPur = rel("purchase", to: purchase, many: false, rule: .nullifyDeleteRule)
        pair(pPho, phoPur)
        purchase.properties += [pPho]
        photo.properties += [phoPur]

        store.properties = [uuid(), str("name"), date("createdAt"), date("lastUsedAt"), int32("useCount")]

        let m = NSManagedObjectModel()
        m.entities = [project, advance, scene, category, receipt, purchase, photo, store]
        return m
    }
}
