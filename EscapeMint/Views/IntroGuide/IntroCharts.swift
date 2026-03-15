import SwiftUI
import Charts

// MARK: - Chart Data Types

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

// MARK: - Market Growth Chart (Step 2)

struct MarketGrowthChart: View {
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
                AreaMark(
                    x: .value("Year", point.year),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(Color.mint.opacity(0.15))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Year", point.year),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(Color.mint)
                .lineStyle(StrokeStyle(lineWidth: 3))
                .interpolationMethod(.catmullRom)
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
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("$\(Int(v))").font(.caption2).foregroundColor(.textMuted)
                        }
                    }
                }
            }
            .frame(height: 220)

            if visibleCount >= data.count {
                Text("$\(Int(data.last?.value ?? 0))")
                    .font(.caption).fontWeight(.bold).foregroundColor(.mint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0)) {
                animationProgress = 1.0
            }
        }
    }
}

// MARK: - Volatility Comparison Chart (Step 3)

struct VolatilityComparisonChart: View {
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
                    LineMark(
                        x: .value("X", point.x),
                        y: .value("Expected", point.straight),
                        series: .value("Series", "Expected")
                    )
                    .foregroundStyle(Color.textMuted)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5]))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("X", point.x),
                        y: .value("Reality", point.volatile),
                        series: .value("Series", "Reality")
                    )
                    .foregroundStyle(Color.mint)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartXScale(domain: 0...100)
            .chartYScale(domain: yMin...yMax)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("$\(Int(v))").font(.caption2).foregroundColor(.textMuted)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 220)

            HStack(spacing: 16) {
                LegendDot(color: .textMuted, label: "Expected (10%)")
                LegendDot(color: .mint, label: "Reality")
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.5)) {
                animationProgress = 1.0
            }
        }
    }
}

// MARK: - Traditional DCA Chart (Step 4)

struct TraditionalDCAChart: View {
    @State private var animationProgress: Double = 0

    private let data: [PriceTargetPoint]
    private let yMin: Double
    private let yMax: Double
    private let buyPoints: [BuySellBadge]

    init() {
        var pts: [PriceTargetPoint] = []
        let points = 60
        for i in 0...points {
            let progress = Double(i) / Double(points)
            let target = 100.0 * pow(1.20, progress * 2.0)
            let wave1 = sin(progress * .pi * 4) * 25
            let wave2 = sin(progress * .pi * 7) * 15
            let price = target + wave1 + wave2
            pts.append(PriceTargetPoint(id: i, x: Double(i), price: price, target: target))
        }
        self.data = pts
        let allValues = pts.flatMap { [$0.price, $0.target] }
        self.yMin = (allValues.min() ?? 0) * 0.85
        self.yMax = (allValues.max() ?? 200) * 1.1

        self.buyPoints = [5, 15, 25, 35, 45, 55].enumerated().map { idx, pos in
            BuySellBadge(id: idx, x: Double(pos), price: pts[pos].price, isBuy: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Traditional DCA: Always buying, never selling")
                .font(.caption).foregroundColor(.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)

            let visibleCount = max(1, Int(animationProgress * Double(data.count)))
            let visible = Array(data.prefix(visibleCount))

            Chart {
                ForEach(visible) { point in
                    if point.price > point.target {
                        AreaMark(
                            x: .value("X", point.x),
                            yStart: .value("Target", point.target),
                            yEnd: .value("Price", point.price)
                        )
                        .foregroundStyle(Color.orange.opacity(0.3))
                        .interpolationMethod(.catmullRom)
                    }
                }

                ForEach(visible) { point in
                    LineMark(
                        x: .value("X", point.x),
                        y: .value("Target", point.target),
                        series: .value("Series", "Target")
                    )
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5]))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("X", point.x),
                        y: .value("Price", point.price),
                        series: .value("Series", "Price")
                    )
                    .foregroundStyle(Color.textPrimary)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartXScale(domain: 0...60)
            .chartYScale(domain: yMin...yMax)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("$\(Int(v))").font(.caption2).foregroundColor(.textMuted)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
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
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.5)) {
                animationProgress = 1.0
            }
        }
    }
}

