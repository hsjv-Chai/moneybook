import SwiftUI

/// 卡片外观：自适应浅色/深色模式，不写死颜色。
private struct CardBackground: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
            )
    }
}

extension View {
    func cardStyle(padding: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// 概览页的统计卡片。
struct StatCard: View {
    let title: String
    let amount: Decimal
    let symbolName: String
    var tint: Color = .accentColor
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(Formatters.currency(amount))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .cardStyle()
    }
}

/// 带标题的图表卡片。
struct ChartCard<Content: View, Legend: View>: View {
    let title: String
    let subtitle: String?
    let content: Content
    let legend: Legend

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder legend: () -> Legend
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.legend = legend()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                legend
            }
            content
        }
        .cardStyle()
    }
}

extension ChartCard where Legend == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, content: content, legend: { EmptyView() })
    }
}

/// 图例中的一项。
struct LegendDot: View {
    let title: String
    let color: Color
    var value: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.caption)
                    .monospacedDigit()
            }
        }
    }
}
