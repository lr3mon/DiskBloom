import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

enum BloomTheme {
    static let background = Color(hex: 0x0B0E14)
    static let sidebar = Color(hex: 0x11151D)
    static let panel = Color(hex: 0x151A24)
    static let panelRaised = Color(hex: 0x1B2130)
    static let border = Color.white.opacity(0.08)
    static let text = Color(hex: 0xF4F6FA)
    static let secondary = Color(hex: 0x99A3B5)
    static let muted = Color(hex: 0x667085)
    static let mint = Color(hex: 0x66D9B7)
    static let amber = Color(hex: 0xF1B45B)
    static let coral = Color(hex: 0xF27F87)
    static let blue = Color(hex: 0x6EA8FE)
    static let violet = Color(hex: 0xAA8BFA)

    static let chartPalette: [Color] = [
        Color(hex: 0x66D9B7),
        Color(hex: 0x6EA8FE),
        Color(hex: 0xF1B45B),
        Color(hex: 0xF27F87),
        Color(hex: 0xAA8BFA),
        Color(hex: 0x58C7D4),
        Color(hex: 0xE88CC5),
        Color(hex: 0xA5D76E)
    ]
}

struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(BloomTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(BloomTheme.border, lineWidth: 1)
            )
    }
}

extension View {
    func bloomPanel() -> some View { modifier(PanelStyle()) }
}
