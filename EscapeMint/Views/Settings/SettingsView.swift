import SwiftUI

struct SettingsView: View {
    @State private var fundCount = 0
    @State private var dataSize = "..."

    var body: some View {
        NavigationStack {
            List {
                Section("Data") {
                    LabeledContent("Funds", value: "\(fundCount)")
                    LabeledContent("Data Size", value: dataSize)
                }

                Section("Actions") {
                    Button("Generate Test Data") { generateTestData() }
                    Button("Clear All Data", role: .destructive) { clearData() }
                }

                Section("About") {
                    LabeledContent("App", value: "EscapeMint")
                    LabeledContent("Version", value: "1.0.0")
                }
            }
            .navigationTitle("Settings")
            .task { await refreshStats() }
        }
    }

    private func refreshStats() async {
        let stats = await FundStore.shared.dataStats()
        fundCount = stats.fundCount
        dataSize = stats.formattedSize
    }

    private func generateTestData() {
        Task {
            // Stock fund
            var stockConfig = fundTypeDefaults[.stock]!
            stockConfig.fund_type = .stock
            stockConfig.status = .active
            stockConfig.category = .volatility
            stockConfig.fund_size_usd = 5000
            stockConfig.target_apy = 0.50
            stockConfig.input_min_usd = 1000
            stockConfig.input_mid_usd = 1000
            stockConfig.input_max_usd = 2000

            let stockEntries: [FundEntry] = [
                FundEntry(date: "2025-01-06", value: 500, action: .BUY, amount: 500, shares: 7.14, price: 70.00),
                FundEntry(date: "2025-01-13", value: 520, action: .HOLD),
                FundEntry(date: "2025-01-20", value: 480, action: .BUY, amount: 150, shares: 2.21, price: 67.87),
                FundEntry(date: "2025-02-03", value: 710, action: .HOLD),
                FundEntry(date: "2025-02-10", value: 690, action: .BUY, amount: 100, shares: 1.40, price: 71.43),
                FundEntry(date: "2025-03-03", value: 850, action: .HOLD),
                FundEntry(date: "2025-03-10", value: 780, action: .BUY, amount: 150, shares: 2.08, price: 72.12),
                FundEntry(date: "2025-04-01", value: 920, action: .HOLD),
                FundEntry(date: "2025-04-07", value: 1050, action: .HOLD),
            ]

            try? await FundStore.shared.writeFund(FundData(platform: "demo", ticker: "tqqq", config: stockConfig, entries: stockEntries))

            // Cash fund
            var cashConfig = fundTypeDefaults[.cash]!
            cashConfig.fund_type = .cash
            cashConfig.status = .active
            cashConfig.category = .liquidity
            cashConfig.fund_size_usd = 10000
            cashConfig.cash_apy = 0.04

            let cashEntries: [FundEntry] = [
                FundEntry(date: "2025-01-01", value: 5000, cash: 5000, action: .DEPOSIT, amount: 5000),
                FundEntry(date: "2025-02-01", value: 5200, cash: 5200, action: .DEPOSIT, amount: 200),
                FundEntry(date: "2025-03-01", value: 5400, cash: 5400, action: .DEPOSIT, amount: 200, cash_interest: 16.67),
            ]

            try? await FundStore.shared.writeFund(FundData(platform: "demo", ticker: "savings", config: cashConfig, entries: cashEntries))

            await refreshStats()
        }
    }

    private func clearData() {
        Task {
            try? await FundStore.shared.deleteAllFunds()
            await refreshStats()
        }
    }
}
