import SwiftUI

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
                        tableHeaderCell("Date", width: 90, sortable: true)
                        tableHeaderCell("Fund Size", width: 85)
                        tableHeaderCell("Equity", width: 85)
                        tableHeaderCell("Cash", width: 85)
                        tableHeaderCell("Interest", width: 70)
                        tableHeaderCell("\u{03A3} Interest", width: 75)
                        tableHeaderCell("Dividend", width: 70)
                        tableHeaderCell("\u{03A3} Dividend", width: 80)
                        tableHeaderCell("Action", width: 55)
                        tableHeaderCell("Amount", width: 80)
                        tableHeaderCell("Invested", width: 80)
                        tableHeaderCell("Unrealized", width: 85)
                        tableHeaderCell("Realized", width: 85)
                        tableHeaderCell("Liquid P&L", width: 85)
                        tableHeaderCell("Target", width: 85)
                    }
                    .padding(.vertical, 6)
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

    // MARK: - Table Header Cell

    private func tableHeaderCell(_ title: String, width: CGFloat, sortable: Bool = false) -> some View {
        Group {
            if sortable {
                Button {
                    sortOrder = sortOrder == .asc ? .desc : .asc
                } label: {
                    HStack(spacing: 2) {
                        Text(title)
                        Text(sortOrder == .asc ? "\u{25B2}" : "\u{25BC}")
                            .font(.system(size: 8))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.textMuted)
                    .frame(width: width, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.textMuted)
                    .frame(width: width, alignment: .trailing)
            }
        }
        .padding(.horizontal, 4)
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
            Text(entry.date)
                .frame(width: 90, alignment: .leading)
                .foregroundColor(.textPrimary)

            Text(formatCurrency(entry.fundSize))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(.textSecondary)

            Text(formatCurrency(entry.equity))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(.mint)

            Text(formatCurrency(entry.cash))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(.green)

            Text(entry.cashInterest > 0.01 ? formatCurrency(entry.cashInterest) : "-")
                .frame(width: 70, alignment: .trailing)
                .foregroundColor(.cyan)

            Text(formatCurrency(entry.sumCashInterest))
                .frame(width: 75, alignment: .trailing)
                .foregroundColor(.cyan.opacity(0.7))

            Text(entry.dividend > 0.01 ? formatCurrency(entry.dividend) : "-")
                .frame(width: 70, alignment: .trailing)
                .foregroundColor(.mint)

            Text(formatCurrency(entry.sumDividends))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(.mint.opacity(0.7))

            Text(entry.action?.rawValue ?? "HOLD")
                .frame(width: 55, alignment: .trailing)
                .foregroundColor(actionColor(entry.action))

            Group {
                if entry.amount > 0 {
                    Text(formatCurrency(entry.amount))
                        .foregroundColor(entry.action == .BUY ? .green : .red)
                } else {
                    Text("-").foregroundColor(.textMuted)
                }
            }
            .frame(width: 80, alignment: .trailing)

            Text(formatCurrency(max(0, entry.invested)))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(.blue)

            Text(formatCurrency(entry.unrealized))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(entry.unrealized >= 0 ? .green : .red)

            Text(formatCurrency(entry.realized))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(entry.realized >= 0 ? .green : .red)

            Text(formatCurrency(entry.liquidPnL))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(entry.liquidPnL >= 0 ? .green : .red)

            Text(formatCurrency(entry.expectedTarget))
                .frame(width: 85, alignment: .trailing)
                .foregroundColor(.cyan)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(bgColor)
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
                ForEach(["Date", "Fund Size", "Equity", "Cash", "Action", "Amount", "Invested", "Unrealized", "Realized"], id: \.self) { title in
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.textMuted)
                        .frame(width: 85, alignment: title == "Date" ? .leading : .trailing)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.vertical, 6)
            .background(Color.bgCard)

            Divider().background(Color.textMuted.opacity(0.3))

            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { _ in
                    HStack(spacing: 0) {
                        ForEach(0..<9, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.textMuted.opacity(0.1))
                                .frame(width: 65, height: 10)
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
