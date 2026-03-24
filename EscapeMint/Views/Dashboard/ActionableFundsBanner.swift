import SwiftUI

struct ActionableFundsBanner: View {
    let actionableFunds: [ActionableFund]
    @Binding var dismissedIds: Set<String>
    @State private var showDismissed = false

    var visibleFunds: [ActionableFund] {
        showDismissed ? actionableFunds : actionableFunds.filter { !dismissedIds.contains($0.id) }
    }

    var dismissedCount: Int {
        actionableFunds.filter { dismissedIds.contains($0.id) }.count
    }

    var body: some View {
        if !visibleFunds.isEmpty || dismissedCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "bell.badge.fill")
                        .foregroundColor(.orange)
                        .accessibilityHidden(true)
                    Text("\(actionableFunds.count) fund\(actionableFunds.count == 1 ? "" : "s") need\(actionableFunds.count == 1 ? "s" : "") attention")
                        .font(.headline).foregroundColor(.textPrimary)
                    Spacer()
                    if dismissedCount > 0 && !showDismissed {
                        Button {
                            showDismissed = true
                        } label: {
                            Text("Show \(dismissedCount) dismissed")
                                .font(.caption2).foregroundColor(.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleFunds) { af in
                            ActionableFundCard(actionableFund: af) {
                                dismissedIds.insert(af.id)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .cardStyle()
        }
    }
}

struct ActionableFundCard: View {
    let actionableFund: ActionableFund
    let onDismiss: () -> Void

    private var borderColor: Color {
        switch actionableFund.urgency {
        case .overdue: return .red
        case .dueToday: return .orange
        case .upcoming: return .yellow
        }
    }

    private var statusText: String {
        if actionableFund.needsCashDeposit { return "Deposit cash to start DCA" }
        switch actionableFund.urgency {
        case .overdue: return "\(actionableFund.daysOverdue)d overdue"
        case .dueToday: return "Due today"
        case .upcoming: return "Due in \(abs(actionableFund.daysOverdue))d"
        }
    }

    var body: some View {
        #if os(macOS)
        cardContent
            .onTapGesture {
                NotificationCenter.default.post(name: .selectFund, object: actionableFund.fund.id)
                NotificationCenter.default.post(name: .showAddEntry, object: actionableFund.fund.id)
            }
        #else
        NavigationLink(destination: FundDetailView(fundId: actionableFund.fund.id, autoShowAddEntry: true)) {
            cardContent
        }
        .buttonStyle(.plain)
        #endif
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(actionableFund.fund.ticker.uppercased())
                    .font(.callout).fontWeight(.bold).foregroundColor(.textPrimary)
                Text(actionableFund.fund.platform.capitalized)
                    .font(.caption).foregroundColor(.textSecondary)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2).foregroundColor(.textMuted)
                }
                .buttonStyle(.plain)
            }
            Text(statusText)
                .font(.caption).foregroundColor(actionableFund.needsCashDeposit ? .orange : .textSecondary)
            if !actionableFund.needsCashDeposit {
                Text("\(actionableFund.intervalDays)d interval")
                    .font(.caption2).foregroundColor(.textMuted)
            }
        }
        .padding(10)
        .frame(minWidth: 160)
        .background(Color.bgCard)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 2)
        )
        .cornerRadius(8)
        .contentShape(Rectangle())
    }
}
