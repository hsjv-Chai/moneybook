import SwiftUI

/// 分类/账户的图标徽章。
struct IconBadge: View {
    let symbolName: String
    let colorHex: String
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: colorHex).opacity(0.18))
            Image(systemName: symbolName)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(Color(hex: colorHex))
        }
        .frame(width: size, height: size)
    }
}

/// 带符号与颜色的金额文本。
struct AmountText: View {
    let amount: Decimal
    let kind: EntryKind
    var font: Font = .body

    var body: some View {
        Text(Formatters.signedCurrency(amount, kind: kind))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch kind {
        case .expense: .red
        case .income: .green
        case .transfer: .secondary
        }
    }
}

/// 流水列表/表格中的一行摘要。
struct EntryRowContent: View {
    let entry: Entry
    var showsDate: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(
                symbolName: entry.category?.symbolName ?? entry.kind.symbolName,
                colorHex: entry.category?.colorHex ?? "#8E8E93"
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                AmountText(amount: entry.amount, kind: entry.kind, font: .body)
                if showsDate {
                    Text(Formatters.dayTitle(entry.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var title: String {
        switch entry.kind {
        case .transfer:
            return "转账 · \(entry.account?.name ?? "未知账户") → \(entry.toAccount?.name ?? "未知账户")"
        case .expense, .income:
            return entry.category?.name ?? "未分类"
        }
    }

    private var subtitle: String? {
        let accountName = entry.account?.name
        if entry.note.isEmpty {
            return entry.kind == .transfer ? entry.note : accountName
        }
        if let accountName, entry.kind != .transfer {
            return "\(accountName) · \(entry.note)"
        }
        return entry.note
    }
}

/// 空状态占位。
struct EmptyStateView: View {
    let symbolName: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }
}

/// 顶部时间范围选择条。
struct RangePickerBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        HStack(spacing: 10) {
            Picker("时间范围", selection: $appState.rangePreset) {
                ForEach(DateRangePreset.selectable) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 118)

            if appState.rangePreset == .custom {
                DatePicker(
                    "开始",
                    selection: Binding(
                        get: { appState.customRange.start },
                        set: { appState.setCustomRangeStart($0) }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()

                Text("至")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DatePicker(
                    "结束",
                    selection: Binding(
                        get: { appState.customRange.end.addingTimeInterval(-1) },
                        set: { appState.setCustomRangeEnd($0) }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
            } else {
                Text(Formatters.rangeTitle(appState.activeInterval))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
