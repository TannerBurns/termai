import SwiftUI

// MARK: - Appearance Settings View

struct AppearanceSettingsView: View {
    @ObservedObject var ptyModel: PTYModel
    @ObservedObject private var settings = AgentSettings.shared
    @Environment(\.colorScheme) var colorScheme
    
    private var selectedTheme: TerminalTheme {
        TerminalTheme.presets.first(where: { $0.id == ptyModel.themeId }) ?? TerminalTheme.presets.first ?? TerminalTheme.system()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // App Appearance Mode Section
                appAppearanceSection
                
                // App Theme Selection Grid
                themeSelectionSection
                
                // Terminal Bell Settings
                terminalBellSection
                
                // Live Preview
                livePreviewSection
                
                // Color Palette Details
                colorPaletteSection
            }
            .padding(24)
        }
        .frame(minWidth: 500)
        .onChange(of: settings.appAppearance) { _ in settings.save() }
        .onChange(of: settings.terminalBellMode) { _ in settings.save() }
    }
    
    // MARK: - App Appearance Section
    private var appAppearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("App Appearance", subtitle: "Choose light, dark, or follow system settings")
            
            HStack(spacing: 16) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    AppearanceModeCard(
                        mode: mode,
                        isSelected: settings.appAppearance == mode
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settings.appAppearance = mode
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Terminal Bell Section
    private var terminalBellSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Terminal Bell", subtitle: "Notification when programs signal an alert")
            
            HStack(spacing: 16) {
                ForEach(TerminalBellMode.allCases, id: \.self) { mode in
                    TerminalBellModeCard(
                        mode: mode,
                        isSelected: settings.terminalBellMode == mode
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settings.terminalBellMode = mode
                        }
                    }
                }
            }
            
            Text("The terminal bell triggers when programs need your attention, such as when pressing backspace with nothing to delete, or tab completion with no matches.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
    }
    
    // MARK: - App Theme Selection Grid
    private var themeSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("App Theme", subtitle: "Choose a color scheme for terminal, editor, and UI")
            
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                ForEach(TerminalTheme.presets) { theme in
                    ThemeCard(
                        theme: theme,
                        isSelected: theme.id == ptyModel.themeId
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            ptyModel.themeId = theme.id
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Live Preview Section
    private var livePreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Preview", subtitle: "How your terminal will look")
            
            VStack(alignment: .leading, spacing: 0) {
                // Terminal Title Bar
                HStack(spacing: 8) {
                    Circle().fill(Color.red.opacity(0.8)).frame(width: 12, height: 12)
                    Circle().fill(Color.yellow.opacity(0.8)).frame(width: 12, height: 12)
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 12, height: 12)
                    Spacer()
                    Text("Terminal Preview")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.3))
                
                // Terminal Content
                VStack(alignment: .leading, spacing: 4) {
                    terminalLine(prompt: "~/projects", command: "ls -la")
                    terminalOutputLine("drwxr-xr-x  5 user  staff   160 Nov 28 10:23 ", highlight: "src", highlightColor: ansiColor(4)) // Blue for directories
                    terminalOutputLine("drwxr-xr-x  3 user  staff    96 Nov 28 10:23 ", highlight: "docs", highlightColor: ansiColor(4))
                    terminalOutputLine("-rw-r--r--  1 user  staff  1234 Nov 28 10:23 ", highlight: "README.md", highlightColor: .white)
                    terminalOutputLine("-rwxr-xr-x  1 user  staff   567 Nov 28 10:23 ", highlight: "run.sh", highlightColor: ansiColor(2)) // Green for executables
                    
                    Spacer().frame(height: 8)
                    
                    terminalLine(prompt: "~/projects", command: "git status")
                    HStack(spacing: 0) {
                        Text("On branch ")
                            .foregroundColor(Color(selectedTheme.foreground))
                        Text("main")
                            .foregroundColor(ansiColor(2)) // Green
                    }
                    .font(.system(size: 12, design: .monospaced))
                    
                    HStack(spacing: 0) {
                        Text("Changes not staged: ")
                            .foregroundColor(Color(selectedTheme.foreground))
                        Text("modified: src/app.swift")
                            .foregroundColor(ansiColor(1)) // Red
                    }
                    .font(.system(size: 12, design: .monospaced))
                    
                    Spacer().frame(height: 8)
                    
                    terminalLine(prompt: "~/projects", command: "")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(selectedTheme.background))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        }
    }
    
    private func terminalLine(prompt: String, command: String) -> some View {
        HStack(spacing: 0) {
            Text(prompt)
                .foregroundColor(ansiColor(6)) // Cyan
            Text(" $ ")
                .foregroundColor(Color(selectedTheme.foreground).opacity(0.6))
            Text(command)
                .foregroundColor(Color(selectedTheme.foreground))
            if command.isEmpty {
                Rectangle()
                    .fill(Color(selectedTheme.caret ?? selectedTheme.foreground))
                    .frame(width: 8, height: 14)
                    .opacity(0.8)
            }
        }
        .font(.system(size: 12, design: .monospaced))
    }
    
    private func terminalOutputLine(_ prefix: String, highlight: String, highlightColor: Color) -> some View {
        HStack(spacing: 0) {
            Text(prefix)
                .foregroundColor(Color(selectedTheme.foreground).opacity(0.7))
            Text(highlight)
                .foregroundColor(highlightColor)
        }
        .font(.system(size: 12, design: .monospaced))
    }
    
    private func ansiColor(_ index: Int) -> Color {
        guard let palette = selectedTheme.ansi16Palette, index < palette.count else {
            // Fallback colors if no palette
            let fallback: [Color] = [.black, .red, .green, .yellow, .blue, .purple, .cyan, .white]
            return index < fallback.count ? fallback[index] : .white
        }
        let c = palette[index]
        return Color(
            red: Double(c.red) / 65535.0,
            green: Double(c.green) / 65535.0,
            blue: Double(c.blue) / 65535.0
        )
    }
    
    // MARK: - Color Palette Section
    private var colorPaletteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Color Palette", subtitle: "Standard ANSI colors used by the terminal")
            
            VStack(spacing: 16) {
                // Primary Colors Row
                HStack(spacing: 8) {
                    // Background & Foreground
                    ColorSwatch(
                        color: Color(selectedTheme.background),
                        label: "Background",
                        isLarge: true
                    )
                    ColorSwatch(
                        color: Color(selectedTheme.foreground),
                        label: "Foreground",
                        isLarge: true
                    )
                    ColorSwatch(
                        color: Color(selectedTheme.selectionBackground),
                        label: "Selection",
                        isLarge: true
                    )
                }
                
                Divider()
                
                // Normal Colors (0-7)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Normal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 6) {
                        ForEach(0..<8, id: \.self) { index in
                            ColorSwatch(
                                color: ansiColor(index),
                                label: ansiColorName(index),
                                isLarge: false
                            )
                        }
                    }
                }
                
                // Bright Colors (8-15)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bright")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 6) {
                        ForEach(8..<16, id: \.self) { index in
                            ColorSwatch(
                                color: ansiColor(index),
                                label: ansiColorName(index),
                                isLarge: false
                            )
                        }
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark 
                          ? Color(white: 0.12) 
                          : Color(white: 0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(colorScheme == .dark 
                            ? Color.white.opacity(0.08) 
                            : Color.black.opacity(0.06), lineWidth: 1)
            )
        }
    }
    
    private func ansiColorName(_ index: Int) -> String {
        let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
                     "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        return index < names.count ? names[index] : "\(index)"
    }
}

