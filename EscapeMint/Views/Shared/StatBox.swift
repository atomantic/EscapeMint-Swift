import SwiftUI

// MARK: - Stat Box

struct StatBox: View {
    let label: String
    let value: String
    var color: Color = .textPrimary
    var showCard: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(value).font(.callout).fontWeight(.semibold).foregroundColor(color)
        }
        .frame(maxWidth: showCard ? .infinity : nil, alignment: .leading)
        .padding(showCard ? 10 : 0)
        .background(showCard ? Color.bgCard : .clear)
        .cornerRadius(showCard ? 8 : 0)
    }
}
