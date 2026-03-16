import Foundation

enum IntroChartType {
    case none
    case growth
    case volatility
    case traditionalDca
    case buySell
    case leverage
    case modes
}

struct IntroStepData: Identifiable {
    let id: Int
    let title: String
    let content: [IntroContentItem]
    let chartType: IntroChartType
    let showDisclaimer: Bool

    init(id: Int, title: String, content: [IntroContentItem], chartType: IntroChartType, showDisclaimer: Bool = false) {
        self.id = id
        self.title = title
        self.content = content
        self.chartType = chartType
        self.showDisclaimer = showDisclaimer
    }
}

enum IntroContentItem {
    case text(String)
    case quote(String)
    case bullet(String)
    case crossBullet(String)
    case boldLabel(label: String, color: IntroLabelColor, text: String)
    case warning(String)
    case link(text: String, label: String)
}

enum IntroLabelColor {
    case green, blue, amber
}

let introSteps: [IntroStepData] = [
    IntroStepData(
        id: 1,
        title: "Getting Rich Slowly",
        content: [
            .quote("\"The stock market is a device for transferring money from the impatient to the patient.\" — Warren Buffett"),
            .text("Building wealth is straightforward — if you're willing to do it slowly."),
            .text("You don't need to watch the news, analyze earnings reports, or pick individual stocks."),
            .text("The approach is simple: remove emotion, track your position, and follow a consistent set of rules."),
            .text("A backtest simulates how a strategy would have performed using real historical market data.")
        ],
        chartType: .none,
        showDisclaimer: true
    ),
    IntroStepData(
        id: 2,
        title: "The Market Grows",
        content: [
            .text("Broad U.S. equity indexes have returned roughly 10% annually over the long term."),
            .text("In strong years, annual returns have reached 20–40% — but single-year returns vary widely."),
            .text("This long-term growth trend is the foundation of the strategy.")
        ],
        chartType: .growth
    ),
    IntroStepData(
        id: 3,
        title: "But It's Not a Straight Line",
        content: [
            .text("Market growth is not steady or linear."),
            .text("Prices swing through recessions and bubbles, sometimes violently."),
            .text("For a systematic, long-term investor, this volatility is actually an advantage.")
        ],
        chartType: .volatility
    ),
    IntroStepData(
        id: 4,
        title: "Traditional DCA Falls Short",
        content: [
            .text("Most retirement advice centers on Dollar Cost Averaging (DCA): invest a fixed amount at regular intervals, regardless of price."),
            .text("But this ignores a key opportunity: when the market is significantly above your growth target, it may be better to sell than to buy."),
            .text("If your target is 20% annualized growth but your position has returned 50%, the market is overvalued relative to your goal — regardless of the headlines. You can lock in those gains.")
        ],
        chartType: .traditionalDca
    ),
    IntroStepData(
        id: 5,
        title: "Volatility is Your Friend",
        content: [
            .text("For a systematic DCA investor, higher volatility is actually beneficial:"),
            .bullet("When prices are low \u{2192} You buy more shares"),
            .bullet("When prices are high \u{2192} You can harvest profits above your target"),
            .text("Think of it as harvesting returns from your own growth — a self-generated yield."),
            .text("The cash you extract becomes dry powder, ready to deploy when the next downturn arrives.")
        ],
        chartType: .buySell
    ),
    IntroStepData(
        id: 6,
        title: "DCA In AND Out",
        content: [
            .text("This system applies dollar-cost averaging in both directions:"),
            .bullet("DCA into dips (buy at lower prices)"),
            .bullet("DCA out of peaks (sell when above target)"),
            .text("Rules replace emotions. No fear of missing out. No panic selling.")
        ],
        chartType: .buySell
    ),
    IntroStepData(
        id: 7,
        title: "Two Modes: Harvest vs Accumulate",
        content: [
            .text("There are two ways to manage your fund:"),
            .boldLabel(label: "Harvest Mode:", color: .green, text: "Optimized for cash flow. Fully exit positions that exceed your target, then rebuild from a lower cost basis. Best suited for volatile assets like TQQQ and SPXL."),
            .boldLabel(label: "Accumulate Mode:", color: .blue, text: "Optimized for long-term growth. Take partial profits above your target while continuing to build your position. Best suited for broad index funds and long-term tax-advantaged accounts.")
        ],
        chartType: .modes
    ),
    IntroStepData(
        id: 8,
        title: "Buy Recessions, Sell Bubbles",
        content: [
            .text("In both modes, the strategy is the same:"),
            .bullet("Recession \u{2192} Buy more (prices are below your target)"),
            .bullet("Bubble \u{2192} Sell (lock in gains above target)"),
            .text("The system generates a specific recommendation at each interval — weekly, monthly, or on your custom schedule.")
        ],
        chartType: .buySell
    ),
    IntroStepData(
        id: 9,
        title: "Choosing Your Assets",
        content: [
            .boldLabel(label: "Core principle:", color: .blue, text: "Stick to assets that would only go to zero if the entire economy collapsed. Individual meme stocks can fail on their own. Broad indexes cannot — unless the whole system fails, at which point portfolio value is the least of anyone's concerns."),
            .text("For long-term holdings: broad market indexes (e.g., VTI), large-cap funds, or other assets you believe in for a multi-decade horizon."),
            .text("For cash management: Leveraged ETFs like TQQQ/SPXL can be used in harvest mode if you're confident the current market regime continues."),
            .text("The key is matching your asset choice to your goal: stable accumulation vs. aggressive cash harvesting.")
        ],
        chartType: .none
    ),
    IntroStepData(
        id: 10,
        title: "Leveraged ETFs = More Volatility",
        content: [
            .text("Example assets used in this guide:"),
            .text("TQQQ is a 3x leveraged long on the Nasdaq-100."),
            .text("SPXL is a 3x leveraged ETF tracking the S&P 500."),
            .text("More volatility = more opportunities to buy low and sell high."),
            .warning("Historical results are not guaranteed. The past decade was exceptionally favorable for leveraged ETFs. A sustained shift in market conditions — such as prolonged sideways movement or rising rates — could significantly impair these products through volatility decay and higher borrowing costs."),
            .text("Your choice of assets depends on your risk tolerance and research.")
        ],
        chartType: .leverage
    ),
    IntroStepData(
        id: 11,
        title: "What This System Is NOT",
        content: [
            .text("This system is not for:"),
            .crossBullet("Day trading meme stocks"),
            .crossBullet("Picking winners and losers"),
            .crossBullet("Betting against the market (shorting)"),
            .crossBullet("Hedging against total market collapse"),
            .text("This strategy rests on one core assumption: that broad markets trend upward over decades.")
        ],
        chartType: .none
    ),
    IntroStepData(
        id: 12,
        title: "Your Personal Configuration",
        content: [
            .text("You control:"),
            .bullet("Target annualized return — a lower target (e.g., 10%) triggers sells sooner; a higher target (e.g., 40%) lets positions grow longer"),
            .bullet("DCA amounts — how much to invest per period, with tiered scaling based on distance from your target"),
            .bullet("Check frequency (daily, weekly, monthly)"),
            .bullet("Which assets (indexes, bitcoin, leveraged ETFs, etc)"),
            .text("This works for IRAs, 401(k)s, or taxable brokerage accounts. Your taxes and goals determine your settings.")
        ],
        chartType: .none
    ),
    IntroStepData(
        id: 13,
        title: "Get Started",
        content: [
            .text("Ready to see the strategy in action? Run a backtest with historical data to explore how different assets and configurations would have performed."),
            .text("When you're ready, head to the Dashboard to create your first fund.")
        ],
        chartType: .none,
        showDisclaimer: true
    )
]
