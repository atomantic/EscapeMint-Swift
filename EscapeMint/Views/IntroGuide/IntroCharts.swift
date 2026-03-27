import SwiftUI
import Charts

// MARK: - Mode Comparison Preloader

@MainActor @Observable
final class ModeComparisonPreloader {
    static let shared = ModeComparisonPreloader()

    var harvestResult: BacktestResult?
    var accumulateResult: BacktestResult?
    private var started = false

    func preload() {
        guard !started else { return }
        started = true
        runIfDataReady()
    }

    /// Called when ViewCache finishes loading historical data
    func onHistoricalDataLoaded() {
        guard harvestResult == nil else { return }
        runIfDataReady()
    }

    private func runIfDataReady() {
        let cache = ViewCache.shared
        guard cache.isHistoricalDataLoaded else { return }

        var harvestCfg = BacktestConfig()
        harvestCfg.spxlPct = 0; harvestCfg.vtiPct = 0; harvestCfg.brgnxPct = 0
        harvestCfg.tqqqPct = 1.0; harvestCfg.btcPct = 0; harvestCfg.gldPct = 0; harvestCfg.slvPct = 0
        harvestCfg.targetAPY = 0.52; harvestCfg.accumulate = false; harvestCfg.inputMax = 350

        var accCfg = BacktestConfig()
        accCfg.spxlPct = 0; accCfg.vtiPct = 0; accCfg.brgnxPct = 0
        accCfg.tqqqPct = 1.0; accCfg.btcPct = 0; accCfg.gldPct = 0; accCfg.slvPct = 0
        accCfg.targetAPY = 0.20; accCfg.accumulate = true

        let hCfg = harvestCfg
        let aCfg = accCfg
        let hist = cache.historicalData
        Task {
            let (harvest, accumulate) = await Task.detached(priority: .userInitiated) {
                let h = runBacktest(config: hCfg, historicalData: hist)
                let a = runBacktest(config: aCfg, historicalData: hist)
                return (h, a)
            }.value
            harvestResult = harvest
            accumulateResult = accumulate
        }
    }
}

// MARK: - Shared Data & Helpers

private struct GrowthPoint: Identifiable {
    let id: Int
    let year: Int
    let value: Double
}

private struct DualLinePoint: Identifiable {
    let id: Int
    let x: Double
    let straight: Double
    let volatile: Double
}

private struct PriceTargetPoint: Identifiable {
    let id: Int
    let x: Double
    let price: Double
    let target: Double
    var buyZoneBottom: Double { min(price, target) }
    var sellZoneTop: Double { max(price, target) }
}

private struct BuySellBadge: Identifiable {
    let id: Int
    let x: Double
    let price: Double
    let isBuy: Bool
}

private struct LeveragePoint: Identifiable {
    let id: Int
    let date: String
    let brgnx: Double
    let spxl: Double
}

private let yearFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

private let investedPurple = Color(
    light: Color(red: 106/255, green: 58/255, blue: 210/255),
    dark: Color(red: 120/255, green: 70/255, blue: 220/255)
)

/// Cached historical data — loaded once from disk, shared across all intro charts


/// Shared price/target sample data used by TraditionalDCAChart and BuySellZonesChart
/// Uses 200 points for smooth step-based area fills
private let sharedPriceTargetData: (data: [PriceTargetPoint], yMin: Double, yMax: Double) = {
    var pts: [PriceTargetPoint] = []
    let points = 120
    for i in 0...points {
        let progress = Double(i) / Double(points)
        let x = progress * 60.0
        let target = 100.0 * pow(1.20, progress * 2.0)
        let wave1 = sin(progress * .pi * 4) * 25
        let wave2 = sin(progress * .pi * 7) * 15
        let price = target + wave1 + wave2
        pts.append(PriceTargetPoint(id: i, x: x, price: price, target: target))
    }
    let allValues = pts.flatMap { [$0.price, $0.target] }
    return (pts, (allValues.min() ?? 0) * 0.85, (allValues.max() ?? 200) * 1.1)
}()

/// Line marks only (no AreaMark — fills drawn via Canvas in chartBackground)
@ChartContentBuilder
private func priceTargetLines(_ visible: [PriceTargetPoint]) -> some ChartContent {
    ForEach(visible) { point in
        LineMark(x: .value("X", point.x), y: .value("TargetLine", point.target), series: .value("Series", "Target"))
            .foregroundStyle(Color.orange)
            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5]))
            .interpolationMethod(.monotone)
        LineMark(x: .value("X", point.x), y: .value("PriceLine", point.price), series: .value("Series", "Price"))
            .foregroundStyle(Color.textPrimary)
            .lineStyle(StrokeStyle(lineWidth: 2.5))
            .interpolationMethod(.monotone)
    }
}