// MARK: - Theme Card

struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Mini Terminal Preview
                VStack(alignment: .leading, spacing: 2) {
                    miniTerminalLine("$ ls", color: Color(theme.foreground))
                    miniTerminalLine("src/  docs/", color: previewColor(4)) // Blue-ish
                    miniTerminalLine("$ git status", color: Color(theme.foreground))
                    miniTerminalLine("✓ clean", color: previewColor(2)) // Green-ish
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(theme.background))
                
                // Theme Name
                HStack {
                    Text(theme.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func previewColor(_ index: Int) -> Color {
        guard let palette = theme.ansi16Palette, index < palette.count else {
            let fallback: [Color] = [.black, .red, .green, .yellow, .blue, .purple, .cyan, .white]
            return index < fallback.count ? fallback[index] : Color(theme.foreground)
        }
        let c = palette[index]
        return Color(
            red: Double(c.red) / 65535.0,
            green: Double(c.green) / 65535.0,
            blue: Double(c.blue) / 65535.0
        )
    }
    
    private func miniTerminalLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(color)
    }
}

// MARK: - Color Swatch

struct ColorSwatch: View {
    let color: Color
    let label: String
    let isLarge: Bool
    
    @State private var isHovering = false
    
    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: isLarge ? 8 : 6)
                .fill(color)
                .frame(width: isLarge ? 60 : 36, height: isLarge ? 36 : 24)
                .overlay(
                    RoundedRectangle(cornerRadius: isLarge ? 8 : 6)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: color.opacity(0.3), radius: isHovering ? 4 : 0)
                .scaleEffect(isHovering ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)
            
            if isLarge || isHovering {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: isLarge ? 60 : 36)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Appearance Mode Card

