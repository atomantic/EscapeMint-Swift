import Foundation

/// Metadata for one column in the fund detail entries table.
struct EntryColumn {
    let id: String
    let label: String
    /// Whether the column is shown by default for fund types that allow it.
    let defaultVisible: Bool
    /// Fund types that never show this column.
    let excludeFrom: Set<FundType>
}

/// All entry-table columns in canonical order (ordered to match the web app).
/// Extracted from `FundDetailView` so the metadata lives with the data model
/// rather than the view. See `FundDetailView` for visibility/order handling.
let allEntryColumns: [EntryColumn] = [
    EntryColumn(id: "date", label: "Date", defaultVisible: true, excludeFrom: []),
    EntryColumn(id: "action", label: "Action", defaultVisible: true, excludeFrom: [.cash]),
    EntryColumn(id: "shares", label: "Shares", defaultVisible: false, excludeFrom: [.cash, .derivatives]),
    EntryColumn(id: "sum_shares", label: "\u{03A3} Shares", defaultVisible: false, excludeFrom: [.cash, .derivatives]),
    EntryColumn(id: "price", label: "Price", defaultVisible: false, excludeFrom: [.cash]),
    EntryColumn(id: "amount", label: "Amount", defaultVisible: true, excludeFrom: []),
    EntryColumn(id: "value", label: "Equity", defaultVisible: true, excludeFrom: [.derivatives]),
    EntryColumn(id: "cash", label: "Cash", defaultVisible: false, excludeFrom: [.cash]),
    EntryColumn(id: "invested", label: "Invested", defaultVisible: true, excludeFrom: [.cash, .derivatives]),
    EntryColumn(id: "dividend", label: "Dividend", defaultVisible: true, excludeFrom: [.cash, .crypto, .derivatives]),
    EntryColumn(id: "expense", label: "Expense", defaultVisible: false, excludeFrom: [.derivatives]),
    EntryColumn(id: "fund_size", label: "Fund Size", defaultVisible: false, excludeFrom: [.derivatives]),
    EntryColumn(id: "extracted", label: "Extracted", defaultVisible: true, excludeFrom: [.cash, .derivatives]),
    EntryColumn(id: "cash_interest", label: "Cash Int", defaultVisible: false, excludeFrom: [.derivatives]),
    EntryColumn(id: "unrealized", label: "Unrealized", defaultVisible: true, excludeFrom: [.cash]),
    EntryColumn(id: "realized", label: "Realized", defaultVisible: true, excludeFrom: []),
    EntryColumn(id: "liquid_pnl", label: "Liquid P&L", defaultVisible: true, excludeFrom: [.cash]),
    EntryColumn(id: "realized_apy", label: "Realized APY", defaultVisible: true, excludeFrom: []),
    EntryColumn(id: "liquid_apy", label: "Liq APY", defaultVisible: true, excludeFrom: [.cash]),
    EntryColumn(id: "sum_expense", label: "\u{03A3} Exp", defaultVisible: false, excludeFrom: [.derivatives]),
    EntryColumn(id: "sum_dividends", label: "\u{03A3} Div", defaultVisible: false, excludeFrom: [.cash, .crypto, .derivatives]),
    EntryColumn(id: "sum_extracted", label: "\u{03A3} Extracted", defaultVisible: false, excludeFrom: [.cash, .derivatives]),
    EntryColumn(id: "sum_cash_int", label: "\u{03A3} Int", defaultVisible: false, excludeFrom: [.derivatives]),
    EntryColumn(id: "margin_available", label: "Margin Avail", defaultVisible: false, excludeFrom: []),
    EntryColumn(id: "margin_borrowed", label: "Margin Borrowed", defaultVisible: false, excludeFrom: []),
    EntryColumn(id: "notes", label: "Notes", defaultVisible: false, excludeFrom: []),
    // Derivatives-specific (ordered to match web app)
    EntryColumn(id: "contracts", label: "Contracts", defaultVisible: false, excludeFrom: [.cash, .stock, .crypto]),
    EntryColumn(id: "fee", label: "Fee", defaultVisible: false, excludeFrom: [.cash, .stock, .crypto]),
    EntryColumn(id: "position", label: "Position", defaultVisible: false, excludeFrom: [.cash, .stock, .crypto]),
    EntryColumn(id: "entry_price", label: "Avg Entry", defaultVisible: false, excludeFrom: [.cash, .stock, .crypto]),
    EntryColumn(id: "deriv_cash", label: "Cash", defaultVisible: false, excludeFrom: [.cash, .stock, .crypto]),
    EntryColumn(id: "margin_locked", label: "Margin Locked", defaultVisible: false, excludeFrom: [.cash, .stock, .crypto]),
    EntryColumn(id: "liquidation_price", label: "Liq Price", defaultVisible: false, excludeFrom: [.cash, .stock, .crypto]),
    EntryColumn(id: "deriv_equity", label: "Equity", defaultVisible: false, excludeFrom: [.cash, .stock, .crypto]),
    EntryColumn(id: "unrealized_pnl", label: "Unrealized", defaultVisible: false, excludeFrom: [.cash, .stock, .crypto]),
]
