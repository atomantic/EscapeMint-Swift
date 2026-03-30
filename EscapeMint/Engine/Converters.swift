import Foundation

func entriesToTrades(_ entries: [FundEntry]) -> [Trade] {
    entries.compactMap { e in
        guard let amount = e.amount, amount != 0, e.action == .BUY || e.action == .SELL else { return nil }
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
            guard e.action == .DEPOSIT || e.action == .WITHDRAW, amount != 0 else { return nil }
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
        return todayString()
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

// MARK: - Stock Trading Day Detection

nonisolated(unsafe) private var holidayCache: (year: Int, holidays: Set<String>)?

/// US stock market holidays (observed dates). Returns holidays for a given year.
func usMarketHolidays(year: Int) -> Set<String> {
    if let cached = holidayCache, cached.year == year { return cached.holidays }
    let holidays = computeUSMarketHolidays(year: year)
    holidayCache = (year, holidays)
    return holidays
}

private func computeUSMarketHolidays(year: Int) -> Set<String> {
    var holidays = Set<String>()
    let cal = Calendar(identifier: .gregorian)

    func fmt(_ m: Int, _ d: Int) -> String {
        String(format: "%04d-%02d-%02d", year, m, d)
    }

    // Fixed-date holidays (with Sat→Fri, Sun→Mon observation rules)
    func observed(_ month: Int, _ day: Int) {
        guard let date = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return }
        let wd = cal.component(.weekday, from: date)
        if wd == 7 { // Saturday → observe Friday
            holidays.insert(fmt(month, day - 1 > 0 ? day - 1 : day))
        } else if wd == 1 { // Sunday → observe Monday
            holidays.insert(fmt(month, day + 1))
        } else {
            holidays.insert(fmt(month, day))
        }
    }

    // Nth weekday of month
    func nthWeekday(_ n: Int, weekday: Int, month: Int) -> String? {
        var comps = DateComponents(year: year, month: month)
        comps.weekday = weekday
        comps.weekdayOrdinal = n
        guard let date = cal.date(from: comps) else { return nil }
        return isoDateFormatter.string(from: date)
    }

    // New Year's Day — Jan 1
    observed(1, 1)

    // MLK Day — 3rd Monday of January
    if let d = nthWeekday(3, weekday: 2, month: 1) { holidays.insert(d) }

    // Presidents' Day — 3rd Monday of February
    if let d = nthWeekday(3, weekday: 2, month: 2) { holidays.insert(d) }

    // Good Friday — 2 days before Easter
    if let easter = computeEaster(year: year) {
        if let gf = cal.date(byAdding: .day, value: -2, to: easter) {
            holidays.insert(isoDateFormatter.string(from: gf))
        }
    }

    // Memorial Day — last Monday of May
    for day in stride(from: 31, through: 25, by: -1) {
        if let date = cal.date(from: DateComponents(year: year, month: 5, day: day)),
           cal.component(.weekday, from: date) == 2 {
            holidays.insert(fmt(5, day))
            break
        }
    }

    // Juneteenth — June 19
    observed(6, 19)

    // Independence Day — July 4
    observed(7, 4)

    // Labor Day — 1st Monday of September
    if let d = nthWeekday(1, weekday: 2, month: 9) { holidays.insert(d) }

    // Thanksgiving — 4th Thursday of November
    if let d = nthWeekday(4, weekday: 5, month: 11) { holidays.insert(d) }

    // Christmas — Dec 25
    observed(12, 25)

    return holidays
}

/// Compute Easter Sunday via the Anonymous Gregorian algorithm
private func computeEaster(year: Int) -> Date? {
    let a = year % 19
    let b = year / 100
    let c = year % 100
    let d = b / 4
    let e = b % 4
    let f = (b + 8) / 25
    let g = (b - f + 1) / 3
    let h = (19 * a + b - d - g + 15) % 30
    let i = c / 4
    let k = c % 4
    let l = (32 + 2 * e + 2 * i - h - k) % 7
    let m = (a + 11 * h + 22 * l) / 451
    let month = (h + l - 7 * m + 114) / 31
    let day = ((h + l - 7 * m + 114) % 31) + 1
    return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
}

/// Whether the given ISO date string (yyyy-MM-dd) is a US stock market trading day
func isStockTradingDay(_ dateStr: String) -> Bool {
    guard let date = isoDateFormatter.date(from: dateStr) else { return false }
    let weekday = Calendar.current.component(.weekday, from: date)
    // 1 = Sunday, 7 = Saturday
    if weekday == 1 || weekday == 7 { return false }
    let year = Calendar.current.component(.year, from: date)
    return !usMarketHolidays(year: year).contains(dateStr)
}

/// Whether the given Date is a US stock market trading day
func isStockTradingDay(_ date: Date) -> Bool {
    isStockTradingDay(isoDateFormatter.string(from: date))
}

/// Returns the next trading day on or after the given date. For stock funds,
/// skips weekends and US market holidays. For non-stock funds, returns the input.
func nextTradingDay(from date: Date, fundType: FundType?) -> Date {
    guard fundType == .stock else { return date }
    let cal = Calendar.current
    var candidate = date
    // Safety limit to avoid infinite loops
    for _ in 0..<10 {
        if isStockTradingDay(candidate) { return candidate }
        candidate = cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }
    return candidate
}