/// Draws buy (green) and sell (configurable color) zone fills using Canvas, aligned to the chart plot area
private func zoneBackground(proxy: ChartProxy, data: [PriceTargetPoint], visibleCount: Int, sellColor: Color, showBuyZone: Bool = true, xDomain: ClosedRange<Double>, yDomain: ClosedRange<Double>) -> some View {
    GeometryReader { geo in
        if let plotFrame = proxy.plotFrame {
            let plotArea = geo[plotFrame]
            Canvas { context, size in
                let visible = Array(data.prefix(visibleCount))
                guard visible.count >= 2 else { return }

                func sx(_ x: Double) -> CGFloat {
                    let span = xDomain.upperBound - xDomain.lowerBound
                    return CGFloat((x - xDomain.lowerBound) / span) * plotArea.width + plotArea.origin.x
                }
                func sy(_ y: Double) -> CGFloat {
                    let span = yDomain.upperBound - yDomain.lowerBound
                    return plotArea.origin.y + plotArea.height - CGFloat((y - yDomain.lowerBound) / span) * plotArea.height
                }

                var buyPath = Path()
                var sellPath = Path()

                for i in 0..<visible.count - 1 {
                    let p0 = visible[i], p1 = visible[i + 1]
                    let d0 = p0.price - p0.target, d1 = p1.price - p1.target

                    if d0 * d1 >= 0 {
                        var trap = Path()
                        trap.move(to: CGPoint(x: sx(p0.x), y: sy(p0.target)))
                        trap.addLine(to: CGPoint(x: sx(p0.x), y: sy(p0.price)))
                        trap.addLine(to: CGPoint(x: sx(p1.x), y: sy(p1.price)))
                        trap.addLine(to: CGPoint(x: sx(p1.x), y: sy(p1.target)))
                        trap.closeSubpath()
                        if d0 >= 0 { sellPath.addPath(trap) }
                        else { buyPath.addPath(trap) }
                    } else {
                        let t = d0 / (d0 - d1)
                        let cx = p0.x + t * (p1.x - p0.x)
                        let cy = p0.target + t * (p1.target - p0.target)

                        var tri0 = Path()
                        tri0.move(to: CGPoint(x: sx(p0.x), y: sy(p0.target)))
                        tri0.addLine(to: CGPoint(x: sx(p0.x), y: sy(p0.price)))
                        tri0.addLine(to: CGPoint(x: sx(cx), y: sy(cy)))
                        tri0.closeSubpath()
                        if d0 >= 0 { sellPath.addPath(tri0) } else { buyPath.addPath(tri0) }

                        var tri1 = Path()
                        tri1.move(to: CGPoint(x: sx(cx), y: sy(cy)))
                        tri1.addLine(to: CGPoint(x: sx(p1.x), y: sy(p1.price)))
                        tri1.addLine(to: CGPoint(x: sx(p1.x), y: sy(p1.target)))
                        tri1.closeSubpath()
                        if d1 >= 0 { sellPath.addPath(tri1) } else { buyPath.addPath(tri1) }
                    }
                }

                if showBuyZone {
                    context.fill(buyPath, with: .color(.mint.opacity(0.4)))
                }
                context.fill(sellPath, with: .color(sellColor.opacity(0.4)))
            }
        }
    }
}

/// Finds local minima (BUY) and maxima (SELL) relative to target line
private func findBuySellBadges(in data: [PriceTargetPoint]) -> [BuySellBadge] {
    var found: [BuySellBadge] = []
    var badgeId = 0
    for i in 3..<(data.count - 3) {
        let price = data[i].price, target = data[i].target
        let prev = data[i - 1].price, next = data[i + 1].price
        if price < target && price < prev && price < next && (target - price) > 5 {
            found.append(BuySellBadge(id: badgeId, x: Double(i), price: price, isBuy: true))
            badgeId += 1
        }
        if price > target && price > prev && price > next && (price - target) > 5 {
            found.append(BuySellBadge(id: badgeId, x: Double(i), price: price, isBuy: false))
            badgeId += 1
        }
    }
    return found.count > 6 ? found.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) : found
}

