import SwiftUI

/// Multi-screen "guided" Add-Entry wizard — an onboarding-style flow that keeps the
/// user focused on one question at a time.
///
/// Direct-equity funds (default for stock/cash):
///   1. "What's your current equity?" (user enters portfolio value shown on the platform)
///   2. Recommendation + "What did you actually do?" (amount)
///   3. Review + save.
///
/// Shares-price funds (default for crypto, opt-in via FundConfig.equity_input):
///   1. Shows the preliminary DCA recommendation amount, asks
///      "How many shares would $X buy at today's price?"
///      From that we derive the current price and the user's current equity
///      (cumulative shares × price) — no need to look up equity directly on the platform.
///   2. Refined recommendation + actual transaction (dollars AND shares).
///   3. Review + save.
///
/// Advanced users can switch to the original single-form `AddEntryView` via the
/// Settings toggle `AppStorageKeys.advancedEntryMode`.
struct GuidedAddEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fundId: String
    var onSaved: () -> Void

    private var fund: FundData? { FundDataStore.shared.fund(byId: fundId) }

    @State private var step: Int = 1
    @State private var date = Date()

    // Step 1 — direct mode
    @State private var enteredEquity: String = ""

    // Step 1 — shares-price mode
    @State private var sharesForDca: String = ""
    @State private var preliminaryDcaAmount: Double = 0

    // Step 2
    @State private var liveRecommendation: Recommendation? = nil
    @State private var actualAction: FundAction = .BUY
    @State private var actualAmount: String = ""
    @State private var actualShares: String = ""
    /// Marks this SELL as a full exit — forces post-action equity to 0 so the engine's
    /// liquidation detection fires even when slippage makes actualAmount ≠ currentEquity.
    @State private var exitedPosition: Bool = false
    @State private var userTouchedExit: Bool = false

    // Step 3 — editable summary overrides (seeded when advancing to step 3)
    @State private var equityBeforeOverride: String = ""
    @State private var equityAfterOverride: String = ""
    @State private var didSeedStep3: Bool = false

    // Step 3 — editable optional fields
    @State private var notes: String = ""
    @State private var dividendStr: String = ""
    @State private var marginAvailableStr: String = ""
    @State private var marginBorrowedStr: String = ""
    @State private var cashInterestStr: String = ""
    @State private var feeStr: String = ""

    @State private var didSeed: Bool = false
    @State private var isSaving = false

    // MARK: Derived

    private var equityInput: EquityInputMethod {
        fund?.config.effectiveEquityInput ?? .direct
    }

    /// Derived current price in shares-price mode: preliminary DCA / sharesForDca.
    private var derivedPrice: Double {
        let s = parseFormulaValue(sharesForDca)
        guard s > 0, preliminaryDcaAmount > 0 else { return 0 }
        return preliminaryDcaAmount / s
    }

    /// Cumulative shares held before this new entry, including recorded same-day actions.
    private var cumulativeSharesHeld: Double {
        guard let fund else { return 0 }
        return cumulativeSharesForNewEntry(
            entries: fund.entries,
            on: isoDateFormatter.string(from: date)
        )
    }

    /// Single source of truth for "this entry fully closes the position."
    private var isFullExit: Bool {
        guard let fund else { return false }
        return exitedPosition
            && actualAction == .SELL
            && !isCashFund(fund.config.fund_type)
    }

    /// The fund's current equity, derived from whichever step-1 inputs apply.
    private var finalEquity: Double {
        switch equityInput {
        case .direct:
            return max(0, parseFormulaValue(enteredEquity))
        case .shares_price:
            // Equity from shares already held × today's derived price.
            // If first-ever entry (no shares yet), we need the user to also enter actualShares
            // on step 2 — meanwhile show DCA as the sensible initial recommendation.
            return max(0, cumulativeSharesHeld * derivedPrice)
        }
    }

    private var canAdvanceFromStep1: Bool {
        switch equityInput {
        case .direct:
            return !enteredEquity.trimmingCharacters(in: .whitespaces).isEmpty
                && parseFormulaValue(enteredEquity) >= 0
        case .shares_price:
            return parseFormulaValue(sharesForDca) > 0
        }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if let fund {
                    switch step {
                    case 1:
                        GuidedStep1(
                            fund: fund,
                            date: $date,
                            enteredEquity: $enteredEquity,
                            sharesForDca: $sharesForDca,
                            preliminaryDcaAmount: preliminaryDcaAmount,
                            derivedPrice: derivedPrice,
                            cumulativeShares: cumulativeSharesHeld,
                            derivedEquity: finalEquity
                        )
                    case 2:
                        GuidedStep2(
                            fund: fund,
                            recommendation: liveRecommendation,
                            actualAction: $actualAction,
                            actualAmount: $actualAmount,
                            actualShares: $actualShares,
                            capturesShares: equityInput == .shares_price,
                            exitedPosition: Binding(
                                get: { exitedPosition },
                                set: { exitedPosition = $0; userTouchedExit = true }
                            )
                        )
                    default:
                        GuidedStep3(
                            fund: fund,
                            showShares: equityInput == .shares_price,
                            exitedPosition: isFullExit,
                            date: $date,
                            action: $actualAction,
                            actualAmount: $actualAmount,
                            equityBefore: $equityBeforeOverride,
                            equityAfter: $equityAfterOverride,
                            sharesBinding: $actualShares,
                            dividend: $dividendStr,
                            marginAvailable: $marginAvailableStr,
                            marginBorrowed: $marginBorrowedStr,
                            cashInterest: $cashInterestStr,
                            fee: $feeStr,
                            notes: $notes
                        )
                    }
                } else {
                    ProgressView()
                }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 500)
            #endif
            .safeAreaInset(edge: .top) { topBar }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .onAppear(perform: seedIfNeeded)
        }
    }

    @ViewBuilder
    private var topBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .foregroundColor(.mint)
            Spacer()
            Text(stepTitle)
                .font(.headline)
            Spacer()
            // Spacer balance so title stays centered
            Text("Cancel").opacity(0).accessibilityHidden(true)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            GuidedStepIndicator(step: step, total: 3)
                .padding(.bottom, 2)
        }
        .padding(.bottom, 8)
        .background(Color.bg.ignoresSafeArea(edges: .top))
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if step > 1 {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { step -= 1 }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            if step < 3 {
                Button {
                    advance()
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                        Image(systemName: "chevron.right")
                    }
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(step == 1 && !canAdvanceFromStep1)
            } else {
                Button {
                    save()
                } label: {
                    Label("Save Entry", systemImage: "checkmark.circle.fill")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.bg.ignoresSafeArea(edges: .bottom))
    }

    private var stepTitle: String {
        switch step {
        case 1: return equityInput == .shares_price ? "Price Check" : "Current Equity"
        case 2: return "Recommended Action"
        default: return "Review & Save"
        }
    }

    // MARK: - Actions

    private func seedIfNeeded() {
        guard !didSeed, let fund else { return }
        didSeed = true
        switch fund.config.effectiveEquityInput {
        case .direct:
            if enteredEquity.isEmpty {
                let lastValue = prefilledEquityValue(for: fund.entries)
                enteredEquity = String(format: "%.\(fund.config.dollarDec)f", lastValue)
            }
        case .shares_price:
            // Compute a preliminary recommendation from last-known equity so we can ask the user
            // "how many shares would $X buy?" using a meaningful reference amount.
            preliminaryDcaAmount = preliminaryDcaReference(fund: fund)
        }
        // Carry forward margin values from last entry so the user sees their current state
        // and can nudge the numbers rather than retyping from scratch.
        if let last = fund.entries.last {
            let dd = fund.config.dollarDec
            if let ma = last.margin_available, ma > 0 {
                marginAvailableStr = String(format: "%.\(dd)f", ma)
            }
            if let mb = last.margin_borrowed, mb > 0 {
                marginBorrowedStr = String(format: "%.\(dd)f", mb)
            }
        }
    }

    /// Picks a sensible $ reference amount for the step-1 shares-at-DCA question.
    /// Prefers the computed preliminary recommendation amount; falls back to config's mid DCA.
    private func preliminaryDcaReference(fund: FundData) -> Double {
        let last = prefilledEquityValue(for: fund.entries)
        if let rec = recommendationForLiveEquity(fund: fund, currentEquity: last), rec.amount > 0 {
            return rec.amount
        }
        return fund.config.input_mid_usd ?? fund.config.input_min_usd ?? 100
    }

    private func advance() {
        guard let fund else { return }
        if step == 1 {
            // Compute the real recommendation now that we know today's equity.
            let rec = recommendationForLiveEquity(fund: fund, currentEquity: finalEquity)
            liveRecommendation = rec
            if let rec {
                actualAction = rec.action
                if actualAmount.isEmpty && rec.amount > 0 {
                    actualAmount = String(format: "%.\(fund.config.dollarDec)f", rec.amount)
                }
                // In shares-price mode, default actualShares to sharesForDca — if the user buys
                // exactly the recommended amount, they'd get exactly the shares they just priced.
                if equityInput == .shares_price && actualShares.isEmpty {
                    actualShares = sharesForDca
                }
                // Auto-toggle "Exited position" when the engine recommends a full harvest:
                // non-accumulate mode + SELL at (or above) current equity. Don't clobber a
                // user override once they've interacted with the toggle.
                if !userTouchedExit
                   && !isCashFund(fund.config.fund_type)
                   && rec.action == .SELL
                   && fund.config.accumulate != true
                   && finalEquity > 0
                   && rec.amount >= finalEquity - 0.01 {
                    exitedPosition = true
                } else if !userTouchedExit {
                    exitedPosition = false
                }
            } else {
                actualAction = isCashFund(fund.config.fund_type) ? .DEPOSIT : .HOLD
                if !userTouchedExit { exitedPosition = false }
            }
        }
        if step == 2 && !didSeedStep3 {
            let dd = fund.config.dollarDec
            let before = finalEquity
            let amt = parseFormulaValue(actualAmount)
            let after: Double
            switch actualAction {
            case .BUY, .DEPOSIT: after = before + amt
            case .SELL, .WITHDRAW: after = isFullExit ? 0 : max(0, before - amt)
            default: after = before
            }
            equityBeforeOverride = String(format: "%.\(dd)f", max(0, before))
            equityAfterOverride = String(format: "%.\(dd)f", max(0, after))
            didSeedStep3 = true
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { step += 1 }
    }

    private func save() {
        guard !isSaving, let fund else { return }
        isSaving = true
        let dd = fund.config.dollarDec
        func r(_ v: Double) -> Double {
            let m = pow(10.0, Double(dd))
            return (v * m).rounded() / m
        }

        let amt = r(parseFormulaValue(actualAmount))
        var shares = parseFormulaValue(actualShares)
        let isCash = isCashFund(fund.config.fund_type)
        let fullExit = isFullExit && amt > 0

        // Execution price for shares-price mode: prefer actual dollars/shares, fall back
        // to the step-1 derived price if only one was captured.
        var execPrice: Double = 0
        if equityInput == .shares_price {
            if amt > 0 && shares > 0 { execPrice = amt / abs(shares) }
            else { execPrice = derivedPrice }
        }

        // Entry.value stores PRE-action equity — the engine applies the action's `amount`
        // itself to derive post-action state (see FundEngine.computeFundMetricsForFund).
        // Resolution order for pre-action equity: user override in step 3 wins, else
        // shares-price mode recomputes from real execution price, else step-1 value.
        var equityForEntry = finalEquity
        if equityInput == .shares_price && execPrice > 0 {
            equityForEntry = cumulativeSharesHeld * execPrice
        }
        if !equityBeforeOverride.trimmingCharacters(in: .whitespaces).isEmpty {
            equityForEntry = max(0, parseFormulaValue(equityBeforeOverride))
        }

        // Full exit: force the engine's liquidation detection to fire. `valueLiquidated`
        // requires entry.value ≤ amount (pre-action equity sold for the exact SELL
        // amount, leaving $0). For share-tracking funds, also force the sold share
        // count to match the entire position so sumShares → 0 (sharesLiquidated path).
        if fullExit {
            equityForEntry = amt
            if equityInput == .shares_price && cumulativeSharesHeld > 0 {
                shares = cumulativeSharesHeld
            }
        }

        var entry: FundEntry
        if isCash {
            let balance = r(max(0, finalEquity))
            let cashAction: FundAction? = amt > 0 ? actualAction : nil
            entry = FundEntry(
                date: isoDateFormatter.string(from: date),
                value: balance,
                cash: balance,
                action: cashAction,
                amount: amt > 0 ? amt : nil
            )
        } else {
            entry = FundEntry(
                date: isoDateFormatter.string(from: date),
                value: r(max(0, equityForEntry)),
                action: actualAction
            )
            if amt != 0 { entry.amount = amt }
            if shares != 0 { entry.shares = shares }
            if execPrice > 0 { entry.price = r(execPrice) }
        }
        func assign(_ str: String, _ keyPath: WritableKeyPath<FundEntry, Double?>) {
            let v = r(parseFormulaValue(str))
            if v != 0 { entry[keyPath: keyPath] = v }
        }
        assign(dividendStr, \.dividend)
        assign(marginAvailableStr, \.margin_available)
        assign(marginBorrowedStr, \.margin_borrowed)
        assign(cashInterestStr, \.cash_interest)
        assign(feeStr, \.expense)
        if fullExit {
            let marker = "Exited position"
            notes = notes.isEmpty ? marker : "\(marker) | \(notes)"
        }
        if !notes.isEmpty { entry.notes = notes }

        entry.fund_size = computeFundSizeForEntry(entry, existingEntries: fund.entries, config: fund.config)

        var writes: [(fundId: String, entry: FundEntry)] = [(fundId, entry)]
        if let cashWrite = buildCashSyncWrite(fundId: fundId, entry: entry, config: fund.config) {
            writes.append(cashWrite)
        }

        dismiss()
        Task {
            await FundDataStore.shared.appendEntries(writes: writes)
            onSaved()
        }
    }
}

// MARK: - Step indicator

private struct GuidedStepIndicator: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Color.mint : Color.textMuted.opacity(0.25))
                    .frame(width: i == step ? 22 : 7, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }
}

