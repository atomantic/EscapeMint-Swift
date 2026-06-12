import SwiftUI
import Charts

private struct EditTarget: Identifiable {
    let id = UUID()
    let entry: FundEntry
    let index: Int
}

struct FundDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let fundId: String
    var autoShowAddEntry: Bool = false
    private var store: FundDataStore { .shared }
    private var cache: ViewCache { .shared }
    @State private var showAddEntry = false
    @State private var showEditFund = false
    @State private var wasDeleted = false
    @State private var editTarget: EditTarget?
    @State private var visibleColumns: Set<String> = []
    @State private var columnOrder: [String] = []
    @State private var showColumnConfig = false
    @State private var showStats = true
    @State private var isRecalculating = false
    @State private var advancedToolsMessage = ""
    @State private var showAdvancedToast = false
    @AppStorage(AppStorageKeys.advancedTools) private var advancedToolsEnabled = false
    @AppStorage(AppStorageKeys.advancedEntryMode) private var advancedEntryMode = false

    private var fund: FundData? { store.fund(byId: fundId) }
    private var summary: FundSummary? { store.summary(byId: fundId) }
    private var dd: Int { fund?.config.dollarDec ?? 2 }
    private var derivPoints: [DerivativesChartPoint]? {
        guard let fund else { return nil }
        return cache.cachedDerivPoints(fundId: fund.id, entryCount: fund.entries.count)
    }
    private var computedRows: [ComputedEntryRow] {
        guard let fund else { return [] }
        return cache.cachedRows(fundId: fund.id, entryCount: fund.entries.count) ?? []
    }

    var body: some View {
        Group {
            if wasDeleted {
                Color.bg.ignoresSafeArea()
            } else if let fund, let summary {
                fundContent(fund, summary: summary)
            } else if store.isLoaded {
                // Fund doesn't exist (was deleted externally)
                Color.bg.ignoresSafeArea()
                    .onAppear { dismiss() }
            } else {
                EscapeMintLoadingBanner(message: "Loading fund\u{2026}")
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color.bg.ignoresSafeArea())
            }
        }
        .navigationTitle(fund.map { "\($0.ticker.uppercased()) (\($0.platform))" } ?? "Fund")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if fund != nil {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showEditFund = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                #endif
            }
        }
        .onAppear {
            if autoShowAddEntry {
                showAddEntry = true
            }
        }
        .sheet(isPresented: $showAddEntry) {
            if let fund {
                if advancedEntryMode {
                    AddEntryView(fundId: fund.id, fundType: fund.config.fund_type ?? .stock, fundConfig: fund.config, existingEntries: fund.entries, recommendation: summary?.isDueForAction == true ? summary?.recommendation : nil) {}
                } else {
                    GuidedAddEntryView(fundId: fund.id) {}
                }
            }
        }
        .sheet(isPresented: $showEditFund) {
            if let fund {
                EditFundView(fund: fund, onSaved: {}, onDeleted: {
                    wasDeleted = true
                    NotificationCenter.default.postSelectDashboard()
                    dismiss()
                })
            }
        }
        .sheet(item: $editTarget) { target in
            EditEntryView(entry: target.entry, entryIndex: target.index, fundId: fundId, fundType: fund?.config.fund_type ?? .stock, fundConfig: fund?.config ?? FundConfig(), existingEntries: fund?.entries ?? []) {}
        }
    }

    @ViewBuilder
    private func fundContent(_ fund: FundData, summary: FundSummary) -> some View {
        let state = summary.state
        let rec = summary.recommendation
        let features = summary.features

        ScrollView {
            VStack(spacing: 12) {
                // Breadcrumb (macOS)
                #if os(macOS)
                HStack(spacing: 4) {
                    Text("Dashboard").font(.caption).foregroundColor(.mint)
                    Text("/").font(.caption).foregroundColor(.textMuted)
                    Text(fund.platform.capitalized).font(.caption).foregroundColor(.mint)
                    Text("/").font(.caption).foregroundColor(.textMuted)
                    Text(fund.ticker.uppercased()).font(.caption).foregroundColor(.textPrimary).fontWeight(.medium)
                    Spacer()
                    Button { showEditFund = true } label: {
                        Label("Edit Fund", systemImage: "gearshape")
                            .font(.callout).fontWeight(.medium)
                            .foregroundColor(.textSecondary)
                    }
                    .buttonStyle(.plain)
                    Button { showAddEntry = true } label: {
                        Label("Take Action", systemImage: "plus.circle.fill")
                            .font(.callout).fontWeight(.medium)
                            .foregroundColor(.mint)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 4)
                #endif

                // Config summary
                configSummary(fund, features: features, state: state)

                // Recommendation (only when fund is due for action per interval)
                if summary.isDueForAction, let rec {
                    recommendationCard(rec)
                }

                // Collapsible Stats section
                DisclosureGroup(isExpanded: $showStats) {
                    VStack(spacing: 12) {
                        #if os(macOS)
                        chartsGridMac(fund: fund, summary: summary)
                        #else
                        stateCard(summary: summary)
                        if fund.entries.count >= 3 || summary.closedMetrics != nil {
                            chartsStackIOS(fund: fund, summary: summary)
                        }
                        #endif
                    }
                } label: {
                    Text("Stats & Charts")
                        .font(.headline).foregroundColor(.textPrimary)
                }
                .tint(.textSecondary)
                .task(id: "\(fund.id)-\(fund.entries.count)-\(store.revision)") {
                    let ec = fund.entries.count
                    let entries = fund.entries
                    let config = fund.config
                    let fid = fund.id
                    // Compute entry rows off main thread
                    if cache.cachedRows(fundId: fid, entryCount: ec) == nil {
                        let rows = await Task.detached(priority: .userInitiated) {
                            computeEntryRows(entries: entries, config: config)
                        }.value
                        guard !Task.isCancelled else { return }
                        cache.cacheRows(rows, fundId: fid, entryCount: ec)
                    }
                    if config.fund_type == .derivatives {
                        if cache.cachedDerivPoints(fundId: fid, entryCount: ec) == nil {
                            let pts = await Task.detached(priority: .userInitiated) {
                                computeDerivativesChartData(entries: entries, config: config)
                            }.value
                            guard !Task.isCancelled else { return }
                            cache.cacheDerivPoints(pts, fundId: fid, entryCount: ec)
                        }
                    } else {
                        cache.cacheDerivPoints(nil, fundId: fid, entryCount: ec)
                    }
                }

                // Entries table
                entriesTable(fund)
            }
            .padding()
            #if os(iOS)
            .padding(.bottom, 80)
            #endif
        }
        .background(Color.bg.ignoresSafeArea())
        #if os(iOS)
        .overlay(alignment: .bottom) {
            Button { showAddEntry = true } label: {
                Label("Take Action", systemImage: "plus.circle.fill")
                    .font(.callout).fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.mint)
                    .cornerRadius(20)
            }
            .padding(.bottom, 16)
        }
        #endif
    }

    // MARK: - Config Summary

    @ViewBuilder
    private func configSummary(_ fund: FundData, features: FundTypeFeatures, state: FundState) -> some View {
        let config = fund.config
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(features.label)
                    .fontWeight(.medium)
                if let cat = config.category, let catInfo = categoryConfig[cat] {
                    Text(catInfo.shortLabel)
                        .tagBadge(background: Color.forCategory(cat).opacity(0.2))
                }
                if config.status == .closed {
                    Text("Closed")
                        .tagBadge(background: .bgInput)
                }
                if config.margin_enabled == true {
                    Text("Margin")
                        .foregroundColor(.blue)
                        .tagBadge(background: Color.blue.opacity(0.2))
                }
                if let acc = config.accumulate {
                    Text(acc ? "Accumulate" : "Harvest")
                        .foregroundColor(acc ? .mint : .orange)
                }
                Spacer()
                if config.status == .closed, let lastCash = fund.entries.last?.cash {
                    Text("Cash: \(formatCurrency(lastCash, decimals: config.dollarDec))")
                        .fontWeight(.medium)
                }
            }
            if !isCashFund(config.fund_type) {
                HStack(spacing: 8) {
                    Text("\(formatPercent(config.target_apy ?? 0)) target")
                    Text("\(config.interval_days ?? 7)d interval")
                    if let min = config.input_min_usd, let mid = config.input_mid_usd, let max = config.input_max_usd {
                        Text("DCA $\(Int(min))/$\(Int(mid))/$\(Int(max))")
                    }
                    Spacer()
                    if state.cashAvailableUsd > 0 {
                        // For manage_cash=false funds this balance comes from the platform
                        // cash fund, not the fund itself — label it accordingly.
                        Text("\(config.managesOwnCash ? "Cash" : "Platform cash"): \(formatCurrency(state.cashAvailableUsd, decimals: config.dollarDec))")
                    }
                    if config.margin_enabled == true,
                       let marginAvail = fund.entries.last?.margin_available, marginAvail > 0 {
                        Text("Margin: \(formatCurrency(marginAvail, decimals: config.dollarDec))")
                            .foregroundColor(.blue)
                    }
                }
            }
        }
        .font(.caption)
        .foregroundColor(.textMuted)
        .padding(8)
        .background(Color.bgCard)
        .cornerRadius(8)
    }

    // MARK: - Recommendation Card

    @ViewBuilder
    private func recommendationCard(_ rec: Recommendation) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(rec.action == .HOLD ? "HOLD" : "\(rec.action.rawValue) \(formatCurrency(rec.amount, decimals: dd))")
                    .font(.title2).fontWeight(.bold)
                    .foregroundColor(Color.forAction(rec.action))
                Text(rec.reasoning)
                    .font(.caption).foregroundColor(.textSecondary)
                Text("Based on your configured rules — not financial advice.")
                    .font(.caption2).foregroundColor(.textMuted)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.bgCard)
        .overlay(
            Rectangle()
                .fill(Color.forAction(rec.action))
                .frame(width: 4),
            alignment: .leading
        )
        .cornerRadius(12)
    }

    // MARK: - Stats Grid

    @ViewBuilder
    private func stateCard(summary: FundSummary) -> some View {
        if let cm = summary.closedMetrics {
            ClosedFundStateCard(closedMetrics: cm, dollarDecimals: dd)
        } else {
            ActiveFundStateCard(state: summary.state, summary: summary, dollarDecimals: dd)
        }
    }

    // MARK: - Charts

    @ViewBuilder
    private func derivativesChartContent() -> some View {
        if let pts = derivPoints, let fund {
            let cb = fund.config.chart_bounds
            let d = dd
            DerivativesPLChart(points: pts, fundId: fund.id, bounds: cb?["pnl"], dollarDecimals: d)
            DerivativesAPYChart(points: pts, fundId: fund.id, bounds: cb?["apy"])
            DerivativesValueChart(points: pts, dollarDecimals: d)
            DerivativesPriceChart(points: pts, fundId: fund.id, bounds: cb?["derivativesPrice"], dollarDecimals: d)
            DerivativesMarginChart(points: pts, dollarDecimals: d)
            DerivativesCapturedProfitChart(points: pts, dollarDecimals: d)
        } else {
            EMChartLoadingPlaceholder()
        }
    }

    @ViewBuilder
    private func standardChartContent(fund: FundData) -> some View {
        ValueChartView(entries: fund.entries, config: fund.config, fundId: fund.id)
        PLChartView(entries: fund.entries, config: fund.config, fundId: fund.id)
        APYChartView(entries: fund.entries, config: fund.config, fundId: fund.id)
        if fund.entries.contains(where: { ($0.dividend ?? 0) > 0 || ($0.cash_interest ?? 0) > 0 || ($0.action == .SELL && ($0.amount ?? 0) > 0) }) {
            CapturedProfitChartView(entries: fund.entries, config: fund.config, fundId: fund.id)
        }
    }

    // MARK: - Charts (macOS - 2 columns)

    @ViewBuilder
    private func chartsGridMac(fund: FundData, summary: FundSummary) -> some View {
        // First row: 3 columns (Current State + P&L + APY)
        LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 12) {
            stateCard(summary: summary)
            if fund.config.fund_type == .derivatives {
                if let pts = derivPoints {
                    let cb = fund.config.chart_bounds
                    let d = dd
                    DerivativesPLChart(points: pts, fundId: fund.id, bounds: cb?["pnl"], dollarDecimals: d)
                    DerivativesAPYChart(points: pts, fundId: fund.id, bounds: cb?["apy"])
                }
            } else {
                PLChartView(entries: fund.entries, config: fund.config, fundId: fund.id)
                APYChartView(entries: fund.entries, config: fund.config, fundId: fund.id)
            }
        }
        // Remaining rows: 2 columns
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
            if fund.config.fund_type == .derivatives {
                if let pts = derivPoints {
                    let cb = fund.config.chart_bounds
                    let d = dd
                    DerivativesValueChart(points: pts, dollarDecimals: d)
                    DerivativesPriceChart(points: pts, fundId: fund.id, bounds: cb?["derivativesPrice"], dollarDecimals: d)
                    DerivativesMarginChart(points: pts, dollarDecimals: d)
                    DerivativesCapturedProfitChart(points: pts, dollarDecimals: d)
                }
            } else {
                ValueChartView(entries: fund.entries, config: fund.config, fundId: fund.id)
                if fund.entries.contains(where: { ($0.dividend ?? 0) > 0 || ($0.cash_interest ?? 0) > 0 || ($0.action == .SELL && ($0.amount ?? 0) > 0) }) {
                    CapturedProfitChartView(entries: fund.entries, config: fund.config, fundId: fund.id)
                }
            }
        }
    }

    // MARK: - Charts (iOS - stacked)

    @ViewBuilder
    private func chartsStackIOS(fund: FundData, summary: FundSummary) -> some View {
        if fund.config.fund_type == .derivatives {
            derivativesChartContent()
        } else {
            standardChartContent(fund: fund)
        }
    }

    // MARK: - Advanced Tools

    @ViewBuilder
    private func recalcPricesButton(_ fund: FundData) -> some View {
        Button {
            guard !isRecalculating else { return }
            isRecalculating = true
            Task {
                let (_, msg) = await store.recalculatePrices(fundId: fund.id)
                advancedToolsMessage = msg
                isRecalculating = false
                showAdvancedToast = true
            }
        } label: {
            Label(isRecalculating ? "..." : "Recalc Prices", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2).fontWeight(.medium)
                .foregroundColor(.mint)
        }
        .disabled(isRecalculating)
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
    }

    @ViewBuilder
    private func advancedToolsButtons(_ fund: FundData) -> some View {
        Button {
            guard !isRecalculating else { return }
            isRecalculating = true
            Task {
                let (_, msg) = await store.recalculateFund(fundId: fund.id)
                advancedToolsMessage = msg
                isRecalculating = false
                showAdvancedToast = true
            }
        } label: {
            Text(isRecalculating ? "..." : "Recalculate")
                .font(.caption2).fontWeight(.medium)
                .foregroundColor(.white)
                .actionBadge(background: Color.secondary.opacity(0.7))
        }
        .disabled(isRecalculating)
        #if os(macOS)
        .buttonStyle(.plain)
        #endif

        Menu {
            ForEach(InterpolatableColumn.allCases, id: \.rawValue) { column in
                Button(column.label) {
                    guard !isRecalculating else { return }
                    isRecalculating = true
                    Task {
                        let (_, msg) = await store.interpolateFundColumn(fundId: fund.id, column: column)
                        advancedToolsMessage = msg
                        isRecalculating = false
                        showAdvancedToast = true
                    }
                }
            }
        } label: {
            Text("Interpolate")
                .font(.caption2).fontWeight(.medium)
                .foregroundColor(.white)
                .actionBadge(background: Color.secondary.opacity(0.7))
        }
        .disabled(isRecalculating)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
    }

    // MARK: - Entries Table

    private func availableColumns(for fundType: FundType?) -> [(id: String, label: String)] {
        let ft = fundType ?? .stock
        return allEntryColumns
            .filter { !$0.excludeFrom.contains(ft) }
            .map { (id: $0.id, label: $0.label) }
    }

    private func defaultVisibleColumns(for fundType: FundType?) -> Set<String> {
        let ft = fundType ?? .stock
        var cols = Set(allEntryColumns
            .filter { $0.defaultVisible && !$0.excludeFrom.contains(ft) }
            .map(\.id))
        if ft == .derivatives {
            cols.formUnion(["contracts", "price", "fee", "position", "entry_price", "deriv_cash", "margin_locked", "liquidation_price", "deriv_equity", "unrealized_pnl"])
        } else if ft == .cash {
            cols.formUnion(["cash_interest", "sum_cash_int"])
        }
        return cols
    }

    /// Prefix for the per-fund column-visibility/order UserDefaults keys.
    private static let columnPrefsPrefix = "columns_"

    private func columnPrefsKey(_ suffix: String) -> String {
        "\(Self.columnPrefsPrefix)\(fundId)_\(suffix)"
    }

    private func saveColumnPrefs() {
        let defaults = UserDefaults.standard
        defaults.set(Array(visibleColumns), forKey: columnPrefsKey("visible"))
        defaults.set(columnOrder, forKey: columnPrefsKey("order"))
    }

    private func initVisibleColumnsIfNeeded(for fund: FundData) {
        if visibleColumns.isEmpty {
            let defaults = UserDefaults.standard
            if let saved = defaults.stringArray(forKey: columnPrefsKey("visible")) {
                visibleColumns = Set(saved)
            } else {
                visibleColumns = defaultVisibleColumns(for: fund.config.fund_type)
            }
            if let savedOrder = defaults.stringArray(forKey: columnPrefsKey("order")) {
                columnOrder = savedOrder
            } else {
                columnOrder = availableColumns(for: fund.config.fund_type).map(\.id)
            }
        }
    }

    /// Columns in user-defined order, filtered to visible + available
    private func orderedVisibleColumns(for fundType: FundType?) -> [(id: String, label: String)] {
        let available = availableColumns(for: fundType)
        let availableMap = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0.label) })
        // Start with ordered columns that are visible and available
        var result: [(id: String, label: String)] = columnOrder.compactMap { id in
            guard visibleColumns.contains(id), let label = availableMap[id] else { return nil }
            return (id: id, label: label)
        }
        // Append any visible columns not yet in the order
        let orderedSet = Set(result.map(\.id))
        for col in available where visibleColumns.contains(col.id) && !orderedSet.contains(col.id) {
            result.append(col)
        }
        return result
    }

    @ViewBuilder
    private func entriesTable(_ fund: FundData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Entries (\(fund.entries.count))")
                    .font(.headline).foregroundColor(.textPrimary)
                Spacer()
                if getFeatures(fund.config.fund_type).supportsShares && fund.entries.contains(where: { ($0.shares ?? 0) != 0 }) {
                    recalcPricesButton(fund)
                }
                if advancedToolsEnabled {
                    advancedToolsButtons(fund)
                }
                #if os(macOS)
                Button {
                    showColumnConfig.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.callout).foregroundColor(.mint)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showColumnConfig) {
                    columnConfigPopover(fund)
                }
                #else
                Button {
                    showColumnConfig = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.callout).foregroundColor(.mint)
                }
                .sheet(isPresented: $showColumnConfig) {
                    columnConfigSheet(fund)
                }
                #endif
            }

            entriesScrollTable(fund)
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
        .onAppear { initVisibleColumnsIfNeeded(for: fund) }
        .toast(isPresented: $showAdvancedToast, message: advancedToolsMessage)
    }

    /// All available columns in user-defined order (for the config UI)
    private func orderedAllColumns(for fundType: FundType?) -> [(id: String, label: String)] {
        let available = availableColumns(for: fundType)
        let availableMap = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0.label) })
        var result: [(id: String, label: String)] = columnOrder.compactMap { id in
            guard let label = availableMap[id] else { return nil }
            return (id: id, label: label)
        }
        let orderedSet = Set(result.map(\.id))
        for col in available where !orderedSet.contains(col.id) {
            result.append(col)
        }
        return result
    }

    private func toggleColumn(_ id: String, on: Bool) {
        if on { visibleColumns.insert(id) }
        else { visibleColumns.remove(id) }
        saveColumnPrefs()
    }

    private func moveColumns(from source: IndexSet, to destination: Int, fundType: FundType?) {
        var ordered = orderedAllColumns(for: fundType).map(\.id)
        ordered.move(fromOffsets: source, toOffset: destination)
        columnOrder = ordered
        saveColumnPrefs()
    }

    @ViewBuilder
    private func columnRow(_ col: (id: String, label: String)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.textMuted)
                .font(.caption)
            Toggle(col.label, isOn: Binding(
                get: { visibleColumns.contains(col.id) },
                set: { toggleColumn(col.id, on: $0) }
            ))
            #if os(macOS)
            .toggleStyle(.checkbox)
            .font(.caption)
            #endif
        }
    }

    #if os(macOS)
    @ViewBuilder
    private func columnConfigPopover(_ fund: FundData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Columns (drag to reorder)")
                .font(.caption).fontWeight(.semibold).foregroundColor(.textMuted)
                .padding(.bottom, 4)
            List {
                ForEach(orderedAllColumns(for: fund.config.fund_type), id: \.id) { col in
                    columnRow(col)
                }
                .onMove { source, dest in
                    moveColumns(from: source, to: dest, fundType: fund.config.fund_type)
                }
            }
            .listStyle(.plain)
        }
        .padding(12)
        .frame(minWidth: 220, minHeight: 300, maxHeight: 500)
    }
    #endif

    @ViewBuilder
    private func columnConfigSheet(_ fund: FundData) -> some View {
        NavigationStack {
            List {
                ForEach(orderedAllColumns(for: fund.config.fund_type), id: \.id) { col in
                    columnRow(col)
                }
                .onMove { source, dest in
                    moveColumns(from: source, to: dest, fundType: fund.config.fund_type)
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("Columns")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showColumnConfig = false }
                }
            }
        }
    }

    private func columnWidth(_ id: String) -> CGFloat {
        switch id {
        case "date": return 85
        case "action": return 60
        case "notes": return 120
        case "realized_apy": return 90
        case "liquid_apy": return 80
        case "liquid_pnl": return 85
        case "sum_shares": return 80
        case "sum_extracted", "sum_dividends": return 90
        case "margin_available", "margin_borrowed": return 95
        default: return 80
        }
    }

    private func columnAlignment(_ id: String) -> Alignment {
        switch id {
        case "date", "action", "notes": return .leading
        default: return .trailing
        }
    }

    @ViewBuilder
    private func entriesScrollTable(_ fund: FundData) -> some View {
        let cols = orderedVisibleColumns(for: fund.config.fund_type)
        let contentWidth = cols.reduce(CGFloat(0)) { $0 + columnWidth($1.id) } + CGFloat(cols.count - 1) * 6 + 30

        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 6) {
                    ForEach(cols, id: \.id) { col in
                        Text(col.label)
                            .frame(width: columnWidth(col.id), alignment: columnAlignment(col.id))
                    }
                    Text("").frame(width: 30) // Edit column
                }
                .font(.caption2).fontWeight(.semibold)
                .foregroundColor(.textMuted)
                .padding(.vertical, 4)

                Divider().background(Color.bgInput)

                let count = fund.entries.count

                // Use entry.id (computed composite of date + value + action + amount + shares +
                // cash) for ForEach identity. Stable across reloads because it's derived from
                // durable content fields. Offset would NOT be stable here: since the array is
                // reversed, appending a new entry shifts every existing row's offset and causes
                // SwiftUI to rebuild the entire visible list.
                ForEach(Array(fund.entries.reversed().enumerated()), id: \.element.id) { reverseIdx, entry in
                    let actualIndex = count - 1 - reverseIdx
                    let computed = actualIndex < computedRows.count ? computedRows[actualIndex] : nil
                    entryRow(entry, entryIndex: actualIndex, columns: cols, config: fund.config, isEven: reverseIdx.isMultiple(of: 2), computed: computed)
                }
            }
            .frame(minWidth: contentWidth)
        }
        .scrollIndicators(.visible)
    }

    private static let dash = Text("-").foregroundColor(.textMuted)

    @ViewBuilder
    private func entryCell(_ entry: FundEntry, columnId: String, computed: ComputedEntryRow?) -> some View {
        let d = dd
        switch columnId {
        case "date":
            Text(entry.date)
        case "action":
            if computed?.isClosingEntry == true {
                Text("Close").italic().foregroundColor(.textMuted)
            } else {
                Text(entry.action?.rawValue ?? "HOLD")
                    .foregroundColor(Color.forAction(entry.action))
            }
        case "value":
            Text(formatCurrency(entry.value, decimals: d))
        case "amount":
            if let amt = entry.amount { Text(formatCurrency(amt, decimals: d)).foregroundColor(.textSecondary) }
            else { Self.dash }
        case "extracted":
            if let c = computed, c.extracted > 0 {
                Text(formatCurrency(c.extracted, decimals: d)).foregroundColor(.mint)
            } else { Self.dash }
        case "realized":
            if let c = computed {
                Text(formatCurrency(c.realized, decimals: d)).foregroundColor(c.realized >= 0 ? .mint : .red)
            } else { Self.dash }
        case "liquid_pnl":
            if let c = computed {
                Text(formatCurrency(c.liquidPnl, decimals: d)).foregroundColor(c.liquidPnl >= 0 ? .mint : .red)
            } else { Self.dash }
        case "realized_apy":
            if let c = computed {
                Text(formatPercentSigned(c.realizedApy)).foregroundColor(c.realizedApy >= 0 ? .mint : .red)
            } else { Self.dash }
        case "liquid_apy":
            if let c = computed {
                Text(formatPercentSigned(c.liquidApy)).foregroundColor(c.liquidApy >= 0 ? .mint : .red)
            } else { Self.dash }
        case "shares":
            if let s = entry.shares { Text(String(format: "%.4f", s)).foregroundColor(.textSecondary) }
            else { Self.dash }
        case "price":
            if let p = entry.price { Text(formatCurrency(p, decimals: d)).foregroundColor(.textSecondary) }
            else { Self.dash }
        case "dividend":
            if let div = entry.dividend { Text(formatCurrency(div, decimals: d)).foregroundColor(.mint) }
            else { Self.dash }
        case "expense":
            if let e = entry.expense { Text(formatCurrency(e, decimals: d)).foregroundColor(.red) }
            else { Self.dash }
        case "cash_interest":
            if let ci = entry.cash_interest { Text(formatCurrency(ci, decimals: d)).foregroundColor(.mint) }
            else { Self.dash }
        case "fund_size":
            if computed?.isClosingEntry == true {
                Text("closed").italic().foregroundColor(.textMuted)
            } else if let fs = entry.fund_size {
                Text(formatCurrency(fs, decimals: d)).foregroundColor(.textSecondary)
            } else { Self.dash }
        case "cash":
            if let c = entry.cash { Text(formatCurrency(c, decimals: d)).foregroundColor(.textSecondary) }
            else { Self.dash }
        case "margin_available":
            if let ma = entry.margin_available { Text(formatCurrency(ma, decimals: d)).foregroundColor(.textSecondary) }
            else { Self.dash }
        case "margin_borrowed":
            if let mb = entry.margin_borrowed { Text(formatCurrency(mb, decimals: d)).foregroundColor(.orange) }
            else { Self.dash }
        case "notes":
            if let n = entry.notes, !n.isEmpty { Text(n).foregroundColor(.textMuted).lineLimit(3) }
            else { Self.dash }
        case "contracts":
            if let c = entry.contracts { Text(String(format: "%.2f", c)).foregroundColor(.textSecondary) }
            else { Self.dash }
        case "entry_price":
            if let ep = entry.entry_price { Text(formatCurrency(ep, decimals: d)).foregroundColor(.textSecondary) }
            else { Self.dash }
        case "fee":
            if let f = entry.fee { Text(formatCurrency(f, decimals: d)).foregroundColor(.red) }
            else { Self.dash }
        case "margin_locked":
            if let ml = entry.margin_locked { Text(formatCurrency(ml, decimals: d)).foregroundColor(.orange) }
            else { Self.dash }
        case "liquidation_price":
            if let lp = entry.liquidation_price { Text(formatCurrency(lp, decimals: d)).foregroundColor(.textSecondary) }
            else { Self.dash }
        case "unrealized_pnl":
            if let up = entry.unrealized_pnl { Text(formatCurrency(up, decimals: d)).foregroundColor(up >= 0 ? .mint : .red) }
            else { Self.dash }
        case "position":
            if let c = computed { Text(String(format: "%.0f", c.sumShares)).foregroundColor(.textSecondary) }
            else { Self.dash }
        case "deriv_cash":
            if let cash = entry.cash { Text(formatCurrency(cash, decimals: d)).foregroundColor(.textSecondary) }
            else { Self.dash }
        case "deriv_equity":
            if let cash = entry.cash, let c = computed {
                let equity = cash + c.unrealized
                Text(formatCurrency(equity, decimals: d)).foregroundColor(.textSecondary)
            } else { Self.dash }
        case "invested":
            if let c = computed {
                Text(formatCurrency(c.invested, decimals: d)).foregroundColor(.textSecondary)
            } else { Self.dash }
        case "unrealized":
            if let c = computed {
                Text(formatCurrency(c.unrealized, decimals: d)).foregroundColor(c.unrealized >= 0 ? .mint : .red)
            } else { Self.dash }
        case "sum_shares":
            if let c = computed, c.sumShares != 0 {
                Text(String(format: "%.1f", c.sumShares)).foregroundColor(.textSecondary)
            } else { Self.dash }
        case "sum_expense":
            if let c = computed, c.sumExpenses > 0 {
                Text(formatCurrency(c.sumExpenses, decimals: d)).foregroundColor(.red)
            } else { Self.dash }
        case "sum_extracted":
            if let c = computed, c.sumExtracted > 0 {
                Text(formatCurrency(c.sumExtracted, decimals: d)).foregroundColor(.mint)
            } else { Self.dash }
        case "sum_cash_int":
            if let c = computed, c.sumCashInterest > 0 {
                Text(formatCurrency(c.sumCashInterest, decimals: d)).foregroundColor(.mint)
            } else { Self.dash }
        case "sum_dividends":
            if let c = computed, c.sumDividends > 0 {
                Text(formatCurrency(c.sumDividends, decimals: d)).foregroundColor(.mint)
            } else { Self.dash }
        default:
            Self.dash
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: FundEntry, entryIndex: Int, columns: [(id: String, label: String)], config: FundConfig, isEven: Bool, computed: ComputedEntryRow?) -> some View {
        HStack(spacing: 6) {
            ForEach(columns, id: \.id) { col in
                entryCell(entry, columnId: col.id, computed: computed)
                    .frame(width: columnWidth(col.id), alignment: columnAlignment(col.id))
            }
            Button {
                editTarget = EditTarget(entry: entry, index: entryIndex)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 30)
        }
        .font(.caption)
        .foregroundColor(.textPrimary)
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(isEven ? Color.clear : Color.textPrimary.opacity(0.04))
        .cornerRadius(4)
        #if os(iOS)
        .contentShape(Rectangle())
        .onTapGesture {
            editTarget = EditTarget(entry: entry, index: entryIndex)
        }
        .accessibilityAddTraits(.isButton)
        #endif
    }

}

#if DEBUG
#Preview("FundDetail — Stock") {
    PreviewData.seedStore()
    return NavigationStack { FundDetailView(fundId: PreviewData.stockFund.id) }
}

#Preview("FundDetail — Closed (Dark)") {
    PreviewData.seedStore()
    return NavigationStack { FundDetailView(fundId: PreviewData.closedFund.id) }
        .preferredColorScheme(.dark)
}
#endif