/// Renders BUY/SELL badge labels positioned on the chart
@ViewBuilder
private func badgeOverlay(badges: [BuySellBadge], data: [PriceTargetPoint], visibleCount: Int, proxy: ChartProxy, geo: GeometryProxy) -> some View {
    if let plotFrame = proxy.plotFrame {
        let plotArea = geo[plotFrame]
        ForEach(badges.filter { $0.x < Double(visibleCount) }) { badge in
            let pt = data[Int(badge.x)]
            if let xPos = proxy.position(forX: pt.x),
               let yPos = proxy.position(forY: pt.price) {
                Text(badge.isBuy ? "BUY" : "SELL")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(badge.isBuy ? Color.mint : Color.red)
                    .cornerRadius(3)
                    .position(x: plotArea.origin.x + xPos,
                              y: plotArea.origin.y + yPos + (badge.isBuy ? 16 : -16))
            }
        }
    }
}

// MARK: - Intro dollar Y-axis (smaller values, no comma formatting)

@AxisContentBuilder
private func introDollarAxis() -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text("$\(Int(v))").font(.caption2).foregroundColor(.textMuted)
            }
        }
    }
}

@AxisContentBuilder
private func introKAxis() -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisValueLabel {
            if let v = value.as(Double.self) {
                if v >= 1000 {
                    Text("$\(Int(v / 1000))K").font(.caption2).foregroundColor(.textMuted)
                } else {
                    Text("\(Int(v))").font(.caption2).foregroundColor(.textMuted)
                }
            }
        }
    }
}

// MARK: - Market Growth Chart (Step 2)

struct MarketGrowthChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationProgress: Double = 0

    private let data: [GrowthPoint] = {
        var pts: [GrowthPoint] = []
        var value = 100.0
        for i in 0...20 {
            pts.append(GrowthPoint(id: i, year: 2005 + i, value: value))
            value *= 1.10
        }
        return pts
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("$100 invested growing at 10% annually")
                .font(.caption).foregroundColor(.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)

            let visibleCount = max(1, Int(animationProgress * Double(data.count)))
            let visible = Array(data.prefix(visibleCount))

            Chart(visible) { point in
                AreaMark(x: .value("Year", point.year), y: .value("Value", point.value))
                    .foregroundStyle(Color.mint.opacity(0.15))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Year", point.year), y: .value("Value", point.value))
                    .foregroundStyle(Color.mint)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...(data.last?.value ?? 700) * 1.1)
            .chartXScale(domain: 2005...2025)
            .chartXAxis {
                AxisMarks(values: .stride(by: 5)) { value in
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("\(v)").font(.caption2).foregroundColor(.textMuted)
                        }
                    }
                }
            }
            .chartYAxis { introDollarAxis() }
            .frame(height: 220)

            if visibleCount >= data.count {
                Text("$\(Int(data.last?.value ?? 0))")
                    .font(.caption).fontWeight(.bold).foregroundColor(.mint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }
        }
        .padding(12).cardStyle()
        .task {
            if reduceMotion { animationProgress = 1.0 }
            else { withAnimation(.easeInOut(duration: 2.0)) { animationProgress = 1.0 } }
        }
    }
}

// MARK: - Volatility Comparison Chart (Step 3)

struct VolatilityComparisonChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationProgress: Double = 0

    private let data: [DualLinePoint]
    private let yMin: Double
    private let yMax: Double

    init() {
        var pts: [DualLinePoint] = []
        let points = 100
        for i in 0...points {
            let progress = Double(i) / Double(points)
            let straight = 100.0 * pow(1.10, progress * 5.0)
            let wave1 = sin(progress * .pi * 8) * 30 * sin(progress * .pi)
            let wave2 = sin(progress * .pi * 15) * 10
            var volatile = straight + wave1 + wave2
            if i == points { volatile = straight }
            pts.append(DualLinePoint(id: i, x: Double(i), straight: straight, volatile: volatile))
        }
        self.data = pts
        let allValues = pts.flatMap { [$0.straight, $0.volatile] }
        self.yMin = (allValues.min() ?? 0) * 0.9
        self.yMax = (allValues.max() ?? 200) * 1.1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Same destination, different journey")
                .font(.caption).foregroundColor(.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)

            let visibleCount = max(1, Int(animationProgress * Double(data.count)))
            let visible = Array(data.prefix(visibleCount))

            Chart {
                ForEach(visible) { point in
                    AreaMark(x: .value("X", point.x), y: .value("RealityFill", point.volatile))
                        .foregroundStyle(Color.mint.opacity(0.1))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("X", point.x), y: .value("Expected", point.straight), series: .value("Series", "Expected"))
                        .foregroundStyle(Color.textMuted)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5]))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("X", point.x), y: .value("Reality", point.volatile), series: .value("Series", "Reality"))
                        .foregroundStyle(Color.mint)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis(.hidden)
            .chartXScale(domain: 0...100)
            .chartYScale(domain: yMin...yMax)
            .chartYAxis { introDollarAxis() }
            .chartLegend(.hidden)
            .frame(height: 220)

            HStack(spacing: 16) {
                LegendDot(color: .textMuted, label: "Expected (10%)")
                LegendDot(color: .mint, label: "Reality")
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(12).cardStyle()
        .task {
            if reduceMotion { animationProgress = 1.0 }
            else { withAnimation(.easeInOut(duration: 2.5)) { animationProgress = 1.0 } }
        }
    }
}