// MARK: - Reusable onboarding-style question view

private struct GuidedQuestion<Input: View, Footer: View>: View {
    let eyebrow: String
    let question: String
    let subtitle: String?
    @ViewBuilder var input: () -> Input
    @ViewBuilder var footer: () -> Footer

    init(
        eyebrow: String,
        question: String,
        subtitle: String? = nil,
        @ViewBuilder input: @escaping () -> Input,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.eyebrow = eyebrow
        self.question = question
        self.subtitle = subtitle
        self.input = input
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 24)

            VStack(spacing: 10) {
                Text(eyebrow)
                    .font(.title3).fontWeight(.bold)
                    .tracking(0.5)
                    .foregroundColor(.mint)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.mint.opacity(0.12))
                    .cornerRadius(8)
                Text(question)
                    .font(.title2).fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 24)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            input()
                .padding(.horizontal, 24)

            footer()
                .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Big dollar-amount input

private struct BigDollarInput: View {
    @Binding var text: String
    var prefix: String = "$"
    var suffix: String? = nil
    var placeholder: String = "0.00"
    @FocusState private var focused: Bool
    // Scale the hero point sizes with Dynamic Type (anchored to the largeTitle style)
    // so the primary input grows at accessibility text sizes like the rest of the UI.
    @ScaledMetric(relativeTo: .largeTitle) private var prefixSize: CGFloat = 34
    @ScaledMetric(relativeTo: .largeTitle) private var fieldSize: CGFloat = 40

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(prefix)
                .font(.system(size: prefixSize, weight: .regular, design: .rounded))
                .foregroundColor(.textMuted)
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.textMuted.opacity(0.4)))
                .font(.system(size: fieldSize, weight: .semibold, design: .rounded))
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.leading)
                .formulaKeyboard()
                .focused($focused)
                .textFieldStyle(.plain)
            if let suffix {
                Text(suffix)
                    .font(.title3)
                    .foregroundColor(.textMuted)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.bgCard)
        )
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { focused = true }
        }
        #if os(iOS)
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
            }
        }
        #endif
    }
}

