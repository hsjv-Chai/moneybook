import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 微信账单导入面板：选择文件 → 预览核对 → 导入 → 可整批撤销。
struct ImportBillView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\EntryCategory.sortOrder)]) private var categories: [EntryCategory]
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)])
    private var accounts: [Account]

    @State private var stage: Stage = .idle
    @State private var errorMessage: String?
    @State private var options = BillImportOptions()

    private enum Stage {
        case idle
        case parsing(String)
        case preview(BillImportPreview)
        case finished(BillImportResult)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            switch stage {
            case .idle:
                idleView
            case .parsing(let fileName):
                parsingView(fileName: fileName)
            case .preview(let preview):
                previewView(preview)
            case .finished(let result):
                finishedView(result)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 640, height: 620)
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("导入微信账单")
                .font(.title3.weight(.semibold))
            Text("支持微信导出的账单 CSV（精确）以及由账单生成的 PDF（文字识别，请核对金额）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if case .preview = stage, let preview = currentPreview {
                Text("已选 \(selectionSummary(preview).count) 笔")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(closeButtonTitle) { dismiss() }
                .keyboardShortcut(.cancelAction)

            if case .preview(let preview) = stage {
                Button("开始导入") { performImport(preview) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectionSummary(preview).count == 0)
            }
        }
    }

    private var closeButtonTitle: String {
        switch stage {
        case .idle, .preview: "取消"
        case .parsing: "取消"
        case .finished: "完成"
        }
    }

    private var currentPreview: BillImportPreview? {
        if case .preview(let preview) = stage { return preview }
        return nil
    }

    // MARK: - 各阶段

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择账单文件")
                        .font(.headline)
                    Text("CSV：微信「账单下载 → 用于个人对账」收到的文件。\nPDF：把账单另存或打印成的 PDF。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("选择文件…") { chooseFile() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func parsingView(fileName: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在解析 \(fileName)…")
            }
            Text("PDF 需要先做文字识别，约需几秒。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewView(_ preview: BillImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryCard(preview)

            if !preview.parseWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(preview.parseWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    accountSection(preview)
                    categorySection
                    optionsSection
                    rowsSection(preview)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func finishedView(_ result: BillImportResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("导入完成", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("新增流水").foregroundStyle(.secondary)
                        Text("\(result.inserted) 笔")
                    }
                    GridRow {
                        Text("支出合计").foregroundStyle(.secondary)
                        Text(Formatters.currency(result.expenseTotal)).foregroundStyle(.red)
                    }
                    GridRow {
                        Text("收入合计").foregroundStyle(.secondary)
                        Text(Formatters.currency(result.incomeTotal)).foregroundStyle(.green)
                    }
                    GridRow {
                        Text("转账合计").foregroundStyle(.secondary)
                        Text(Formatters.currency(result.transferTotal))
                    }
                    GridRow {
                        Text("跳过").foregroundStyle(.secondary)
                        Text("重复 \(result.skippedDuplicates) · 无效 \(result.skippedInvalid) · 退款 \(result.skippedRefunded)")
                    }
                }
                .font(.callout)

                if !result.createdAccountNames.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("新建账户").font(.subheadline)
                        Text(result.createdAccountNames.joined(separator: "、"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if result.inserted > 0 {
                    Button("撤销本次导入") { undo(result) }
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 预览分区

    private func summaryCard(_ preview: BillImportPreview) -> some View {
        let summary = selectionSummary(preview)
        return VStack(alignment: .leading, spacing: 8) {
            Text(preview.fileName)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 14) {
                labeledValue("来源", preview.source.title)
                labeledValue("解析", "\(preview.rows.count) 笔")
                labeledValue("待导入", "\(summary.count) 笔")
                if let range = preview.dateRange {
                    labeledValue("区间", "\(Formatters.isoDate(range.lowerBound)) ~ \(Formatters.isoDate(range.upperBound))")
                }
            }

            HStack(spacing: 14) {
                labeledValue("支出", Formatters.currency(summary.expense), tint: .red)
                labeledValue("收入", Formatters.currency(summary.income), tint: .green)
                labeledValue("转账", Formatters.currency(summary.transfer))
            }

            if let billSummary = preview.summary, let income = billSummary.incomeTotal, let expense = billSummary.expenseTotal {
                Text("账单自带汇总：收入 \(Formatters.currency(income)) · 支出 \(Formatters.currency(expense))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func labeledValue(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    private func accountSection(_ preview: BillImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("账户对应")
                .font(.subheadline.weight(.semibold))
            Text("账单里的支付方式会对应到账户，已存在的会自动匹配。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(preview.accountPlans) { plan in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plan.paymentMethod)
                            .font(.callout)
                            .lineLimit(1)
                        Text(plan.willCreateAccount(overrides: options.accountOverrides)
                             ? "将新建账户"
                             : "已有账户")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Picker("账户", selection: accountBinding(for: plan)) {
                        Text("新建「\(plan.accountName)」").tag(UUID?.some(BillImportOptions.createNewAccountUUID))
                        ForEach(accounts) { account in
                            Text(account.name).tag(UUID?.some(account.uuid))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("默认分类")
                .font(.subheadline.weight(.semibold))
            Text("账单没有分类，会根据商户关键词自动匹配；匹配不到时使用这里的默认分类。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Picker("支出默认", selection: $options.defaultExpenseCategoryUUID) {
                    ForEach(expenseCategories) { category in
                        Text(category.name).tag(UUID?.some(category.uuid))
                    }
                }
                .frame(maxWidth: 260)

                Picker("收入默认", selection: $options.defaultIncomeCategoryUUID) {
                    ForEach(incomeCategories) { category in
                        Text(category.name).tag(UUID?.some(category.uuid))
                    }
                }
                .frame(maxWidth: 260)
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("导入选项")
                .font(.subheadline.weight(.semibold))
            Toggle("导入中性交易（充值 / 提现 / 信用卡还款记为账户间转账）", isOn: $options.importNeutralTransactions)
            Toggle("导入退款 / 已关闭 / 失败的记录", isOn: $options.importRefundedRows)
            Toggle("跳过已经导入过的记录（按交易单号判断）", isOn: $options.skipDuplicates)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    private func rowsSection(_ preview: BillImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("明细（前 \(min(preview.rows.count, 50)) 笔）")
                .font(.subheadline.weight(.semibold))

            ForEach(preview.rows.prefix(50)) { row in
                HStack(spacing: 8) {
                    Text(row.rawDate.isEmpty ? "—" : row.rawDate)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 128, alignment: .leading)
                    Text(row.displayTitle)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(row.direction?.title ?? (row.isNeutralTransaction ? "转账" : "—"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(row.amount.map(Formatters.amount) ?? "—")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(row.isValid ? Color.primary : Color.orange)
                        .frame(width: 76, alignment: .trailing)
                }
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: - 数据

    private var expenseCategories: [EntryCategory] {
        categories.filter { $0.kind == .expense && !$0.isArchived }
    }

    private var incomeCategories: [EntryCategory] {
        categories.filter { $0.kind == .income && !$0.isArchived }
    }

    private func accountBinding(for plan: BillAccountPlan) -> Binding<UUID?> {
        Binding(
            get: {
                options.accountOverrides[plan.accountName]
                    ?? plan.matchedAccountUUID
                    ?? BillImportOptions.createNewAccountUUID
            },
            set: { options.accountOverrides[plan.accountName] = $0 }
        )
    }

    private func selectionSummary(_ preview: BillImportPreview) -> (
        count: Int, expense: Decimal, income: Decimal, transfer: Decimal, skipped: Int
    ) {
        BillImportService.selectionSummary(preview: preview, options: options)
    }

    // MARK: - 行为

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .pdf]
        panel.message = "选择微信账单文件（CSV 或 PDF）"
        panel.prompt = "导入"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        errorMessage = nil
        stage = .parsing(url.lastPathComponent)

        Task {
            do {
                let parsed = try await Task.detached(priority: .userInitiated) {
                    try BillImportService.parse(url: url)
                }.value
                let preview = try BillImportService.makePreview(
                    parsed: parsed,
                    fileName: url.lastPathComponent,
                    context: context
                )
                applyDefaultSelections(preview)
                stage = .preview(preview)
            } catch {
                errorMessage = error.localizedDescription
                stage = .idle
            }
        }
    }

    private func applyDefaultSelections(_ preview: BillImportPreview) {
        if options.defaultExpenseCategoryUUID == nil {
            options.defaultExpenseCategoryUUID = expenseCategories.first { $0.name == "其他支出" }?.uuid
                ?? expenseCategories.first?.uuid
        }
        if options.defaultIncomeCategoryUUID == nil {
            options.defaultIncomeCategoryUUID = incomeCategories.first { $0.name == "其他收入" }?.uuid
                ?? incomeCategories.first?.uuid
        }
        options.accountOverrides = options.accountOverrides.filter { key, _ in
            preview.accountPlans.contains { $0.accountName == key }
        }
    }

    private func performImport(_ preview: BillImportPreview) {
        do {
            let result = try BillImportService.apply(preview: preview, options: options, context: context)
            stage = .finished(result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func undo(_ result: BillImportResult) {
        let removed = BillImportService.undo(batchID: result.batchID, context: context)
        errorMessage = removed > 0 ? "已撤销本次导入，删除 \(removed) 笔流水。" : "没有找到可撤销的流水。"
        stage = .idle
    }
}

private extension BillAccountPlan {
    func willCreateAccount(overrides: [String: UUID]) -> Bool {
        guard let chosen = overrides[accountName] else { return matchedAccountUUID == nil }
        return chosen != matchedAccountUUID
    }
}