// MARK: - Buy/Sell Zones Chart (Steps 5, 6, 8)

struct BuySellZonesChart: View {
    @State private var animationProgress: Double = 0

    private let data: [PriceTargetPoint]
    private let yMin: Double
    private let yMax: Double

    init() {
        var pts: [PriceTargetPoint] = []
        let points = 60
        for i in 0...points {
            let progress = Double(i) / Double(points)
            let target = 100.0 * pow(1.20, progress * 2.0)
            let wave1 = sin(progress * .pi * 4) * 25
            let wave2 = sin(progress * .pi * 7) * 15
            let price = target + wave1 + wave2
            pts.append(PriceTargetPoint(id: i, x: Double(i), price: price, target: target))
        }
        self.data = pts
        let allValues = pts.flatMap { [$0.price, $0.target] }
        self.yMin = (allValues.min() ?? 0) * 0.85
        self.yMax = (allValues.max() ?? 200) * 1.1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Buy low, sell high — automatically")
                .font(.caption).foregroundColor(.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)

            let visibleCount = max(1, Int(animationProgress * Double(data.count)))
            let visible = Array(data.prefix(visibleCount))

            Chart {
                ForEach(visible) { point in
                    if point.price < point.target {
                        AreaMark(
                            x: .value("X", point.x),
                            yStart: .value("Target", point.target),
                            yEnd: .value("Price", point.price)
                        )
                        .foregroundStyle(Color.mint.opacity(0.3))
                        .interpolationMethod(.catmullRom)
                    }
                }

                ForEach(visible) { point in
                    if point.price > point.target {
                        AreaMark(
                            x: .value("X", point.x),
                            yStart: .value("Target", point.target),
                            yEnd: .value("Price", point.price)
                        )
                        .foregroundStyle(Color.red.opacity(0.3))
                        .interpolationMethod(.catmullRom)
                    }
                }

                ForEach(visible) { point in
                    LineMark(
                        x: .value("X", point.x),
                        y: .value("Target", point.target),
                        series: .value("Series", "Target")
                    )
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5]))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("X", point.x),
                        y: .value("Price", point.price),
                        series: .value("Series", "Price")
                    )
                    .foregroundStyle(Color.textPrimary)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartXScale(domain: 0...60)
            .chartYScale(domain: yMin...yMax)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("$\(Int(v))").font(.caption2).foregroundColor(.textMuted)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 220)

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.mint.opacity(0.5)).frame(width: 12, height: 12)
                    Text("Buy zone").font(.caption2).foregroundColor(.textMuted)
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.red.opacity(0.5)).frame(width: 12, height: 12)
                    Text("Sell zone").font(.caption2).foregroundColor(.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.5)) {
                animationProgress = 1.0
            }
        }
    }
}

// MARK: - Leverage Comparison Chart (Step 10)

struct LeverageComparisonChart: View {
    @State private var animationProgress: Double = 0
    @State private var viewMode: LeverageViewMode = .price

    enum LeverageViewMode: String, CaseIterable {
        case price = "Price"
        case dca = "$100/wk DCA"
    }

    private let historicalData: [String: HistoricalData]

    init() {
        self.historicalData = loadHistoricalData()
    }

    private var priceData: [LeveragePoint] {
        guard let brgnx = historicalData["BRGNX"],
              let spxl = historicalData["SPXL"] else { return [] }
        let spxlByDate = Dictionary(uniqueKeysWithValues: spxl.prices.map { ($0.date, $0.value) })
        let brgnxStart = brgnx.prices.first?.value ?? 1
        let spxlStart = spxl.prices.first?.value ?? 1

        return brgnx.prices.enumerated().compactMap { i, bp in
            guard let sv = spxlByDate[bp.date] else { return nil }
            return LeveragePoint(
                id: i,
                date: bp.date,
                brgnx: (bp.value / brgnxStart) * 100,
                spxl: (sv / spxlStart) * 100
            )
        }
    }

