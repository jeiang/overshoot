import SwiftUI

/// Visual language of a 2006-08 Sony Ericsson Cyber-shot phone camera: dark translucent bars
/// around the viewfinder, white icons, rounded handset type and orange highlights.
enum Theme {
    static let orange = Color(red: 0xF2 / 255, green: 0x8C / 255, blue: 0x00 / 255)
    static let silver = Color(red: 0x9A / 255, green: 0xA3 / 255, blue: 0xAD / 255)
    static let warning = Color(red: 0xE5 / 255, green: 0x35 / 255, blue: 0x2B / 255)
    static let highlight = LinearGradient(
        colors: [Color(red: 1, green: 0.70, blue: 0.23), Color(red: 0.88, green: 0.44, blue: 0)],
        startPoint: .top,
        endPoint: .bottom
    )
    /// Bar plastic: a dark blue-grey gradient with a faint gloss line on the top edge.
    static let bar = LinearGradient(
        colors: [Color(red: 0.17, green: 0.19, blue: 0.21), Color(red: 0.05, green: 0.06, blue: 0.07)],
        startPoint: .top,
        endPoint: .bottom
    )

    static func font(_ size: CGFloat) -> Font { .custom("ArialRoundedMTBold", fixedSize: size) }
}

/// A bar's background: the plastic gradient plus a 1 pt gloss line along its top edge.
struct BarBackground: View {
    var body: some View {
        Theme.bar.overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
        }
    }
}

/// A soft key: a label that lights up orange while pressed, like a handset's selection key.
struct SoftKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(15))
            .foregroundStyle(configuration.isPressed ? Theme.orange : .white)
            .frame(minWidth: 64, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// The selected row or tab of a menu: the orange gradient bar with dark text.
struct HighlightRow: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(selected ? .black : .white)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.highlight)
                }
            }
    }
}
