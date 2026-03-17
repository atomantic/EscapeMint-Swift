import SwiftUI

// MARK: - Adaptive Colors (light + dark mode)

extension Color {
    init(light: Color, dark: Color) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #endif
    }
}

extension Color {
    // Backgrounds
    static let bg = Color(
        light: Color(red: 248/255, green: 250/255, blue: 252/255),  // slate-50
        dark: Color(red: 15/255, green: 23/255, blue: 42/255)       // slate-900
    )
    static let bgCard = Color(
        light: .white,
        dark: Color(red: 30/255, green: 41/255, blue: 59/255)       // slate-800
    )
    static let bgInput = Color(
        light: Color(red: 241/255, green: 245/255, blue: 249/255),  // slate-100
        dark: Color(red: 51/255, green: 65/255, blue: 85/255)       // slate-600
    )

    // Brand
    static let mint = Color(red: 16/255, green: 185/255, blue: 129/255)     // emerald-500
    static let mintDark = Color(red: 5/255, green: 150/255, blue: 105/255)  // emerald-600

    // Card border — visible in light mode, subtle in dark
    static let cardBorder = Color(
        light: Color(red: 226/255, green: 232/255, blue: 240/255),  // slate-200
        dark: Color(red: 51/255, green: 65/255, blue: 85/255).opacity(0.5) // slate-600 faint
    )

    // Text
    static let textPrimary = Color(
        light: Color(red: 15/255, green: 23/255, blue: 42/255),     // slate-900
        dark: .white
    )
    static let textSecondary = Color(
        light: Color(red: 71/255, green: 85/255, blue: 105/255),    // slate-600
        dark: Color(red: 148/255, green: 163/255, blue: 184/255)    // slate-400
    )
    static let textMuted = Color(
        light: Color(red: 148/255, green: 163/255, blue: 184/255),  // slate-400
        dark: Color(red: 100/255, green: 116/255, blue: 139/255)    // slate-500
    )
}

// MARK: - Layout Constants

enum Layout {
    static let chartFrameHeight: CGFloat = 160
}

// MARK: - Card Style Modifier

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.bgCard)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.cardBorder, lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}

extension Color {
    static func forCategory(_ cat: FundCategory?) -> Color {
        guard let cat else { return .gray }
        return categoryConfig[cat]?.color ?? .gray
    }

    static func forAction(_ action: FundAction?) -> Color {
        switch action {
        case .BUY, .DEPOSIT: return .mint
        case .SELL, .WITHDRAW: return .red
        case .HOLD: return .textSecondary
        default: return .orange
        }
    }
}