    private var dcaData: [LeveragePoint] {
        guard let brgnx = historicalData["BRGNX"],
              let spxl = historicalData["SPXL"] else { return [] }
        let spxlByDate = Dictionary(uniqueKeysWithValues: spxl.prices.map { ($0.date, $0.value) })
        var brgnxShares = 0.0, spxlShares = 0.0
        let weekly = 100.0

        return brgnx.prices.enumerated().compactMap { i, bp in
            guard let sv = spxlByDate[bp.date] else { return nil }
            brgnxShares += weekly / bp.value
            spxlShares += weekly / sv
            return LeveragePoint(
                id: i,
                date: bp.date,
                brgnx: brgnxShares * bp.value,
                spxl: spxlShares * sv
            )
        }
    }

    private var chartData: [LeveragePoint] {
        let source = viewMode == .price ? priceData : dcaData
        return samplePoints(source, maxPoints: 80)
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
                ForEach(LeverageViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .frame(maxWidth: .infinity, alignment: .center)

            Text(viewMode == .price ? "Price: Normalized to 100 at start" : "DCA: $100/week invested")
                .font(.caption).foregroundColor(.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)

            let fullData = viewMode == .price ? priceData : dcaData
            let fullRange = yRange(for: fullData)
            let visibleCount = max(1, Int(animationProgress * Double(chartData.count)))
            let visible = Array(chartData.prefix(visibleCount))

            Chart {
                ForEach(visible) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("BRGNX", point.brgnx),
                        series: .value("Series", "BRGNX")
                    )
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("SPXL", point.spxl),
                        series: .value("Series", "SPXL")
                    )
                    .foregroundStyle(Color.mint)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let str = value.as(String.self) {
                            Text(String(str.suffix(7)))
                                .font(.caption2).foregroundColor(.textMuted)
                        }
                    }
                }
            }
            .chartYScale(domain: fullRange)
            .chartYAxis {
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
            .chartLegend(.hidden)
            .frame(height: 220)

            HStack(spacing: 16) {
                LegendDot(color: .blue, label: "BRGNX (Russell 1000)")
                LegendDot(color: .mint, label: "SPXL (3x leveraged)")
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0)) {
                animationProgress = 1.0
            }
        }
        .onChange(of: viewMode) { _, _ in
            animationProgress = 0
            withAnimation(.easeInOut(duration: 2.0)) {
                animationProgress = 1.0
            }
        }
    }
}

// MARK: - Mode Comparison Chart (Step 7)
// Matches web app: stacked areas (invested purple + cash green) + value line (orange) + target line (cyan dashed)

struct ModeComparisonChart: View {
    private let historicalData: [String: HistoricalData]
    @State private var harvestResult: BacktestResult?
    @State private var accumulateResult: BacktestResult?

    init() {
        self.historicalData = loadHistoricalData()
    }

