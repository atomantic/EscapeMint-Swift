import AppIntents
import Foundation
import SwiftUI

// MARK: - Siri Shortcuts / App Intents
//
// Exposes voice-/Shortcuts-accessible portfolio queries. Each intent reads the
// same App Group snapshot the widget consumes (written by WidgetDataProvider on
// every recompute) rather than spinning up the MainActor store, because intents
// can run in a separate process where the store isn't loaded — the snapshot file
// is the established cross-process data path.
//
// Phrasing lives in PortfolioVoiceSummary (pure, unit-tested); these wrappers just
// load the snapshot and return the result as both spoken dialog and a glanceable
// snippet view.

private func loadSnapshot() -> WidgetSnapshot? {
    WidgetDataProvider.readSnapshot()
}

let lockedPortfolioMessage = "EscapeMint is locked. Open the app and authenticate to view your portfolio."

func portfolioResponse(
    isExternalPortfolioLocked: Bool = WidgetDataProvider.externalPortfolioAccessIsLocked,
    _ summary: (WidgetSnapshot?) -> String
) -> String {
    guard !isExternalPortfolioLocked else {
        return lockedPortfolioMessage
    }
    return summary(loadSnapshot())
}

/// "What's my portfolio value?"
struct PortfolioValueIntent: AppIntent {
    static let title: LocalizedStringResource = "Portfolio Value"
    static let description = IntentDescription(
        "Reports your total portfolio value and overall gain or loss."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let phrase = portfolioResponse(PortfolioVoiceSummary.portfolioValue)
        return .result(
            dialog: IntentDialog(stringLiteral: phrase),
            view: IntentSnippetView(headline: "Portfolio Value", message: phrase)
        )
    }
}

/// "Show my top performer"
struct TopPerformerIntent: AppIntent {
    static let title: LocalizedStringResource = "Top Performer"
    static let description = IntentDescription(
        "Shows the fund with the highest gain in your portfolio."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let phrase = portfolioResponse(PortfolioVoiceSummary.topPerformer)
        return .result(
            dialog: IntentDialog(stringLiteral: phrase),
            view: IntentSnippetView(headline: "Top Performer", message: phrase)
        )
    }
}

/// Morning portfolio summary — value, overall gain, and DCA actions due today.
struct MorningSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Morning Portfolio Summary"
    static let description = IntentDescription(
        "A morning briefing: portfolio value, overall gain, and any DCA actions due today."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let phrase = portfolioResponse(PortfolioVoiceSummary.morningSummary)
        return .result(
            dialog: IntentDialog(stringLiteral: phrase),
            view: IntentSnippetView(headline: "Morning Summary", message: phrase)
        )
    }
}

// MARK: - Snippet View

/// Compact result card shown by Siri / Shortcuts alongside the spoken dialog.
private struct IntentSnippetView: View {
    let headline: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(headline, systemImage: "leaf.fill")
                .font(.headline)
                .foregroundStyle(.mint)
            Text(message)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - App Shortcuts

/// Registers the intents as App Shortcuts so they appear in the Shortcuts app and
/// are invocable by voice without manual setup. Phrases must include the app name
/// token `\(.applicationName)` per AppIntents requirements.
struct EscapeMintShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PortfolioValueIntent(),
            phrases: [
                "What's my \(.applicationName) portfolio value",
                "How much is my \(.applicationName) portfolio worth",
                "Check my \(.applicationName) portfolio"
            ],
            shortTitle: "Portfolio Value",
            systemImageName: "dollarsign.circle"
        )
        AppShortcut(
            intent: TopPerformerIntent(),
            phrases: [
                "Show my \(.applicationName) top performer",
                "What's my best \(.applicationName) fund"
            ],
            shortTitle: "Top Performer",
            systemImageName: "chart.line.uptrend.xyaxis"
        )
        AppShortcut(
            intent: MorningSummaryIntent(),
            phrases: [
                "Give me my \(.applicationName) morning summary",
                "\(.applicationName) morning briefing"
            ],
            shortTitle: "Morning Summary",
            systemImageName: "sun.max"
        )
    }
}
