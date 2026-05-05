import Foundation
import SwiftUI

struct EscapeMintLoadingView: View {
    let message: String
    var progress: Double?
    var detail: String?
    var loadedCount: Int = 0
    var totalCount: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Color.mint)
                        .rotationEffect(.degrees(sin(time * 1.4) * 4))
                        .accessibilityHidden(true)
                    Text("EscapeMint")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                }

                VStack(spacing: 16) {
                    MarketLoadingGraphic(time: time)
                        .frame(width: 420, height: 170)
                        .accessibilityHidden(true)
                    LoadingStatusPanel(
                        message: message,
                        detail: detail,
                        progress: progress,
                        loadedCount: loadedCount,
                        totalCount: totalCount,
                        time: time
                    )
                }
                .frame(maxWidth: 460)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [
                        Color.bg,
                        Color.bgInput.opacity(0.58),
                        Color.bg
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
        }
    }
}

struct EscapeMintLoadingBanner: View {
    let message: String
    var progress: Double?
    var loadedCount: Int = 0
    var totalCount: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 12) {
                MiniMarketPulse(time: time)
                    .frame(width: 64, height: 36)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(message)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.textPrimary)
                        if totalCount > 0 {
                            Text("\(loadedCount)/\(totalCount)")
                                .font(.caption2)
                                .foregroundColor(.textMuted)
                                .monospacedDigit()
                        }
                    }
                    loadingProgress
                }

                Spacer()
                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    .font(.callout)
                    .foregroundColor(.mint)
                    .rotationEffect(.degrees(time * 42))
                    .accessibilityHidden(true)
            }
            .padding(10)
            .background(Color.bgCard)
            .cornerRadius(8)
        }
    }

    @ViewBuilder
    private var loadingProgress: some View {
        if let progress {
            ProgressView(value: progress)
                .tint(.mint)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}

private struct LoadingStatusPanel: View {
    let message: String
    let detail: String?
    let progress: Double?
    let loadedCount: Int
    let totalCount: Int
    let time: TimeInterval

    private let rows = [
        "icloud.funds.scan()",
        "parse(tsv).parallel()",
        "cashflow.normalize()",
        "rebalance.signal.emit()"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.headline)
                        .foregroundColor(.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                    } else if totalCount > 0 {
                        Text("\(loadedCount) of \(totalCount) funds indexed")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                            .monospacedDigit()
                    } else {
                        Text("Preparing secure local cache")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                    }
                }
                Spacer()
                MiniMarketPulse(time: time)
                    .frame(width: 84, height: 42)
                    .accessibilityHidden(true)
            }

            loadingProgress

            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(rowColor(index))
                            .frame(width: 6, height: 6)
                            .opacity(rowOpacity(index))
                        Text(rows[index])
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(18)
        .background(Color.bgCard)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var loadingProgress: some View {
        if let progress {
            ProgressView(value: progress)
                .tint(.mint)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func rowOpacity(_ index: Int) -> Double {
        0.35 + 0.65 * ((sin(time * 2.2 + Double(index) * 0.7) + 1) / 2)
    }

    private func rowColor(_ index: Int) -> Color {
        switch index % 4 {
        case 0: .mint
        case 1: .cyan
        case 2: .orange
        default: .red
        }
    }
}

private struct MarketLoadingGraphic: View {
    let time: TimeInterval

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.cardBorder, lineWidth: 1)
                )

            GeometryReader { proxy in
                let size = proxy.size
                let chartHeight = size.height - 62
                ZStack(alignment: .bottomLeading) {
                    gridLines
                    candleStrip(height: chartHeight)
                        .frame(height: chartHeight, alignment: .bottom)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 36)
                    signalPath(size: size)
                    tickerTape(time: time)
                        .frame(height: 24)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var gridLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { _ in
                Rectangle()
                    .fill(Color.cardBorder.opacity(0.45))
                    .frame(height: 1)
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
    }

    private func candleStrip(height: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<24, id: \.self) { index in
                let phase = time * 1.35 + Double(index) * 0.58
                let bodyHeight = 10 + CGFloat((sin(phase) + 1) * 0.5) * 44
                let wickHeight = min(height, bodyHeight + 18 + CGFloat((cos(phase * 0.7) + 1) * 0.5) * 44)
                let isUp = sin(phase + 0.8) > -0.2
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill((isUp ? Color.mint : Color.red).opacity(0.42))
                        .frame(width: 2, height: wickHeight)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isUp ? Color.mint : Color.red.opacity(0.78))
                        .frame(width: 8, height: bodyHeight)
                }
                .frame(height: height, alignment: .bottom)
            }
        }
    }

    private func signalPath(size: CGSize) -> some View {
        Path { path in
            let width = size.width - 42
            let height = size.height - 54
            let startX: CGFloat = 21
            let startY = size.height - 44
            path.move(to: CGPoint(x: startX, y: startY))
            for step in 0...48 {
                let x = startX + width * CGFloat(step) / 48
                let wave = sin(time * 1.7 + Double(step) * 0.34)
                let trend = CGFloat(step) / 48
                let y = startY - height * (0.2 + trend * 0.48) - CGFloat(wave) * 10
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        .stroke(Color.cyan.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        .shadow(color: Color.cyan.opacity(0.28), radius: 8)
    }

    private func tickerTape(time: TimeInterval) -> some View {
        HStack(spacing: 18) {
            ForEach(["NAV", "DCA", "APY", "BTC", "VTI", "TQQQ"], id: \.self) { symbol in
                HStack(spacing: 4) {
                    Text(symbol)
                        .fontWeight(.semibold)
                    Text(formattedMove(symbol, time: time))
                        .foregroundColor(moveIsPositive(symbol, time: time) ? .mint : .red)
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(Color.bgInput.opacity(0.72))
    }

    private func formattedMove(_ symbol: String, time: TimeInterval) -> String {
        let value = sin(time + Double(symbol.count)) * 1.8
        return String(format: "%+.2f%%", value)
    }

    private func moveIsPositive(_ symbol: String, time: TimeInterval) -> Bool {
        sin(time + Double(symbol.count)) >= 0
    }
}

private struct MiniMarketPulse: View {
    let time: TimeInterval

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<7, id: \.self) { index in
                let height = 9 + CGFloat((sin(time * 2.0 + Double(index) * 0.8) + 1) * 0.5) * 26
                RoundedRectangle(cornerRadius: 2)
                    .fill(index % 3 == 0 ? Color.cyan : Color.mint)
                    .frame(width: 5, height: height)
            }
        }
    }
}