    var body: some View {
        VStack(spacing: 12) {
            if let harvest = harvestResult, let accumulate = accumulateResult {
                HStack(spacing: 12) {
                    modeChart(result: harvest, title: "Harvest Mode (TQQQ)", color: .mint)
                    modeChart(result: accumulate, title: "Accumulate Mode (TQQQ)", color: .blue)
                }

                HStack(spacing: 12) {
                    legendItem(color: .orange, label: "Value", style: .line)
                    legendItem(color: Color(red: 139/255, green: 92/255, blue: 246/255), label: "Invested", style: .square)
                    legendItem(color: .mint, label: "Cash", style: .square)
                    legendItem(color: .cyan, label: "Target", style: .dashed)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ProgressView("Loading backtest data...")
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
        .task {
            var harvestCfg = BacktestConfig()
            harvestCfg.spxlPct = 0; harvestCfg.vtiPct = 0; harvestCfg.brgnxPct = 0
            harvestCfg.tqqqPct = 1.0; harvestCfg.btcPct = 0; harvestCfg.gldPct = 0; harvestCfg.slvPct = 0
            harvestCfg.targetAPY = 0.52; harvestCfg.accumulate = false
            harvestCfg.inputMax = 350

            var accCfg = BacktestConfig()
            accCfg.spxlPct = 0; accCfg.vtiPct = 0; accCfg.brgnxPct = 0
            accCfg.tqqqPct = 1.0; accCfg.btcPct = 0; accCfg.gldPct = 0; accCfg.slvPct = 0
            accCfg.targetAPY = 0.20; accCfg.accumulate = true

            let hist = historicalData
            harvestResult = await Task.detached { runBacktest(config: harvestCfg, historicalData: hist) }.value
            accumulateResult = await Task.detached { runBacktest(config: accCfg, historicalData: hist) }.value
        }
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
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(color).frame(width: 3, height: 2)
                    }
                }
            }
            Text(label).font(.system(size: 9)).foregroundColor(.textMuted)
        }
    }

    @ViewBuilder
    private func modeChart(result: BacktestResult, title: String, color: Color) -> some View {
        let sampled = sampleBacktestEntries(result.entries, maxPoints: 60)
        let purple = Color(red: 139/255, green: 92/255, blue: 246/255)

        // Compute fixed Y range from full data
        let yMax: Double = {
            var m = 0.0
            for e in result.entries {
                m = max(m, e.totalValue, e.costBasis + e.cash)
            }
            return m * 1.1
        }()

        // Compute expected target for each entry
        let targetAPY = title.contains("Harvest") ? 0.52 : 0.20

        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption).fontWeight(.bold).foregroundColor(color)
                .frame(maxWidth: .infinity, alignment: .center)

            Chart(sampled.indices, id: \.self) { i in
                let entry = sampled[i]
                let expectedTarget = entry.costBasis * (1.0 + targetAPY * Double(i) * 7.0 / 365.0)

                // Invested area (purple) - from bottom
                AreaMark(
                    x: .value("Date", entry.date),
                    y: .value("Invested", entry.costBasis)
                )
                .foregroundStyle(purple.opacity(0.4))
                .interpolationMethod(.catmullRom)

                // Cash area (green) - stacked on top of invested
                AreaMark(
                    x: .value("Date", entry.date),
                    yStart: .value("InvBase", entry.costBasis),
                    yEnd: .value("InvPlusCash", entry.costBasis + entry.cash)
                )
                .foregroundStyle(Color.mint.opacity(0.4))
                .interpolationMethod(.catmullRom)

                // Target line (cyan dashed)
                LineMark(
                    x: .value("Date", entry.date),
                    y: .value("Target", expectedTarget),
                    series: .value("Series", "Target")
                )
                .foregroundStyle(Color.cyan)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .interpolationMethod(.catmullRom)

                // Value line (orange)
                LineMark(
                    x: .value("Date", entry.date),
                    y: .value("Value", entry.equity),
                    series: .value("Series", "Value")
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let str = value.as(String.self) {
                            // Show "Jan '22" style
                            Text(String(str.suffix(5)))
                                .font(.system(size: 7)).foregroundColor(.textMuted)
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

// MARK: - Helpers

private func samplePoints(_ points: [LeveragePoint], maxPoints: Int) -> [LeveragePoint] {
    guard points.count > maxPoints else { return points }
    let step = max(1, points.count / maxPoints)
    return points.enumerated()
        .filter { $0.offset % step == 0 || $0.offset == points.count - 1 }
        .map(\.element)
}

private func sampleBacktestEntries(_ entries: [BacktestResult.BacktestEntry], maxPoints: Int) -> [BacktestResult.BacktestEntry] {
    let step = max(1, entries.count / maxPoints)
    return entries.enumerated()
        .filter { $0.offset % step == 0 || $0.offset == entries.count - 1 }
        .map(\.element)
}
