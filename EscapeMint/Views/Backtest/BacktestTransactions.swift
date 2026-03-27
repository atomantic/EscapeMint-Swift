import SwiftUI

// Column definition shared between header and rows
private struct Col {
    let title: String
    let width: CGFloat
    let leading: Bool

    init(_ title: String, _ width: CGFloat, leading: Bool = false) {
        self.title = title
        self.width = width
        self.leading = leading
    }
}

private let columns: [Col] = [
    Col("Date", 78, leading: true),
    Col("Fund Size", 70),
    Col("Equity", 70),
    Col("Cash", 65),
    Col("Interest", 58),
    Col("\u{03A3} Int", 58),
    Col("Dividend", 58),
    Col("\u{03A3} Div", 58),
    Col("Action", 45),
    Col("Amount", 65),
    Col("Invested", 65),
    Col("Unrealized", 72),
    Col("Realized", 70),
    Col("Liquid P&L", 72),
    Col("Target", 70),
]

struct BacktestTransactions: View {
    let result: BacktestResult
    @Binding var sortOrder: BacktestView.SortOrder

    var body: some View {
        let sorted = sortOrder == .asc ? result.entries : result.entries.reversed()

        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    // Header
                    HStack(spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { i, col in
                            if i == 0 {
                                // Sortable Date header
                                Button {
                                    sortOrder = sortOrder == .asc ? .desc : .asc
                                } label: {
                                    HStack(spacing: 2) {
                                        Text(col.title)
                                        Text(sortOrder == .asc ? "\u{25B2}" : "\u{25BC}")
                                            .font(.system(size: 7))
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.textMuted)
                                .frame(width: col.width, alignment: .leading)
                            } else {
                                Text(col.title)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.textMuted)
                                    .frame(width: col.width, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .background(Color.bgCard)

                    Divider().background(Color.textMuted.opacity(0.3))

                    // Rows
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(sorted) { entry in
                                entryRow(entry)
                                Divider().background(Color.textMuted.opacity(0.15))
                            }
                        }
                    }
                    .frame(maxHeight: 500)
                }
            }
            .defaultScrollAnchor(.leading)

            // Footer
            HStack {
                Text("\(result.entries.count) entries")
                    .font(.caption2).foregroundColor(.textMuted)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.bg.opacity(0.5))
        }
        .background(Color.bgCard)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.textMuted.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Entry Row

    @ViewBuilder
    private func entryRow(_ entry: BacktestResult.BacktestEntry) -> some View {
        let bgColor: Color = {
            switch entry.action {
            case .BUY: return Color.green.opacity(0.05)
            case .SELL: return Color.red.opacity(0.05)
            default: return Color.clear
            }
        }()

        HStack(spacing: 0) {
            cell(entry.date, width: columns[0].width, alignment: .leading, color: .textPrimary)
            cell(formatCurrency(entry.fundSize), width: columns[1].width, color: .textSecondary)
            cell(formatCurrency(entry.equity), width: columns[2].width, color: .mint)
            cell(formatCurrency(entry.cash), width: columns[3].width, color: .green)
            cell(entry.cashInterest > 0.01 ? formatCurrency(entry.cashInterest) : "-", width: columns[4].width, color: .cyan)
            cell(formatCurrency(entry.sumCashInterest), width: columns[5].width, color: .cyan.opacity(0.7))
            cell(entry.dividend > 0.01 ? formatCurrency(entry.dividend) : "-", width: columns[6].width, color: .mint)
            cell(formatCurrency(entry.sumDividends), width: columns[7].width, color: .mint.opacity(0.7))
            cell(entry.action?.rawValue ?? "HOLD", width: columns[8].width, color: actionColor(entry.action))
            cell(entry.amount > 0 ? formatCurrency(entry.amount) : "-", width: columns[9].width,
                 color: entry.amount > 0 ? (entry.action == .BUY ? .green : .red) : .textMuted)
            cell(formatCurrency(max(0, entry.invested)), width: columns[10].width, color: .blue)
            cell(formatCurrency(entry.unrealized), width: columns[11].width, color: entry.unrealized >= 0 ? .green : .red)
            cell(formatCurrency(entry.realized), width: columns[12].width, color: entry.realized >= 0 ? .green : .red)
            cell(formatCurrency(entry.liquidPnL), width: columns[13].width, color: entry.liquidPnL >= 0 ? .green : .red)
            cell(formatCurrency(entry.expectedTarget), width: columns[14].width, color: .cyan)
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(bgColor)
    }

    private func cell(_ text: String, width: CGFloat, alignment: Alignment = .trailing, color: Color) -> some View {
        Text(text)
            .frame(width: width, alignment: alignment)
            .foregroundColor(color)
    }

    private func actionColor(_ action: FundAction?) -> Color {
        switch action {
        case .BUY: return .green
        case .SELL: return .orange
        default: return .textMuted
        }
    }
}

// MARK: - Table Placeholder

struct BacktestTablePlaceholder: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(columns.prefix(9).enumerated()), id: \.offset) { _, col in
                    Text(col.title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.textMuted)
                        .frame(width: col.width, alignment: col.leading ? .leading : .trailing)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(Color.bgCard)

            Divider().background(Color.textMuted.opacity(0.3))

            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { _ in
                    HStack(spacing: 0) {
                        ForEach(0..<9, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.textMuted.opacity(0.1))
                                .frame(width: 55, height: 10)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.vertical, 6)
                    Divider().background(Color.textMuted.opacity(0.15))
                }
            }
            .shimmer()

            HStack {
                ProgressView().scaleEffect(0.7)
                Text("Loading entries...")
                    .font(.caption2).foregroundColor(.textMuted)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.bg.opacity(0.5))
        }
        .background(Color.bgCard)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.textMuted.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Shimmer Effect

struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.15), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase * 300)
                .mask(content)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .onDisappear {
                phase = -1
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}