struct AppearanceModeCard: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Mini App Preview
                appPreview
                    .frame(height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                
                // Mode Name and Icon
                HStack(spacing: 6) {
                    Image(systemName: mode.icon)
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                    
                    Text(mode.rawValue)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))
            }
            .frame(maxWidth: .infinity)
            .background(previewBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .shadow(color: isSelected ? Color.accentColor.opacity(0.2) : Color.clear, radius: isHovered ? 8 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
    
    private var previewBackground: Color {
        switch mode {
        case .light: return Color(white: 0.97)
        case .dark: return Color(white: 0.12)
        case .system: return Color.primary.opacity(0.03)
        }
    }
    
    @ViewBuilder
    private var appPreview: some View {
        switch mode {
        case .light:
            lightModePreview
        case .dark:
            darkModePreview
        case .system:
            systemModePreview
        }
    }
    
    // Light mode preview - shows a mini app window in light theme
    private var lightModePreview: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 24, height: 6)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 24, height: 6)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.06))
                    .frame(width: 24, height: 6)
                Spacer()
            }
            .padding(6)
            .frame(width: 36)
            .background(Color(white: 0.94))
            
            // Main content
            VStack(spacing: 4) {
                // Terminal area
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Circle().fill(Color.red.opacity(0.7)).frame(width: 4, height: 4)
                        Circle().fill(Color.yellow.opacity(0.7)).frame(width: 4, height: 4)
                        Circle().fill(Color.green.opacity(0.7)).frame(width: 4, height: 4)
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.black.opacity(0.6))
                        .frame(width: 30, height: 3)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.green.opacity(0.5))
                        .frame(width: 20, height: 3)
                }
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .padding(6)
            .background(Color(white: 0.98))
        }
        .background(Color(white: 0.92))
    }
    
    // Dark mode preview - shows a mini app window in dark theme
    private var darkModePreview: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 24, height: 6)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.blue.opacity(0.4))
                    .frame(width: 24, height: 6)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 24, height: 6)
                Spacer()
            }
            .padding(6)
            .frame(width: 36)
            .background(Color(white: 0.12))
            
            // Main content
            VStack(spacing: 4) {
                // Terminal area
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Circle().fill(Color.red.opacity(0.8)).frame(width: 4, height: 4)
                        Circle().fill(Color.yellow.opacity(0.8)).frame(width: 4, height: 4)
                        Circle().fill(Color.green.opacity(0.8)).frame(width: 4, height: 4)
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 30, height: 3)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.green.opacity(0.7))
                        .frame(width: 20, height: 3)
                }
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .padding(6)
            .background(Color(white: 0.15))
        }
        .background(Color(white: 0.1))
    }
    
    // System mode preview - split view showing both themes
    private var systemModePreview: some View {
        HStack(spacing: 0) {
            // Light half
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    Circle().fill(Color.red.opacity(0.7)).frame(width: 3, height: 3)
                    Circle().fill(Color.yellow.opacity(0.7)).frame(width: 3, height: 3)
                    Circle().fill(Color.green.opacity(0.7)).frame(width: 3, height: 3)
                    Spacer()
                }
                Spacer()
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 25, height: 3)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.green.opacity(0.5))
                    .frame(width: 16, height: 3)
            }
            .padding(4)
            .background(Color(white: 0.96))
            
            // Diagonal divider representation
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.9), Color(white: 0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 2)
            
            // Dark half
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    Circle().fill(Color.red.opacity(0.8)).frame(width: 3, height: 3)
                    Circle().fill(Color.yellow.opacity(0.8)).frame(width: 3, height: 3)
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 3, height: 3)
                    Spacer()
                }
                Spacer()
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 25, height: 3)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.green.opacity(0.7))
                    .frame(width: 16, height: 3)
            }
            .padding(4)
            .background(Color(white: 0.1))
        }
        .overlay(
            // System icon overlay
            Image(systemName: "gear")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
        )
    }
}

// MARK: - Terminal Bell Mode Card

struct TerminalBellModeCard: View {
    let mode: TerminalBellMode
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Bell Icon Preview
                bellPreview
                    .frame(height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                
                // Mode Name and Icon
                HStack(spacing: 6) {
                    Image(systemName: mode.icon)
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                    
                    Text(mode.rawValue)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))
            }
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .shadow(color: isSelected ? Color.accentColor.opacity(0.2) : Color.clear, radius: isHovered ? 8 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
    
    @ViewBuilder
    private var bellPreview: some View {
        VStack(spacing: 4) {
            // Large icon
            Image(systemName: mode.icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(iconColor)
            
            // Description
            Text(mode.description)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
    }
    
    private var iconColor: Color {
        switch mode {
        case .sound: return .orange
        case .visual: return .yellow
        case .off: return .secondary
        }
    }
    
    private var backgroundColor: Color {
        switch mode {
        case .sound: return Color.orange.opacity(0.1)
        case .visual: return Color.yellow.opacity(0.1)
        case .off: return Color.primary.opacity(0.03)
        }
    }
}
