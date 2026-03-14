import Foundation

func entriesToTrades(_ entries: [FundEntry]) -> [Trade] {
    entries
        .filter { $0.amount != nil && ($0.action == .BUY || $0.action == .SELL) }
        .map { e in
            var trade = Trade(
                date: e.date,
                amountUsd: e.amount!,
                type: e.action == .BUY ? .buy : .sell
            )
            trade.shares = e.shares
            if e.action == .BUY || (e.value > 0) {
                trade.value = e.value
            }
            return trade
        }
}

func entriesToCashFlows(_ entries: [FundEntry]) -> [CashFlow] {
    entries
        .compactMap { e -> CashFlow? in
            guard let amount = e.amount else { return nil }
            if e.action == .HOLD {
                if amount == 0 { return nil }
                return CashFlow(
                    date: e.date,
                    amountUsd: abs(amount),
                    type: amount > 0 ? .deposit : .withdrawal
                )
            }
            guard e.action == .DEPOSIT || e.action == .WITHDRAW else { return nil }
            return CashFlow(
                date: e.date,
                amountUsd: amount,
                type: e.action == .DEPOSIT ? .deposit : .withdrawal
            )
        }
}

func entriesToDividends(_ entries: [FundEntry]) -> [Dividend] {
    entries
        .filter { ($0.dividend ?? 0) > 0 }
        .map { Dividend(date: $0.date, amountUsd: $0.dividend!) }
}

func entriesToExpenses(_ entries: [FundEntry]) -> [Expense] {
    entries
        .filter { ($0.expense ?? 0) > 0 }
        .map { Expense(date: $0.date, amountUsd: $0.expense!) }
}

func getLatestValue(_ entries: [FundEntry]) -> Double {
    entries.last?.value ?? 0
}

func getFundStartDate(_ entries: [FundEntry]) -> String {
    guard let first = entries.min(by: { $0.date < $1.date }) else {
        return ISO8601DateFormatter().string(from: Date()).prefix(10).description
    }
    return first.date
}

func daysBetween(_ start: String, _ end: String) -> Int {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    guard let s = fmt.date(from: start), let e = fmt.date(from: end) else { return 0 }
    return Calendar.current.dateComponents([.day], from: s, to: e).day ?? 0
}

func todayString() -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    return fmt.string(from: Date())
}
