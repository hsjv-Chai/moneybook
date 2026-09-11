import Foundation
import SwiftData

/// 负责创建本地 SwiftData 容器。
@MainActor
enum PersistenceController {
    static let schema = Schema([Account.self, EntryCategory.self, Entry.self])

    /// 覆盖数据库目录的环境变量，供无界面自检与测试使用。
    static let dataDirectoryEnvironmentKey = "MONEYBOOK_DATA_DIR"

    /// 数据库目录：默认 `~/Library/Application Support/MoneyBook`。
    static func storeDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment[dataDirectoryEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

        return base.appendingPathComponent("MoneyBook", isDirectory: true)
    }

    /// 数据库文件（SQLite）路径。
    static func storeURL() -> URL {
        storeDirectory().appendingPathComponent("MoneyBook.store")
    }

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: [configuration])
        }

        return try makeContainer(at: storeDirectory())
    }

    /// 在指定目录创建/打开数据库，供测试验证重启后数据仍在。
    static func makeContainer(at directory: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            schema: schema,
            url: directory.appendingPathComponent("MoneyBook.store")
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