// MARK: - Traditional DCA Chart (Step 4)

struct TraditionalDCAChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationProgress: Double = 0

    private let data: [PriceTargetPoint]
    private let yMin: Double
    private let yMax: Double
    private let buyPoints: [BuySellBadge]

    init() {
        let shared = sharedPriceTargetData
        self.data = shared.data
        self.yMin = shared.yMin
        self.yMax = shared.yMax
        // Place BUY badges at evenly-spaced x positions across the chart
        let targetXs: [Double] = [5, 15, 25, 35, 45, 55]
        self.buyPoints = targetXs.enumerated().compactMap { idx, targetX in
            // Find the data point closest to this x position
            guard let pt = shared.data.min(by: { abs($0.x - targetX) < abs($1.x - targetX) }) else { return nil }
            return BuySellBadge(id: idx, x: Double(pt.id), price: pt.price, isBuy: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Traditional DCA: Always buying, never selling")
                .font(.caption).foregroundColor(.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)

            let visibleCount = max(1, Int(animationProgress * Double(data.count)))
            let visible = Array(data.prefix(visibleCount))

            Chart { priceTargetLines(visible) }
            .chartXAxis(.hidden)
            .chartXScale(domain: 0...60)
            .chartYScale(domain: yMin...yMax)
            .chartYAxis { introDollarAxis() }
            .chartLegend(.hidden)
            .chartBackground { proxy in
                zoneBackground(proxy: proxy, data: data, visibleCount: visibleCount, sellColor: .orange,
                               showBuyZone: false, xDomain: 0...60, yDomain: yMin...yMax)
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    badgeOverlay(badges: buyPoints, data: data, visibleCount: visibleCount, proxy: proxy, geo: geo)
                }
            }
            .frame(height: 220)

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.5)).frame(width: 12, height: 12)
                    Text("Missed sell opportunity").font(.caption2).foregroundColor(.textMuted)
                }
                LegendDot(color: .orange, label: "Target growth")
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(12).cardStyle()
        .task {
            if reduceMotion { animationProgress = 1.0 }
            else { withAnimation(.easeInOut(duration: 2.5)) { animationProgress = 1.0 } }
        }
    }
}

// MARK: - Buy/Sell Zones Chart (Steps 5, 6, 8)

struct BuySellZonesChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationProgress: Double = 0

    private let data: [PriceTargetPoint]
    private let yMin: Double
    private let yMax: Double
    private let badges: [BuySellBadge]

    init() {
        let shared = sharedPriceTargetData
        self.data = shared.data
        self.yMin = shared.yMin
        self.yMax = shared.yMax
        self.badges = findBuySellBadges(in: shared.data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Buy low, sell high — automatically")
                .font(.caption).foregroundColor(.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)

            let visibleCount = max(1, Int(animationProgress * Double(data.count)))
            let visible = Array(data.prefix(visibleCount))

            Chart { priceTargetLines(visible) }
            .chartXAxis(.hidden)
            .chartXScale(domain: 0...60)
            .chartYScale(domain: yMin...yMax)
            .chartYAxis { introDollarAxis() }
            .chartLegend(.hidden)
            .chartBackground { proxy in
                zoneBackground(proxy: proxy, data: data, visibleCount: visibleCount, sellColor: .red,
                               xDomain: 0...60, yDomain: yMin...yMax)
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    badgeOverlay(badges: badges, data: data, visibleCount: visibleCount, proxy: proxy, geo: geo)
                }
            }
            .frame(height: 220)

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.mint.opacity(0.5)).frame(width: 12, height: 12)
                    Text("Buy zone (below target)").font(.caption2).foregroundColor(.textMuted)
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.red.opacity(0.5)).frame(width: 12, height: 12)
                    Text("Sell zone (above target)").font(.caption2).foregroundColor(.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(12).cardStyle()
        .task {
            if reduceMotion { animationProgress = 1.0 }
            else { withAnimation(.easeInOut(duration: 2.5)) { animationProgress = 1.0 } }
        }
    }
}