// MARK: - Step 1

private struct GuidedStep1: View {
    let fund: FundData
    @Binding var date: Date
    @Binding var enteredEquity: String
    @Binding var sharesForDca: String
    let preliminaryDcaAmount: Double
    let derivedPrice: Double
    let cumulativeShares: Double
    let derivedEquity: Double

    private var dd: Int { fund.config.dollarDec }

    var body: some View {
        ScrollView {
            switch fund.config.effectiveEquityInput {
            case .direct: directBody
            case .shares_price: sharesPriceBody
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.bg.ignoresSafeArea())
    }

    @ViewBuilder
    private var directBody: some View {
        GuidedQuestion(
            eyebrow: fund.ticker.uppercased(),
            question: isCashFund(fund.config.fund_type)
                ? "What's the current cash balance?"
                : "What's your current equity?",
            subtitle: "Enter the total value of this fund as shown on your trading platform right now.",
            input: {
                BigDollarInput(text: $enteredEquity)
            },
            footer: {
                VStack(spacing: 16) {
                    if let last = fund.entries.last {
                        Text("Last recorded: \(formatCurrency(last.value, decimals: dd)) on \(last.date)")
                            .font(.caption)
                            .foregroundColor(.textMuted)
                    }
                    DateFooter(date: $date)
                }
            }
        )
    }

    @ViewBuilder
    private var sharesPriceBody: some View {
        GuidedQuestion(
            eyebrow: fund.ticker.uppercased(),
            question: "If you bought \(formatCurrency(preliminaryDcaAmount, decimals: dd)) of \(fund.ticker.uppercased()) today, how many shares would that be?",
            subtitle: "We'll use that to figure out today's price and your current equity — no need to look it up.",
            input: {
                BigDollarInput(
                    text: $sharesForDca,
                    prefix: "",
                    suffix: "shares",
                    placeholder: "0"
                )
            },
            footer: {
                VStack(spacing: 16) {
                    if derivedPrice > 0 {
                        VStack(spacing: 4) {
                            Text("≈ \(formatCurrency(derivedPrice, decimals: dd)) per share")
                                .font(.subheadline)
                                .foregroundColor(.textSecondary)
                            if cumulativeShares > 0 {
                                Text("Your equity: \(formatCurrency(derivedEquity, decimals: dd))  (\(cleanShares(cumulativeShares)) shares held)")
                                    .font(.caption)
                                    .foregroundColor(.textMuted)
                            } else {
                                Text("You don't hold any shares yet — we'll set up your starting position on the next step.")
                                    .font(.caption)
                                    .foregroundColor(.textMuted)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
                    DateFooter(date: $date)
                }
            }
        )
    }
}

private struct DateFooter: View {
    @Binding var date: Date
    var body: some View {
        HStack {
            Text("Date").font(.caption).foregroundColor(.textMuted)
            Spacer()
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.bgCard.opacity(0.6))
        )
    }
}

// MARK: - Step 2

private struct GuidedStep2: View {
    let fund: FundData
    let recommendation: Recommendation?
    @Binding var actualAction: FundAction
    @Binding var actualAmount: String
    @Binding var actualShares: String
    let capturesShares: Bool
    @Binding var exitedPosition: Bool

    // Scale the recommendation headline with Dynamic Type (anchored to .title).
    @ScaledMetric(relativeTo: .title) private var recAmountSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title2) private var recManualSize: CGFloat = 24

    private var dd: Int { fund.config.dollarDec }

    private var allowedActions: [FundAction] {
        isCashFund(fund.config.fund_type)
            ? [.DEPOSIT, .WITHDRAW, .HOLD]
            : [.BUY, .SELL, .HOLD]
    }

    private var canExit: Bool {
        !isCashFund(fund.config.fund_type) && actualAction == .SELL
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                recommendationCard
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                VStack(spacing: 14) {
                    Text("What did you actually do?")
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundColor(.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Picker("Action", selection: $actualAction) {
                        ForEach(allowedActions, id: \.self) { a in
                            Text(a.rawValue).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)

                    BigDollarInput(text: $actualAmount)
                        .opacity(actualAction == .HOLD ? 0.4 : 1)
                        .disabled(actualAction == .HOLD)

                    if capturesShares {
                        BigDollarInput(
                            text: $actualShares,
                            prefix: "",
                            suffix: "shares",
                            placeholder: "0"
                        )
                        .opacity(actualAction == .HOLD ? 0.4 : 1)
                        .disabled(actualAction == .HOLD)
                    }

                    if canExit {
                        exitToggle
                    }

                    Text(capturesShares
                         ? "Enter the real dollars spent and shares received — market slippage means these often differ slightly from the recommendation."
                         : "Enter the real executed amount — market slippage means a $100 buy might settle at $100.01.")
                        .font(.caption)
                        .foregroundColor(.textMuted)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)

                Spacer(minLength: 8)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.bg.ignoresSafeArea())
    }

    @ViewBuilder
    private var exitToggle: some View {
        Toggle(isOn: $exitedPosition) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Exited position")
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundColor(.textPrimary)
                Text("Zero out remaining equity and close the cycle — use this when you sold everything, even if the dollar amount differs from your last recorded equity.")
                    .font(.caption)
                    .foregroundColor(.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(.mint)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.bgCard)
        )
    }

    @ViewBuilder
    private var recommendationCard: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("WE SUGGEST")
                    .font(.caption2).fontWeight(.semibold)
                    .tracking(1.5)
                    .foregroundColor(.textMuted)
                if let rec = recommendation {
                    Text(rec.action == .HOLD
                         ? "HOLD"
                         : "\(rec.action.rawValue) \(formatCurrency(rec.amount, decimals: dd))")
                        .font(.system(size: recAmountSize, weight: .bold, design: .rounded))
                        .foregroundColor(Color.forAction(rec.action))
                    Text(rec.reasoning)
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Manual entry")
                        .font(.system(size: recManualSize, weight: .semibold, design: .rounded))
                        .foregroundColor(.textSecondary)
                    Text("This fund doesn't compute DCA recommendations — record what happened below.")
                        .font(.caption).foregroundColor(.textMuted)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.forAction(recommendation?.action ?? .HOLD).opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Step 3

private struct GuidedStep3: View {
    let fund: FundData
    let showShares: Bool
    let exitedPosition: Bool
    @Binding var date: Date
    @Binding var action: FundAction
    @Binding var actualAmount: String
    @Binding var equityBefore: String
    @Binding var equityAfter: String
    @Binding var sharesBinding: String
    @Binding var dividend: String
    @Binding var marginAvailable: String
    @Binding var marginBorrowed: String
    @Binding var cashInterest: String
    @Binding var fee: String
    @Binding var notes: String

    private enum EntryField: Hashable { case amount, equityBefore, equityAfter }
    @FocusState private var focusedField: EntryField?

    private var dd: Int { fund.config.dollarDec }
    private var features: FundTypeFeatures { getFeatures(fund.config.fund_type) }
    private var isCash: Bool { isCashFund(fund.config.fund_type) }

    private var parsedShares: Double { parseFormulaValue(sharesBinding) }

    private var allowedActions: [FundAction] {
        isCash ? [.DEPOSIT, .WITHDRAW, .HOLD] : [.BUY, .SELL, .HOLD]
    }

    private func fmt(_ v: Double) -> String { String(format: "%.\(dd)f", max(0, v)) }

    /// When amount or before changes due to user editing that specific field, recompute after.
    private func syncAfterFromAmountAndBefore() {
        let before = parseFormulaValue(equityBefore)
        let amt = parseFormulaValue(actualAmount)
        let after: Double
        switch action {
        case .BUY, .DEPOSIT: after = before + amt
        case .SELL, .WITHDRAW: after = exitedPosition ? 0 : max(0, before - amt)
        default: after = before
        }
        equityAfter = fmt(after)
    }

    /// When after is edited by the user, back-calculate amount from before & after.
    private func syncAmountFromAfter() {
        let before = parseFormulaValue(equityBefore)
        let after = parseFormulaValue(equityAfter)
        let amt: Double
        switch action {
        case .BUY, .DEPOSIT: amt = max(0, after - before)
        case .SELL, .WITHDRAW: amt = max(0, before - after)
        default: amt = 0
        }
        actualAmount = fmt(amt)
    }

    private struct DetailRow: Identifiable {
        let id: String
        let label: String
        let text: Binding<String>
        /// Sign affix shown to the right of the value; when "-" is passed,
        /// NumericFieldRow also strips user-entered minus signs.
        let sign: String?
        let placeholder: String
    }

    private var detailRows: [DetailRow] {
        var rows: [DetailRow] = []
        if features.supportsShares && !showShares {
            rows.append(DetailRow(id: "shares", label: "Shares / Units", text: $sharesBinding, sign: nil, placeholder: "0"))
        }
        if features.supportsDividends {
            rows.append(DetailRow(id: "dividend", label: "Dividend ($)", text: $dividend, sign: nil, placeholder: "0.00"))
        }
        if features.supportsMargin {
            rows.append(DetailRow(id: "margin_avail", label: "Margin available ($)", text: $marginAvailable, sign: nil, placeholder: "0.00"))
            rows.append(DetailRow(id: "margin_borrow", label: "Margin borrowed ($)", text: $marginBorrowed, sign: "-", placeholder: "0.00"))
        }
        if isCash {
            rows.append(DetailRow(id: "cash_interest", label: "Interest earned ($)", text: $cashInterest, sign: nil, placeholder: "0.00"))
            rows.append(DetailRow(id: "fee", label: "Fee ($)", text: $fee, sign: "-", placeholder: "0.00"))
        }
        return rows
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCard
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                if !detailRows.isEmpty {
                    detailsCard
                        .padding(.horizontal, 20)
                }

                notesCard
                    .padding(.horizontal, 20)

                Spacer(minLength: 8)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.bg.ignoresSafeArea())
    }

    // MARK: Summary card (editable entry)

    @ViewBuilder
    private var summaryCard: some View {
        VStack(spacing: 0) {
            summaryRow("Fund", value: "\(fund.ticker.uppercased()) (\(fund.platform))")
            Divider()
            dateRow
            Divider()
            actionRow
            if action != .HOLD {
                Divider()
                NumericFieldRow(label: "Amount ($)", placeholder: "0.00", text: $actualAmount)
                    .focused($focusedField, equals: .amount)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                if showShares && parsedShares > 0 {
                    Divider()
                    summaryRow("Shares", value: cleanShares(parsedShares))
                }
            }
            Divider()
            NumericFieldRow(label: "Equity before ($)", placeholder: "0.00", text: $equityBefore)
                .focused($focusedField, equals: .equityBefore)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            if action != .HOLD {
                Divider()
                equityAfterRow
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.bgCard)
        )
        .onChange(of: actualAmount) { _, _ in
            if focusedField == .amount { syncAfterFromAmountAndBefore() }
        }
        .onChange(of: equityBefore) { _, _ in
            if focusedField == .equityBefore { syncAfterFromAmountAndBefore() }
        }
        .onChange(of: equityAfter) { _, _ in
            if focusedField == .equityAfter { syncAmountFromAfter() }
        }
        .onChange(of: action) { _, _ in syncAfterFromAmountAndBefore() }
    }

    @ViewBuilder
    private var dateRow: some View {
        HStack {
            Text("Date")
                .font(.subheadline)
                .foregroundColor(.textMuted)
            Spacer()
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack {
            Text("Action")
                .font(.subheadline)
                .foregroundColor(.textMuted)
            Spacer()
            Picker("", selection: $action) {
                ForEach(allowedActions, id: \.self) { a in
                    Text(a.rawValue).tag(a)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var equityAfterRow: some View {
        if exitedPosition {
            summaryRow(
                "Equity after",
                value: "\(formatCurrency(0, decimals: dd)) (exited)",
                color: .mint
            )
        } else {
            NumericFieldRow(label: "Equity after ($)", placeholder: "0.00", text: $equityAfter)
                .focused($focusedField, equals: .equityAfter)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    // MARK: Details card (editable optional fields)

    @ViewBuilder
    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Details (optional)")
                .font(.caption).fontWeight(.semibold).tracking(1)
                .foregroundColor(.textMuted)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ForEach(Array(detailRows.enumerated()), id: \.element.id) { idx, row in
                if idx > 0 {
                    Divider().padding(.leading, 14)
                }
                NumericFieldRow(
                    label: row.label,
                    placeholder: row.placeholder,
                    text: row.text,
                    sign: row.sign
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.bgCard)
        )
    }

    // MARK: Notes

    @ViewBuilder
    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes (optional)")
                .font(.caption).foregroundColor(.textMuted)
            TextField("", text: $notes, prompt: Text("Anything to remember about this entry?").foregroundColor(.textMuted.opacity(0.5)))
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.bgCard)
                )
        }
    }

    @ViewBuilder
    private func summaryRow(_ label: String, value: String, color: Color = .textPrimary) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.textMuted)
            Spacer()
            Text(value)
                .font(.subheadline).fontWeight(.medium)
                .foregroundColor(color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
