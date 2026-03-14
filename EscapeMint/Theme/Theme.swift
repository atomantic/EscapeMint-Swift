import SwiftUI

extension Color {
    static let bg = Color(red: 15/255, green: 23/255, blue: 42/255)
    static let bgCard = Color(red: 30/255, green: 41/255, blue: 59/255)
    static let bgInput = Color(red: 51/255, green: 65/255, blue: 85/255)
    static let mint = Color(red: 16/255, green: 185/255, blue: 129/255)
    static let mintDark = Color(red: 5/255, green: 150/255, blue: 105/255)
    static let textSecondary = Color(red: 148/255, green: 163/255, blue: 184/255)
    static let textMuted = Color(red: 100/255, green: 116/255, blue: 139/255)
}

extension Color {
    static func forCategory(_ cat: FundCategory?) -> Color {
        switch cat {
        case .liquidity: return .blue
        case .yield: return .green
        case .sov: return .yellow
        case .volatility: return .purple
        case nil: return .gray
        }
    }
}
