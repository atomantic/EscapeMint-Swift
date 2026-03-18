import SwiftUI

struct BacktestConfigPanel: View {
    @Binding var config: BacktestConfig
    @Binding var selectedPreset: BacktestPreset
    let onConfigChanged: () -> Void
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var isWide: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 16) {
                allocationColumn
                Divider().frame(height: 180)
                strategyColumn
                Divider().frame(height: 180)
                dcaTiersColumn
                Divider().frame(height: 180)
                fundModeColumn
            }
            .padding(12)
            #else
            if isWide {
                // iPad: 2x2 grid layout
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 12) {
                        allocationColumn
                        Divider()
                        strategyColumn
                    }
                    Divider()
                    VStack(spacing: 12) {
                        dcaTiersColumn
                        Divider()
                        fundModeColumn
                    }
                }
                .padding(12)
            } else {
                VStack(spacing: 12) {
                    allocationColumn
                    Divider()
                    strategyColumn
                    Divider()
                    dcaTiersColumn
                    Divider()
                    fundModeColumn
                }
                .padding(12)
            }
            #endif
        }
        .background(Color.bgCard)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.textMuted.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Allocation Column

    @ViewBuilder
    private var allocationColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Allocation").font(.caption).fontWeight(.medium).foregroundColor(.textMuted)

            // Allocation bar
            allocationBar
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Asset allocation bar showing \(allocationBarSegments.map { "\($0.label) \(Int($0.pct * 100))%" }.joined(separator: ", "))")

            // Sliders
            allocationSlider("SPXL", value: $config.spxlPct, color: .assetSPXL)
            allocationSlider("VTI", value: $config.vtiPct, color: .assetVTI)
            allocationSlider("BRGNX", value: $config.brgnxPct, color: .assetBRGNX)
            allocationSlider("TQQQ", value: $config.tqqqPct, color: .assetTQQQ)
            allocationSlider("BTC", value: $config.btcPct, color: .assetBTC)
            allocationSlider("GLD", value: $config.gldPct, color: .assetGLD)
            allocationSlider("SLV", value: $config.slvPct, color: .assetSLV)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("allocation-section")
    }

    @ViewBuilder
    private var allocationBar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(allocationBarSegments, id: \.label) { segment in
                    let width = geo.size.width * segment.pct
                    if width > 0 {
                        ZStack {
                            Rectangle().fill(segment.color)
                            if segment.pct >= 0.20 {
                                Text("\(segment.label) \(Int(segment.pct * 100))%")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                            } else if segment.pct >= 0.10 {
                                Text("\(Int(segment.pct * 100))%")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(width: width)
                    }
                }
            }
        }
        .frame(height: 20)
        .cornerRadius(4)
    }

    private var allocationBarSegments: [(label: String, pct: Double, color: Color)] {
        [
            ("SPXL", config.spxlPct, .assetSPXL),
            ("VTI", config.vtiPct, .assetVTI),
            ("BRGNX", config.brgnxPct, .assetBRGNX),
            ("TQQQ", config.tqqqPct, .assetTQQQ),
            ("BTC", config.btcPct, .assetBTC),
            ("GLD", config.gldPct, .assetGLD),
            ("SLV", config.slvPct, .assetSLV),
        ].filter { $0.pct > 0 }
    }

    private func allocationSlider(_ label: String, value: Binding<Double>, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 10)).foregroundColor(.textSecondary)
                .frame(width: 42, alignment: .leading)
            CompactSlider(value: value, range: 0...1, step: 0.05, tint: color) {
                onConfigChanged()
            }
            .accessibilityLabel("\(label) allocation")
            .accessibilityValue("\(Int(value.wrappedValue * 100)) percent")
            .accessibilityIdentifier("slider-\(label.lowercased())")
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.textMuted)
                .frame(width: 28, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Strategy Column

    @ViewBuilder
    private var strategyColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Strategy").font(.caption).fontWeight(.medium).foregroundColor(.textMuted)

            styledSlider("Initial Cash", value: $config.initialCash,
                         range: 1000...100000, step: 1000,
                         format: { formatCurrency($0) })
            styledSlider("Target APY", value: $config.targetAPY,
                         range: 0...1, step: 0.01,
                         format: { "\(Int($0 * 100))%" })
            styledSlider("Min Profit", value: $config.minProfitUSD,
                         range: 0...5000, step: 50,
                         format: { formatCurrency($0) })
            styledSlider("Cash APY", value: $config.cashAPY,
                         range: 0...0.10, step: 0.005,
                         format: { String(format: "%.1f%%", $0 * 100) })
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - DCA Tiers Column

    @ViewBuilder
    private var dcaTiersColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DCA Tiers").font(.caption).fontWeight(.medium).foregroundColor(.textMuted)

            styledSlider("Min (\u{2265} target)", value: $config.inputMin,
                         range: 0...1000, step: 10,
                         format: { formatCurrency($0) })
            styledSlider("Mid (< target)", value: $config.inputMid,
                         range: 0...1000, step: 10,
                         format: { formatCurrency($0) })
            styledSlider("Max (\u{2264} \(Int(config.maxAtPct * 100))%)", value: $config.inputMax,
                         range: 0...1000, step: 10,
                         format: { formatCurrency($0) })

            let thresholdBinding = Binding<Double>(
                get: { abs(config.maxAtPct) * 100 },
                set: { config.maxAtPct = -($0 / 100) }
            )
            styledSlider("Threshold", value: thresholdBinding,
                         range: 10...50, step: 5,
                         format: { "-\(Int($0))%" })
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Fund Mode Column

    @ViewBuilder
    private var fundModeColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fund Mode").font(.caption).fontWeight(.medium).foregroundColor(.textMuted)

            // Accumulate / Harvest toggle
            HStack(spacing: 2) {
                Button {
                    config.accumulate = true
                    onConfigChanged()
                } label: {
                    Text("Accumulate")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(config.accumulate ? Color.blue : Color.bgInput)
                        .foregroundColor(config.accumulate ? .white : .textMuted)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Accumulate mode")
                .accessibilityAddTraits(config.accumulate ? .isSelected : [])
                .accessibilityIdentifier("btn-accumulate")

                Button {
                    config.accumulate = false
                    onConfigChanged()
                } label: {
                    Text("Harvest")
                        .font(.system(size: 10, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(!config.accumulate ? Color.orange : Color.bgInput)
                        .foregroundColor(!config.accumulate ? .white : .textMuted)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Harvest mode")
                .accessibilityAddTraits(!config.accumulate ? .isSelected : [])
                .accessibilityIdentifier("btn-harvest")
            }

            Text(config.accumulate
                 ? "Sell min DCA amount when over target + min profit."
                 : "Close entire position to cash when over target + min profit.")
                .font(.system(size: 9))
                .foregroundColor(.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            // Re-invest toggle
            HStack(spacing: 4) {
                Button {
                    config.reinvest.toggle()
                    onConfigChanged()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: config.reinvest ? "checkmark.square.fill" : "square")
                            .font(.system(size: 10))
                            .foregroundColor(config.reinvest ? .blue : .textMuted)
                        Text("Re-invest proceeds")
                            .font(.system(size: 9))
                            .foregroundColor(.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("btn-reinvest")
            }

            // Presets
            Text("Presets").font(.system(size: 9)).foregroundColor(.textMuted)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(BacktestPreset.allCases) { preset in
                    Button {
                        selectedPreset = preset
                        var presetConfig = preset.config(accumulate: config.accumulate)
                        presetConfig.reinvest = config.reinvest
                        config = presetConfig
                        onConfigChanged()
                    } label: {
                        Text(preset.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(selectedPreset == preset
                                        ? (config.accumulate ? Color.blue : Color.orange)
                                        : Color.bgInput)
                            .foregroundColor(selectedPreset == preset ? .white : .textSecondary)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preset \(preset.rawValue)")
                    .accessibilityAddTraits(selectedPreset == preset ? .isSelected : [])
                    .accessibilityIdentifier("preset-\(preset.rawValue.lowercased())")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fund-mode-section")
    }

    // MARK: - Styled Slider Helper

    private func styledSlider(_ label: String, value: Binding<Double>,
                              range: ClosedRange<Double>, step: Double,
                              format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10)).foregroundColor(.textMuted)
                #if os(macOS)
                .frame(width: 85, alignment: .leading)
                #else
                .frame(width: 70, alignment: .leading)
                #endif
                .lineLimit(1)
            CompactSlider(value: value, range: range, step: step, tint: .blue) {
                onConfigChanged()
            }
            .accessibilityLabel(label)
            .accessibilityValue(format(value.wrappedValue))
            .accessibilityIdentifier("slider-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
            Text(format(value.wrappedValue))
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.textSecondary)
                .frame(width: 60, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Compact Slider (no macOS tick marks)

private struct CompactSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    let onDragEnd: () -> Void

    init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, tint: Color, onDragEnd: @escaping () -> Void) {
        self._value = value
        self.range = range
        self.step = step
        self.tint = tint
        self.onDragEnd = onDragEnd
    }

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let frac = span > 0 ? (value - range.lowerBound) / span : 0
            let trackH: CGFloat = 4
            let thumbD: CGFloat = 14

            ZStack(alignment: .leading) {
                // Track background
                Capsule().fill(Color.textMuted.opacity(0.15))
                    .frame(height: trackH)
                // Filled track
                Capsule().fill(tint)
                    .frame(width: max(0, geo.size.width * frac), height: trackH)
                // Thumb
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .frame(width: thumbD, height: thumbD)
                    .offset(x: max(0, min(geo.size.width - thumbD, geo.size.width * frac - thumbD / 2)))
            }
            .frame(height: thumbD)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let pct = max(0, min(1, drag.location.x / geo.size.width))
                        let raw = range.lowerBound + pct * span
                        let stepped = step > 0 ? (raw / step).rounded() * step : raw
                        value = max(range.lowerBound, min(range.upperBound, stepped))
                    }
                    .onEnded { _ in onDragEnd() }
            )
        }
        .frame(height: 14)
    }
}
