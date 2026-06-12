import SwiftUI

struct MetricCard: View {
    let label: String
    let value: String
    var sub: String? = nil
    var color: Color? = nil
    var tooltip: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(value).font(.callout).fontWeight(.bold).foregroundColor(color ?? .textPrimary)
            if let sub { Text(sub).font(.caption2).foregroundColor(.textMuted) }
        }
        #if os(macOS)
        .help(tooltip ?? "")
        #endif
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)\(sub.map { ", \($0)" } ?? "")")
        .accessibilityIdentifier("metric-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

#if DEBUG
#Preview("MetricCard") {
    HStack {
        MetricCard(label: "Total Value", value: "$12,480", sub: "+$1,240")
        MetricCard(label: "Liquid APY", value: "24.8%", color: .mint)
        MetricCard(label: "Drawdown", value: "-8.2%", color: .red)
    }
    .padding()
    .background(Color.bg)
}

#Preview("MetricCard — Dark") {
    HStack {
        MetricCard(label: "Total Value", value: "$12,480", sub: "+$1,240")
        MetricCard(label: "Liquid APY", value: "24.8%", color: .mint)
    }
    .padding()
    .background(Color.bg)
    .preferredColorScheme(.dark)
}

#Preview("MetricCard — XXL Type") {
    MetricCard(label: "Total Value", value: "$12,480", sub: "+$1,240")
        .padding()
        .background(Color.bg)
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