// MARK: - Leverage Comparison Chart (Step 10)

struct LeverageComparisonChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationProgress: Double = 0
    @State private var viewMode: LeverageViewMode = .price
    @State private var cachedPriceData: [LeveragePoint] = []
    @State private var cachedDcaData: [LeveragePoint] = []

    enum LeverageViewMode: String, CaseIterable {
        case price = "Price"
        case dca = "$100/wk DCA"
    }

    private var chartData: [LeveragePoint] {
        sampleArray(viewMode == .price ? cachedPriceData : cachedDcaData, maxPoints: 80)
    }

    private func yRange(for data: [LeveragePoint]) -> ClosedRange<Double> {
        let allValues = data.flatMap { [$0.brgnx, $0.spxl] }
        let minVal = viewMode == .price ? 0 : (allValues.min() ?? 0) * 0.9
        let maxVal = (allValues.max() ?? 200) * 1.1
        return minVal...maxVal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("View", selection: $viewMode) {
                ForEach(LeverageViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 200)
            .frame(maxWidth: .infinity, alignment: .center)

            Text(viewMode == .price ? "Price: Normalized to 100 at start" : "DCA: $100/week invested")
                .font(.caption).foregroundColor(.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)

            let fullData = viewMode == .price ? cachedPriceData : cachedDcaData
            let fullRange = yRange(for: fullData)
            let sampled = chartData
            let visibleCount = max(1, Int(animationProgress * Double(sampled.count)))
            let visible = Array(sampled.prefix(visibleCount))

            // Compute fixed x-scale from full data so axis doesn't shift during animation
            let xDomain: ClosedRange<Date> = {
                let dates = fullData.compactMap { isoDateFormatter.date(from: $0.date) }
                let minDate = dates.min() ?? Date()
                let maxDate = dates.max() ?? Date()
                return minDate...maxDate
            }()

            Chart {
                ForEach(visible) { point in
                    let date = isoDateFormatter.date(from: point.date) ?? Date()
                    LineMark(x: .value("Date", date), y: .value("BRGNX", point.brgnx), series: .value("Series", "BRGNX"))
                        .foregroundStyle(Color.blue).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
                    LineMark(x: .value("Date", date), y: .value("SPXL", point.spxl), series: .value("Series", "SPXL"))
                        .foregroundStyle(Color.mint).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
                }
            }
            .chartXAxis { emDateAxisTemporal() }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: fullRange)
            .chartYAxis { introKAxis() }
            .chartLegend(.hidden)
            .frame(height: 220)

            HStack(spacing: 16) {
                LegendDot(color: .blue, label: "BRGNX (Russell 1000)")
                LegendDot(color: .mint, label: "SPXL (3x leveraged)")
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(12).cardStyle()
        .task {
            if ViewCache.shared.isHistoricalDataLoaded {
                computeLeverageData()
                if reduceMotion { animationProgress = 1.0 }
                else { withAnimation(.easeInOut(duration: 2.0)) { animationProgress = 1.0 } }
            }
        }
        .onChange(of: ViewCache.shared.isHistoricalDataLoaded) { _, loaded in
            if loaded {
                computeLeverageData()
                animationProgress = 0
                if reduceMotion { animationProgress = 1.0 }
                else { withAnimation(.easeInOut(duration: 2.0)) { animationProgress = 1.0 } }
            }
        }
        .onChange(of: viewMode) { _, _ in
            animationProgress = 0
            if reduceMotion { animationProgress = 1.0 }
            else { withAnimation(.easeInOut(duration: 2.0)) { animationProgress = 1.0 } }
        }
    }

    private func computeLeverageData() {
        let hist = ViewCache.shared.historicalData
        guard let brgnx = hist["BRGNX"], let spxl = hist["SPXL"] else { return }
        let spxlByDate = Dictionary(uniqueKeysWithValues: spxl.prices.map { ($0.date, $0.value) })
        let brgnxStart = brgnx.prices.first?.value ?? 1
        let spxlStart = spxl.prices.first?.value ?? 1

        var pricePoints: [LeveragePoint] = []
        var dcaPoints: [LeveragePoint] = []
        var brgnxShares = 0.0, spxlShares = 0.0
        let weekly = 100.0

        for (i, bp) in brgnx.prices.enumerated() {
            guard let sv = spxlByDate[bp.date] else { continue }
            pricePoints.append(LeveragePoint(id: i, date: bp.date,
                brgnx: (bp.value / brgnxStart) * 100, spxl: (sv / spxlStart) * 100))
            brgnxShares += weekly / bp.value
            spxlShares += weekly / sv
            dcaPoints.append(LeveragePoint(id: i, date: bp.date,
                brgnx: brgnxShares * bp.value, spxl: spxlShares * sv))
        }
        cachedPriceData = pricePoints
        cachedDcaData = dcaPoints
    }
}

