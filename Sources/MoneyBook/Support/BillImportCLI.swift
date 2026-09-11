import Foundation
import SwiftData

/// `MoneyBook --import-preview <文件>`：只解析、只打印，不接触任何数据库。
/// 用于在没有界面的情况下核对账单解析结果。
@MainActor
enum BillImportCLI {
    /// `--check-store`：打开数据库（会触发必要的结构升级）并打印统计，用于核对数据是否完好。
    /// 尊重 MONEYBOOK_DATA_DIR 环境变量，因此可以安全地在副本上验证。
    static func checkStore() -> Bool {
        do {
            let directory = PersistenceController.storeDirectory()
            print("数据库目录：\(directory.path)")
            let container = try PersistenceController.makeContainer()
            let context = ModelContext(container)

            let entries = try context.fetch(
                FetchDescriptor<Entry>(sortBy: [SortDescriptor(\Entry.date, order: .reverse)])
            )
            let accounts = try context.fetch(FetchDescriptor<Account>())
            let categories = try context.fetch(FetchDescriptor<EntryCategory>())

            print("流水 \(entries.count) 笔 / 账户 \(accounts.count) 个 / 分类 \(categories.count) 个")
            for entry in entries.prefix(10) {
                let title = entry.category?.name ?? (entry.kind == .transfer ? "转账" : "未分类")
                print(
                    "  \(Formatters.isoDate(entry.date)) \(title) "
                        + "\(Formatters.signedCurrency(entry.amount, kind: entry.kind)) "
                        + "账户:\(entry.account?.name ?? "—") 导入:\(entry.isImported ? "是" : "否")"
                )
            }
            return true
        } catch {
            print("打开数据库失败：\(error)")
            return false
        }
    }

    /// `--import-apply <文件>`：不打开界面，按默认选项把账单导入当前数据库。
    /// 与界面走的是同一套服务，配合 MONEYBOOK_DATA_DIR 可以在副本上做端到端验证。
    static func apply(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        do {
            let container = try PersistenceController.makeContainer()
            let context = ModelContext(container)
            try SeedDataService.seedIfNeeded(in: context)

            let parsed = try BillImportService.parse(url: url)
            let preview = try BillImportService.makePreview(
                parsed: parsed,
                fileName: url.lastPathComponent,
                context: context
            )

            var options = BillImportOptions()
            let categories = try context.fetch(FetchDescriptor<EntryCategory>())
            options.defaultExpenseCategoryUUID = categories.first { $0.kind == .expense && $0.name == "其他支出" }?.uuid
            options.defaultIncomeCategoryUUID = categories.first { $0.kind == .income && $0.name == "其他收入" }?.uuid

            print("待导入 \(preview.rows.count) 笔，账户计划 \(preview.accountPlans.count) 个")
            for warning in preview.parseWarnings { print("⚠️ \(warning)") }

            let result = try BillImportService.apply(preview: preview, options: options, context: context)
            print(
                "导入完成：新增 \(result.inserted) 笔（支出 \(Formatters.currency(result.expenseTotal))，"
                    + "收入 \(Formatters.currency(result.incomeTotal))，转账 \(Formatters.currency(result.transferTotal))）"
            )
            print("跳过：重复 \(result.skippedDuplicates)、无效 \(result.skippedInvalid)、退款 \(result.skippedRefunded)")
            if !result.createdAccountNames.isEmpty {
                print("新建账户：\(result.createdAccountNames.joined(separator: "、"))")
            }
            print("批次号：\(result.batchID.uuidString)")
            return result.inserted > 0
        } catch {
            print("导入失败：\(error.localizedDescription)")
            return false
        }
    }

