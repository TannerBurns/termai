import SwiftUI

/// A stylized brain icon for reasoning/thinking models with modern multicolor palette rendering
/// Creates a purple-to-blue gradient effect that works in menus, buttons, and labels
struct ReasoningBrainIcon: View {
    enum Size {
        case small      // For menu items and captions
        case medium     // For buttons and labels
        case large      // For larger UI elements
        
        var font: Font {
            switch self {
            case .small: return .caption
            case .medium: return .system(size: 14)
            case .large: return .system(size: 18)
            }
        }
    }
    
    let size: Size
    let showGlow: Bool
    
    init(size: Size = .medium, showGlow: Bool = false) {
        self.size = size
        self.showGlow = showGlow
    }
    
    var body: some View {
        Image(systemName: "brain")
            .font(size.font)
            .symbolRenderingMode(.palette)
            .foregroundStyle(
                // Primary: vibrant purple
                Color.purple,
                // Secondary: blue for depth
                Color.blue,
                // Tertiary: softer purple accent
                Color.purple.opacity(0.6)
            )
            .shadow(
                color: showGlow ? Color.purple.opacity(0.4) : .clear,
                radius: showGlow ? 3 : 0
            )
    }
}

/// A Label-compatible brain icon for menu items that need Label format
struct ReasoningBrainLabel: View {
    let text: String
    let size: ReasoningBrainIcon.Size
    
    init(_ text: String, size: ReasoningBrainIcon.Size = .small) {
        self.text = text
        self.size = size
    }
    
    var body: some View {
        HStack(spacing: 6) {
            ReasoningBrainIcon(size: size)
            Text(text)
        }
    }
}

