import Foundation

func entriesToTrades(_ entries: [FundEntry]) -> [Trade] {
    entries.compactMap { e in
        guard let amount = e.amount, e.action == .BUY || e.action == .SELL else { return nil }
        var trade = Trade(date: e.date, amountUsd: amount, type: e.action == .BUY ? .buy : .sell)
        trade.shares = e.shares
        if e.action == .BUY || e.value > 0 { trade.value = e.value }
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
    entries.compactMap { e in
        guard let d = e.dividend, d > 0 else { return nil }
        return Dividend(date: e.date, amountUsd: d)
    }
}

func entriesToExpenses(_ entries: [FundEntry]) -> [Expense] {
    entries.compactMap { e in
        guard let exp = e.expense, exp > 0 else { return nil }
        return Expense(date: e.date, amountUsd: exp)
    }
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

let isoDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

let shortDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM ''yy"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

private let tooltipDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d, yyyy"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func formatDateLabel(_ dateStr: String) -> String {
    guard let date = isoDateFormatter.date(from: dateStr) else { return dateStr }
    return shortDateFormatter.string(from: date)
}

func formatTooltipDate(_ dateStr: String) -> String {
    guard let date = isoDateFormatter.date(from: dateStr) else { return dateStr }
    return tooltipDateFormatter.string(from: date)
}

func daysBetween(_ start: String, _ end: String) -> Int {
    guard let s = isoDateFormatter.date(from: start), let e = isoDateFormatter.date(from: end) else { return 0 }
    return Calendar.current.dateComponents([.day], from: s, to: e).day ?? 0
}

func todayString() -> String {
    isoDateFormatter.string(from: Date())
}