    /// `--import-debug <文件>`：打印 OCR 文本块与列边界，用于排查表格重建问题。
    static func debug(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        do {
            let (tokens, boundaries) = try WeChatPDFParser.analyze(url: url)
            let dumpURL = URL(fileURLWithPath: "/private/tmp/moneybook-gray.png")
            try? WeChatPDFParser.dumpGrayscale(url: url, to: dumpURL)
            print("灰度图：\(dumpURL.path)")
            if let boundaries {
                let text = boundaries.map { String(format: "%.4f", $0) }.joined(separator: ", ")
                print("列边界(\(boundaries.count) 条)：\(text)")
            } else {
                print("列边界：未检测到网格线，改用文字坐标推断")
            }
            print("文本块：\(tokens.count)")
            for token in tokens.sorted(by: { $0.centerY > $1.centerY }) {
                print(String(format: "y=%.4f x=%.4f w=%.4f | %@", token.y, token.x, token.width, token.text))
            }
            return true
        } catch {
            print("诊断失败：\(error.localizedDescription)")
            return false
        }
    }

    static func run(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("文件不存在：\(url.path)")
            return false
        }

        do {
            let (source, rows, summary) = try BillImportService.parse(url: url)
            print("来源：\(source.title)")
            print("文件：\(url.lastPathComponent)")
            print("解析出 \(rows.count) 行")

            var expense = Decimal.zero
            var income = Decimal.zero
            var neutral = Decimal.zero
            var invalid = 0

            for row in rows {
                let amount = row.amount ?? .zero
                switch row.direction {
                case .expense: expense += amount
                case .income: income += amount
                case .neutral, .none:
                    if row.isNeutralTransaction { neutral += amount } else { invalid += 0 }
                }
                if !row.isValid { invalid += 1 }

                let issues = row.issues.isEmpty ? "" : "  ⚠️ \(row.issues.joined(separator: "、"))"
                print(
                    String(
                        format: "%2d | %@ | %@ | %@ | %@ | %@ | %@ | %@ | 单号:%@%@",
                        row.sourceLine,
                        row.rawDate.isEmpty ? "—" : row.rawDate,
                        pad(row.transactionType, 8),
                        pad(row.counterparty, 10),
                        pad(row.displayTitle, 14),
                        pad(row.directionText, 4),
                        pad(row.amount.map(Formatters.amount) ?? "—", 9),
                        pad(row.paymentMethod, 12),
                        row.transactionID.isEmpty ? "无" : row.transactionID,
                        issues
                    )
                )
            }

            print("---")
            print("支出合计：\(Formatters.currency(expense))")
            print("收入合计：\(Formatters.currency(income))")
            print("中性交易合计：\(Formatters.currency(neutral))")
            print("无法解析的行：\(invalid)")

            if let summary {
                print(
                    "账单自带汇总：共\(summary.totalCount ?? 0)笔 / 收入 \(summary.incomeCount ?? 0) 笔 \(Formatters.currency(summary.incomeTotal ?? .zero))"
                        + " / 支出 \(summary.expenseCount ?? 0) 笔 \(Formatters.currency(summary.expenseTotal ?? .zero))"
                        + " / 中性 \(summary.neutralCount ?? 0) 笔 \(Formatters.currency(summary.neutralTotal ?? .zero))"
                )
                let warnings = BillSummaryParser.discrepancyWarnings(
                    summary: summary,
                    expense: expense,
                    income: income,
                    neutral: neutral,
                    importedRowCount: rows.count
                )
                for warning in warnings { print("⚠️ \(warning)") }
                if warnings.isEmpty { print("✅ 与账单汇总一致") }
            } else {
                print("账单自带汇总：未识别")
            }

            for row in rows where row.isNeutralTransaction {
                let movement = BillImportService.transferAccounts(for: row)
                print("转账映射：\(row.transactionType) → \(movement.from) ⇒ \(movement.to)")
            }
            return invalid == 0
        } catch {
            print("解析失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 中文按显示宽度对齐会被截断，这里按字符数补空格即可满足阅读需要。
    private static func pad(_ text: String, _ width: Int) -> String {
        let trimmed = text.isEmpty ? "—" : text
        let display = trimmed.count >= width ? String(trimmed.prefix(width)) : trimmed
        return display + String(repeating: " ", count: max(0, width - display.count))
    }
}
