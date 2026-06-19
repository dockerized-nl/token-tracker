import SwiftUI

/// White & blue visual theme for the whole app.
enum Theme {
    // Core blues
    static let primary      = Color(red: 0.13, green: 0.45, blue: 0.95) // #2173F2
    static let primaryDark  = Color(red: 0.07, green: 0.32, blue: 0.78)
    static let accent       = Color(red: 0.20, green: 0.60, blue: 1.00)
    static let sky          = Color(red: 0.55, green: 0.78, blue: 1.00)

    // Surfaces
    static let background   = Color(red: 0.96, green: 0.98, blue: 1.00) // very light blue-white
    static let card         = Color.white
    static let cardStroke   = Color(red: 0.85, green: 0.91, blue: 0.99)
    static let sidebar      = Color(red: 0.92, green: 0.96, blue: 1.00)

    // Text
    static let textPrimary   = Color(red: 0.10, green: 0.16, blue: 0.26)
    static let textSecondary = Color(red: 0.40, green: 0.48, blue: 0.60)

    // Semantic
    static let good = Color(red: 0.16, green: 0.66, blue: 0.45)
    static let warn = Color(red: 0.95, green: 0.61, blue: 0.18)
    static let bad  = Color(red: 0.88, green: 0.31, blue: 0.31)

    static let cardShadow = Color.black.opacity(0.06)

    /// A palette used to color series (models, etc.)
    static let series: [Color] = [
        Color(red: 0.13, green: 0.45, blue: 0.95),
        Color(red: 0.20, green: 0.60, blue: 1.00),
        Color(red: 0.40, green: 0.74, blue: 0.98),
        Color(red: 0.55, green: 0.78, blue: 1.00),
        Color(red: 0.10, green: 0.32, blue: 0.70),
        Color(red: 0.30, green: 0.50, blue: 0.85)
    ]
}

/// Formats large token counts compactly: 1.2K, 3.4M, 5.6B
func formatTokens(_ n: Int) -> String {
    let d = Double(n)
    switch abs(n) {
    case 1_000_000_000...: return String(format: "%.2fB", d / 1_000_000_000)
    case 1_000_000...:     return String(format: "%.2fM", d / 1_000_000)
    case 1_000...:         return String(format: "%.1fK", d / 1_000)
    default:               return "\(n)"
    }
}

func formatFull(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}
