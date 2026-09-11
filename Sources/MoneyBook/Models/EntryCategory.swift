import Foundation
import SwiftData

/// 收支分类，一级扁平结构。
@Model
final class EntryCategory {
    var uuid: UUID = UUID()
    var name: String = ""
    var kindRaw: String = CategoryKind.expense.rawValue
    var symbolName: String = "tag"
    var colorHex: String = Palette.categoryColors[0]
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Entry.category)
    var entries: [Entry] = []

    init(
        name: String,
        kind: CategoryKind,
        symbolName: String = "tag",
        colorHex: String = Palette.categoryColors[0],
        sortOrder: Int = 0,
        isArchived: Bool = false,
        createdAt: Date = Date()
    ) {
        self.uuid = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.symbolName = symbolName
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.createdAt = createdAt
    }

    var kind: CategoryKind {
        get { CategoryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
}
