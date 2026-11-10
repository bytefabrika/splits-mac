import SwiftUI

/// A titled group, the way macOS shows a box: the title above, the content on a quiet background.
/// Colour lives in the content (symbols, charts), never in the box itself.
struct Panel<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                accessory
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension Panel where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// One number with what it is: a tinted symbol and a label above, the value below. Neutral, so the
/// numbers carry the weight rather than coloured tiles.
struct Metric: View {
    let label: String
    let symbol: String
    let tint: Color
    let value: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Metrics side by side with dividers between them when there's room, in rows of three when there isn't.
struct MetricRow: View {
    let metrics: [Metric]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(metrics.indices, id: \.self) { i in
                    if i > 0 { Divider() }
                    metrics[i].frame(minWidth: 120)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 14) {
                ForEach(Array(stride(from: 0, to: metrics.count, by: 3)), id: \.self) { start in
                    GridRow {
                        ForEach(start..<min(start + 3, metrics.count), id: \.self) { metrics[$0] }
                    }
                }
            }
        }
    }
}

extension View {
    /// The box every group in the app sits in: a quiet background, a hairline edge, the same corners.
    func card(padding: CGFloat? = nil) -> some View {
        self
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

/// Cards in rows, as many across as fit, every card in a row as tall as the tallest one.
/// (A lazy grid lets each card keep its own height, which leaves ragged rows.)
struct CardGrid: View {
    let minWidth: CGFloat
    let spacing: CGFloat
    let cards: [AnyView]
    @State private var width: CGFloat = 900

    init(minWidth: CGFloat = 260, spacing: CGFloat = 14, cards: [AnyView]) {
        self.minWidth = minWidth
        self.spacing = spacing
        self.cards = cards
    }

    var body: some View {
        let columns = max(1, min(cards.count, Int((width + spacing) / (minWidth + spacing))))
        VStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                ForEach(Array(stride(from: 0, to: cards.count, by: columns)), id: \.self) { start in
                    GridRow(alignment: .top) {
                        ForEach(start..<start + columns, id: \.self) { i in
                            if i < cards.count {
                                cards[i].frame(maxHeight: .infinity, alignment: .top)
                            } else {
                                Color.clear.gridCellUnsizedAxes([.vertical])
                            }
                        }
                    }
                }
            }
        }
    }
}
