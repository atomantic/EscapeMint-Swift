import SwiftUI

struct MetricCard: View {
    let label: String
    let value: String
    var sub: String? = nil
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(value).font(.callout).fontWeight(.bold).foregroundColor(color ?? .textPrimary)
            if let sub { Text(sub).font(.caption2).foregroundColor(.textMuted) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)\(sub.map { ", \($0)" } ?? "")")
        .accessibilityIdentifier("metric-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}
