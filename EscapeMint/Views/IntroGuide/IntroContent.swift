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
            .quote("\"The stock market is a device for transferring money from the impatient to the patient... nobody wants to get rich slowly.\" — Warren Buffett"),
            .text("Getting rich is easy, as long as you're willing to do it slowly."),
            .text("You don't need to watch the news, analyze earnings reports, or pick individual stocks."),
            .text("Remove emotion, track your position and follow the rules.")
        ],
        chartType: .none,
        showDisclaimer: true
    ),
    IntroStepData(
        id: 2,
        title: "The Market Grows",
        content: [
            .text("The whole stock market grows at about 10% annually (long-term average)."),
            .text("Recently, it's been even higher — 20-40% in some years."),
            .text("This is the baseline we're building on.")
        ],
        chartType: .growth
    ),
    IntroStepData(
        id: 3,
        title: "But It's Not a Straight Line",
        content: [
            .text("However, the market doesn't grow in a steady straight line."),
            .text("It has volatility — wild swings up and down. Recessions and Bubbles."),
            .text("And for the long-term investor, this is actually GOOD news.")
        ],
        chartType: .volatility
    ),
    IntroStepData(
        id: 4,
        title: "Traditional DCA Falls Short",
        content: [
            .text("Most retirement advice centers around Dollar Cost Averaging (DCA): Invest the same amount every week/month, regardless of price."),
            .text("But this ignores a key opportunity: when the market is super inflated, it might be better to SELL than to buy."),
            .text("If you expect 20% annual growth, but you're clocking 50% APY... then regardless of the news, the market is overvalued relative to your target. And you can lock it in.")
        ],
        chartType: .traditionalDca
    ),
    IntroStepData(
        id: 5,
        title: "Volatility is Your Friend",
        content: [
            .text("For the DCA investor, higher volatility is actually BETTER:"),
            .bullet("When prices are LOW \u{2192} You buy MORE shares"),
            .bullet("When prices are HIGH \u{2192} You can harvest profits above your target"),
            .text("Think of it like extracting dividends from your own growth. This also gives you a constant cash pile to resume your DCA during the next recession.")
        ],
        chartType: .buySell
    ),
    IntroStepData(
        id: 6,
        title: "DCA In AND Out",
        content: [
            .text("This system dollar-cost-averages in BOTH directions:"),
            .bullet("DCA into dips (buy at lower prices)"),
            .bullet("DCA out of peaks (sell when above target)"),
            .text("Rules replace emotions. No FOMO. No panic selling.")
        ],
        chartType: .buySell
    ),
    IntroStepData(
        id: 7,
        title: "Two Modes: Harvest vs Accumulate",
        content: [
            .text("There are two ways to manage your fund:"),
            .boldLabel(label: "Harvest Mode:", color: .green, text: "For cash optimization. Fully exit when above target, then slowly rebuild. Great for volatile assets like TQQQ, SPXL."),
            .boldLabel(label: "Accumulate Mode:", color: .blue, text: "For long-term retirement. Take small profits, keep building your position. Great for stable index funds and buy-borrow-die strategies.")
        ],
        chartType: .modes
    ),
    IntroStepData(
        id: 8,
        title: "Buy Recessions, Sell Bubbles",
        content: [
            .text("In both modes, the strategy is the same:"),
            .text("Recession \u{2192} BUY more (prices are on sale)"),
            .text("Bubble \u{2192} SELL (lock in gains above target)"),
            .text("The system tells you exactly what to do, every week/month (intervals are configurable).")
        ],
        chartType: .buySell
    ),
    IntroStepData(
        id: 9,
        title: "Choosing Your Assets",
        content: [
            .boldLabel(label: "Core principle:", color: .blue, text: "Only invest in assets that can only go to zero if the entire economy collapses. Meme stocks can go to zero. If the whole market goes to zero, you have bigger problems."),
            .text("For long-term holdings: Total market indexes (VTI), Bitcoin (BTC), large-cap indexes. These are \"hold forever\" assets for retirement accounts."),
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
            .text("SPXL is a 3x leveraged long on the Russell 1000 Large Cap Index."),
            .text("More volatility = more opportunities to buy low and sell high."),
            .warning("Historical results are not guaranteed. The past decade was exceptionally favorable for leveraged ETFs. A regime change could significantly impair these products through volatility decay and higher borrowing costs."),
            .text("Your choice of assets depends on your risk tolerance and research.")
        ],
        chartType: .leverage
    ),
    IntroStepData(
        id: 11,
        title: "What This System Is NOT",
        content: [
            .text("This is NOT for:"),
            .crossBullet("Day trading meme stocks"),
            .crossBullet("Picking winners and losers"),
            .crossBullet("Betting against the market (shorting)"),
            .crossBullet("Apocalyptic hedging"),
            .text("This is a long-term bet that the market goes up over decades.")
        ],
        chartType: .none
    ),
    IntroStepData(
        id: 12,
        title: "Your Personal Configuration",
        content: [
            .text("You control:"),
            .bullet("Target APY (10% = sell sooner \u{2192} 40% = hold longer, accumulate more)"),
            .bullet("DCA amounts (how much to invest per period with tiers)"),
            .bullet("Check frequency (daily, weekly, monthly)"),
            .bullet("Which assets (indexes, bitcoin, leveraged ETFs, etc)"),
            .text("This works for IRAs, 401ks, or regular trading accounts. Your taxes and goals determine your settings.")
        ],
        chartType: .none
    ),
    IntroStepData(
        id: 13,
        title: "Get Started",
        content: [
            .text("Ready to simulate your first fund?"),
            .text("Try the backtest tool to see how this strategy would have performed with different assets and configurations."),
            .text("Then create your first real fund on the Dashboard when you're ready.")
        ],
        chartType: .none,
        showDisclaimer: true
    )
]
