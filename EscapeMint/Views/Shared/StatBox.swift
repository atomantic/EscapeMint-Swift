import SwiftUI

// MARK: - Stat Box

struct StatBox: View {
    let label: String
    let value: String
    var color: Color = .textPrimary
    var showCard: Bool = true

    /// VoiceOver announces gain/loss direction so it isn't conveyed by color alone.
    /// When the value is colored .mint (gain) or .red (loss), append a spoken
    /// direction derived from the leading "-" in the value string. Callers that
    /// want explicit wording can pass an override.
    var accessibilityDirection: String? = nil

    private var directionSuffix: String {
        if let accessibilityDirection { return ", \(accessibilityDirection)" }
        guard color == .mint || color == .red else { return "" }
        return value.trimmingCharacters(in: .whitespaces).hasPrefix("-") ? ", loss" : ", gain"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(value).font(.callout).fontWeight(.semibold).foregroundColor(color)
        }
        .frame(maxWidth: showCard ? .infinity : nil, alignment: .leading)
        .padding(showCard ? 10 : 0)
        .background(showCard ? Color.bgCard : .clear)
        .cornerRadius(showCard ? 8 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)\(directionSuffix)")
    }
}

#if DEBUG
#Preview("StatBox") {
    HStack {
        StatBox(label: "Size", value: "$1,510")
        StatBox(label: "Realized", value: "+18.4%", color: .mint)
        StatBox(label: "Liquid", value: "-3.1%", color: .red)
    }
    .padding()
    .background(Color.bg)
}

#Preview("StatBox — Dark") {
    HStack {
        StatBox(label: "Size", value: "$1,510")
        StatBox(label: "Realized", value: "+18.4%", color: .mint)
    }
    .padding()
    .background(Color.bg)
    .preferredColorScheme(.dark)
}
#endif
