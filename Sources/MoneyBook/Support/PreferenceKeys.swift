import Foundation

/// UserDefaults / @AppStorage 使用的键。
enum PreferenceKeys {
    static let defaultAccountID = "defaultAccountID"
    static let showArchivedAccounts = "showArchivedAccounts"
    static let showArchivedCategories = "showArchivedCategories"
    /// 内置分类版本号，用于给已有的数据库补齐后来新增的内置分类。
    static let defaultCategoriesVersion = "defaultCategoriesVersion"
}
