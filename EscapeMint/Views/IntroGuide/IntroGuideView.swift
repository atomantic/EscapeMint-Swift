import SwiftUI

struct IntroGuideView: View {
    @Binding var isPresented: Bool
    @State private var currentStep = 1
    @AppStorage("escapemint-intro-completed") private var introCompleted = false

    private let totalSteps = introSteps.count

    private var stepData: IntroStepData {
        introSteps[currentStep - 1]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            // Progress dots
            progressIndicator

            Divider().overlay(Color.textMuted.opacity(0.2))

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if stepData.showDisclaimer {
                        disclaimerBanner
                    }

                    Text(stepData.title)
                        .font(.title2).fontWeight(.bold).foregroundColor(.textPrimary)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(stepData.content.enumerated()), id: \.offset) { _, item in
                            contentItem(item)
                        }
                    }

                    chartView
                }
                .padding(20)
                .id(currentStep) // force re-render on step change for animations
            }

            Divider().overlay(Color.textMuted.opacity(0.2))

            // Footer navigation
            footer
        }
        .background(Color.bg)
        .frame(minWidth: 600, idealWidth: 700, minHeight: 500, idealHeight: 650)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "leaf.fill").foregroundColor(.mint)
                    Text("EscapeMint").font(.headline).fontWeight(.bold).foregroundColor(.textPrimary)
                }
                Text("Introduction Guide")
                    .font(.caption).foregroundColor(.textMuted)
            }
            Spacer()
            Text("Step \(currentStep) of \(totalSteps)")
                .font(.caption).foregroundColor(.textSecondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.bgCard.opacity(0.5))
    }

    // MARK: - Progress Indicator

    @ViewBuilder
    private var progressIndicator: some View {
        HStack(spacing: 4) {
            ForEach(1...totalSteps, id: \.self) { step in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentStep = step
                    }
                } label: {
                    Capsule()
                        .fill(step == currentStep ? Color.mint : step < currentStep ? Color.mint.opacity(0.5) : Color.textMuted.opacity(0.3))
                        .frame(width: step == currentStep ? 20 : 8, height: 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.bgCard.opacity(0.3))
    }

    // MARK: - Content Rendering

    @ViewBuilder
    private func contentItem(_ item: IntroContentItem) -> some View {
        switch item {
        case .text(let str):
            Text(str)
                .font(.body).foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

        case .quote(let str):
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: 3)
                Text(str)
                    .font(.callout).italic().foregroundColor(.textMuted)
                    .padding(.leading, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .bullet(let str):
            HStack(alignment: .top, spacing: 8) {
                Text("\u{2022}")
                    .font(.body).foregroundColor(.mint)
                Text(str)
                    .font(.body).foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 16)

        case .crossBullet(let str):
            HStack(alignment: .top, spacing: 8) {
                Text("\u{2717}")
                    .font(.body).foregroundColor(.red)
                Text(str)
                    .font(.body).foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 16)

        case .boldLabel(let label, let color, let text):
            HStack(alignment: .top, spacing: 0) {
                Text(label)
                    .font(.body).fontWeight(.bold)
                    .foregroundColor(labelColor(color))
                Text(" " + text)
                    .font(.body).foregroundColor(.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .warning(let str):
            HStack(alignment: .top, spacing: 8) {
                Text("!")
                    .font(.callout).fontWeight(.bold).foregroundColor(.yellow)
                    .frame(width: 20, height: 20)
                    .background(Color.yellow.opacity(0.2))
                    .cornerRadius(4)
                Text(str)
                    .font(.callout).foregroundColor(.yellow.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.yellow.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.3), lineWidth: 1))
            .cornerRadius(8)

        case .link(let text, let label):
            HStack(spacing: 4) {
                Text(text).font(.body).foregroundColor(.textSecondary)
                Text(label).font(.body).foregroundColor(.blue)
            }
        }
    }

    private func labelColor(_ c: IntroLabelColor) -> Color {
        switch c {
        case .green: return .mint
        case .blue: return .blue
        case .amber: return .yellow
        }
    }

    // MARK: - Chart View

    @ViewBuilder
    private var chartView: some View {
        switch stepData.chartType {
        case .growth:
            MarketGrowthChart()
        case .volatility:
            VolatilityComparisonChart()
        case .traditionalDca:
            TraditionalDCAChart()
        case .buySell:
            BuySellZonesChart()
        case .leverage:
            LeverageComparisonChart()
        case .modes:
            ModeComparisonChart()
        case .none:
            EmptyView()
        }
    }

    // MARK: - Disclaimer Banner

    @ViewBuilder
    private var disclaimerBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("!")
                .font(.title3).fontWeight(.bold).foregroundColor(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Not Investment Advice")
                    .font(.callout).fontWeight(.semibold).foregroundColor(.yellow)
                Text("This is an open-source tool created by an individual investor to track their personal fund strategy. The sample funds (TQQQ, SPXL, BTC) are examples and not financial advice.")
                    .font(.caption).foregroundColor(.yellow.opacity(0.8))
                Text("Do your own research. Choice of platforms, assets, timeline, and risk tolerance is entirely up to you.")
                    .font(.caption).fontWeight(.medium).foregroundColor(.yellow)
            }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.3), lineWidth: 1))
        .cornerRadius(8)
    }

    // MARK: - Footer Navigation

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 0) {
            HStack {
                // Previous
                if currentStep > 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep -= 1
                        }
                    } label: {
                        Text("\u{2190} Previous")
                            .font(.callout).foregroundColor(.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Skip
                Button {
                    introCompleted = true
                    isPresented = false
                } label: {
                    Text("Skip to Backtest")
                        .font(.callout).foregroundColor(.textMuted)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)

                // Next / Launch
                if currentStep < totalSteps {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep += 1
                        }
                    } label: {
                        Text("Next \u{2192}")
                            .font(.callout).fontWeight(.medium)
                    }
                    .buttonStyle(.borderedProminent).tint(.mint)
                } else {
                    Button {
                        introCompleted = true
                        isPresented = false
                    } label: {
                        Text("Launch Backtest \u{2192}")
                            .font(.callout).fontWeight(.medium)
                    }
                    .buttonStyle(.borderedProminent).tint(.mint)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)

            // Footer disclaimer
            Text("Not investment advice. Do your own research.")
                .font(.caption2).foregroundColor(.textMuted)
                .padding(.bottom, 8)
        }
        .background(Color.bgCard.opacity(0.5))
    }
}