// MARK: - Mode Comparison Chart (Step 7)

struct ModeComparisonChart: View {
    var preloader: ModeComparisonPreloader

    var body: some View {
        VStack(spacing: 12) {
            if let harvest = preloader.harvestResult, let accumulate = preloader.accumulateResult {
                HStack(spacing: 12) {
                    modeChart(result: harvest, targetAPY: 0.52, title: "Harvest Mode (TQQQ)", color: .mint)
                    modeChart(result: accumulate, targetAPY: 0.20, title: "Accumulate Mode (TQQQ)", color: .blue)
                }

                HStack(spacing: 12) {
                    legendItem(color: .orange, label: "Value", style: .line)
                    legendItem(color: investedPurple, label: "Invested", style: .square)
                    legendItem(color: .mint, label: "Cash", style: .square)
                    legendItem(color: .cyan, label: "Target", style: .dashed)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ProgressView("Loading backtest data...")
                    .frame(height: 180).frame(maxWidth: .infinity)
            }
        }
        .padding(12).cardStyle()
    }

    private enum LegendStyle { case line, square, dashed }

    @ViewBuilder
    private func legendItem(color: Color, label: String, style: LegendStyle) -> some View {
        HStack(spacing: 4) {
            switch style {
            case .line:
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 12, height: 2)
            case .square:
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.6)).frame(width: 8, height: 8)
            case .dashed:
                HStack(spacing: 1) {
                    ForEach(0..<3, id: \.self) { _ in Rectangle().fill(color).frame(width: 3, height: 2) }
                }
            }
            Text(label).font(.system(size: 9)).foregroundColor(.textMuted)
        }
    }

    @ViewBuilder
    private func modeChart(result: BacktestResult, targetAPY: Double, title: String, color: Color) -> some View {
        let sampled = sampleArray(result.entries, maxPoints: 200)

        let yMax: Double = {
            var m = 0.0
            for e in result.entries { m = max(m, e.equity, e.invested + e.cash, e.expectedTarget) }
            return m * 1.1
        }()

        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption).fontWeight(.bold).foregroundColor(color)
                .frame(maxWidth: .infinity, alignment: .center)

            Chart {
                ForEach(sampled.indices, id: \.self) { i in
                    let entry = sampled[i]
                    let date = isoDateFormatter.date(from: entry.date) ?? Date()

                    // Stacked areas: invested (bottom) + cash (top)
                    AreaMark(x: .value("Date", date), y: .value("Amount", entry.invested), stacking: .standard)
                        .foregroundStyle(by: .value("Fill", "Invested"))
                        .interpolationMethod(.linear)
                    AreaMark(x: .value("Date", date), y: .value("Amount", entry.cash), stacking: .standard)
                        .foregroundStyle(by: .value("Fill", "Cash"))
                        .interpolationMethod(.linear)
                    // Target line (dashed cyan)
                    LineMark(x: .value("Date", date), y: .value("Target", entry.expectedTarget), series: .value("Series", "Target"))
                        .foregroundStyle(Color.cyan)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .interpolationMethod(.monotone)
                    // Value/equity line (orange)
                    LineMark(x: .value("Date", date), y: .value("Value", entry.equity), series: .value("Series", "Value"))
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["Invested": investedPurple, "Cash": Color.green.opacity(0.6)])
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(yearFormatter.string(from: date))
                                .font(.system(size: 8)).foregroundColor(.textMuted)
                        }
                    }
                }
            }
            .chartYScale(domain: 0...yMax)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("$\(Int(v / 1000))K").font(.system(size: 8)).foregroundColor(.textMuted)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 180)
        }
    }
}
