import SwiftUI

struct SettingsRootView: View {
    var selectedSession: ChatSession?
    @ObservedObject var ptyModel: PTYModel
    @State private var selectedTab: SettingsTab = .chatModel
    
    enum SettingsTab: String, CaseIterable {
        case chatModel = "Chat & Model"
        case providers = "Providers"
        case agent = "Agent"
        case favorites = "Favorites"
        case appearance = "Appearance"
        case usage = "Usage"
        case data = "Data"
        
        var icon: String {
            switch self {
            case .chatModel: return "message.fill"
            case .providers: return "server.rack"
            case .agent: return "cpu"
            case .favorites: return "star.fill"
            case .appearance: return "paintbrush.fill"
            case .usage: return "chart.bar.fill"
            case .data: return "externaldrive.fill"
            }
        }
    }

    var body: some View {
        HSplitView {
            // Sidebar
            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsTabButton(
                        title: tab.rawValue,
                        icon: tab.icon,
                        isSelected: selectedTab == tab
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    }
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 180)
            .background(Color.primary.opacity(0.02))
            
            // Content
            Group {
                switch selectedTab {
                case .chatModel:
                    if let session = selectedSession {
                        SessionSettingsView(session: session)
                    } else {
                        NoSessionPlaceholder()
                    }
                case .providers:
                    ProvidersSettingsView()
                case .agent:
                    AgentSettingsView()
                case .favorites:
                    FavoritesSettingsView()
                case .appearance:
                    AppearanceSettingsView(ptyModel: ptyModel)
                case .usage:
                    UsageSettingsView()
                case .data:
                    DataSettingsView()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

// MARK: - Settings Tab Button
struct SettingsTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                
                Spacer()
            }
            .foregroundColor(isSelected ? .accentColor : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - No Session Placeholder
struct NoSessionPlaceholder: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No Chat Session")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.secondary)
            
            Text("Create or select a chat session to configure its model settings.")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

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
                
                // Terminal Theme Selection Grid
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
    
    // MARK: - Terminal Theme Selection Grid
    private var themeSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Terminal Theme", subtitle: "Choose a color scheme for your terminal")
            
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

// MARK: - Providers Settings View
struct ProvidersSettingsView: View {
    @ObservedObject private var apiKeyManager = CloudAPIKeyManager.shared
    @ObservedObject private var agentSettings = AgentSettings.shared
    @Environment(\.colorScheme) var colorScheme
    
    // Connection testing state for each local provider
    @State private var ollamaStatus: ConnectionStatus = .unknown
    @State private var lmStudioStatus: ConnectionStatus = .unknown
    @State private var vllmStatus: ConnectionStatus = .unknown
    @State private var isTestingOllama = false
    @State private var isTestingLMStudio = false
    @State private var isTestingVLLM = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Cloud Providers Section
                cloudProvidersSection
                
                // Local Providers Section
                localProvidersSection
            }
            .padding(24)
        }
        .frame(minWidth: 500)
    }
    
    // MARK: - Cloud Providers Section
    private var cloudProvidersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Cloud Providers", subtitle: "Configure API keys for cloud AI services")
            
            VStack(spacing: 16) {
                // OpenAI
                cloudProviderCard(for: .openai)
                
                Divider()
                
                // Anthropic
                cloudProviderCard(for: .anthropic)
                
                Divider()
                
                // Google AI Studio
                cloudProviderCard(for: .google)
            }
            .settingsCard()
        }
    }
    
    private func cloudProviderCard(for provider: CloudProvider) -> some View {
        let hasEnvKey = apiKeyManager.getEnvironmentKey(for: provider) != nil
        let hasOverride = apiKeyManager.hasOverride(for: provider)
        let isFromEnv = apiKeyManager.isFromEnvironment(for: provider)
        let hasKey = apiKeyManager.hasAPIKey(for: provider)
        
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Provider badge
                ZStack {
                    Circle()
                        .fill(hasKey ? providerColor(for: provider) : Color.gray.opacity(0.2))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: provider.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(hasKey ? .white : .gray)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                    
                    if isFromEnv {
                        Text("Using \(provider.apiKeyEnvVariable)")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    } else if hasOverride {
                        Text("Custom key configured")
                            .font(.system(size: 11))
                            .foregroundColor(.blue)
                    } else {
                        Text("Not configured")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Status indicator
                if hasKey {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Ready")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.1))
                    )
                }
            }
            
            // API Key field
            HStack(spacing: 8) {
                SecureField(
                    hasEnvKey ? "Override environment variable..." : "Enter API key...",
                    text: Binding(
                        get: { apiKeyManager.getOverride(for: provider) ?? "" },
                        set: { apiKeyManager.setOverride($0.isEmpty ? nil : $0, for: provider) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(hasOverride ? providerColor(for: provider).opacity(0.3) : Color.primary.opacity(0.1), lineWidth: 1)
                )
                
                if hasOverride {
                    Button(action: {
                        apiKeyManager.setOverride(nil, for: provider)
                    }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Revert to environment variable")
                }
            }
            
            // Help text
            if hasEnvKey && !hasOverride {
                Text("Using key from environment variable. Enter a value above to override.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else if !hasEnvKey && !hasOverride {
                Text("Set \(provider.apiKeyEnvVariable) environment variable or enter a key above.")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
    }
    
    private func providerColor(for provider: CloudProvider) -> Color {
        switch provider {
        case .openai: return .green
        case .anthropic: return .orange
        case .google: return .blue
        }
    }
    
    // MARK: - Local Providers Section
    private var localProvidersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Local Providers", subtitle: "Configure URLs for local LLM servers")
            
            VStack(spacing: 16) {
                // Ollama
                localProviderCard(
                    provider: .ollama,
                    url: $agentSettings.ollamaBaseURL,
                    status: ollamaStatus,
                    isTesting: isTestingOllama,
                    onTest: testOllama
                )
                
                Divider()
                
                // LM Studio
                localProviderCard(
                    provider: .lmStudio,
                    url: $agentSettings.lmStudioBaseURL,
                    status: lmStudioStatus,
                    isTesting: isTestingLMStudio,
                    onTest: testLMStudio
                )
                
                Divider()
                
                // vLLM
                localProviderCard(
                    provider: .vllm,
                    url: $agentSettings.vllmBaseURL,
                    status: vllmStatus,
                    isTesting: isTestingVLLM,
                    onTest: testVLLM
                )
            }
            .settingsCard()
        }
    }
    
    private func localProviderCard(
        provider: LocalLLMProvider,
        url: Binding<String>,
        status: ConnectionStatus,
        isTesting: Bool,
        onTest: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Provider badge
                ZStack {
                    Circle()
                        .fill(localProviderColor(for: provider))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: provider.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                    
                    Text("Default: \(provider.defaultBaseURL.absoluteString)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Connection status
                ConnectionStatusBadge(status: status)
            }
            
            // URL field
            HStack(spacing: 8) {
                TextField("API URL", text: url)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .onChange(of: url.wrappedValue) { _ in
                        agentSettings.save()
                    }
                
                // Test button
                Button(action: onTest) {
                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 12))
                            .foregroundColor(.accentColor)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(0.1))
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(isTesting)
                .help("Test connection")
                
                // Reset to default
                if url.wrappedValue != provider.defaultBaseURL.absoluteString {
                    Button(action: {
                        url.wrappedValue = provider.defaultBaseURL.absoluteString
                        agentSettings.save()
                    }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Reset to default URL")
                }
            }
            
            // Connection error
            if case .disconnected(let error) = status {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
            }
        }
    }
    
    private func localProviderColor(for provider: LocalLLMProvider) -> Color {
        switch provider {
        case .ollama: return .blue
        case .lmStudio: return .purple
        case .vllm: return .orange
        }
    }
    
    // MARK: - Connection Testing
    
    private func testOllama() {
        testLocalProvider(.ollama, status: $ollamaStatus, isTesting: $isTestingOllama)
    }
    
    private func testLMStudio() {
        testLocalProvider(.lmStudio, status: $lmStudioStatus, isTesting: $isTestingLMStudio)
    }
    
    private func testVLLM() {
        testLocalProvider(.vllm, status: $vllmStatus, isTesting: $isTestingVLLM)
    }
    
    private func testLocalProvider(_ provider: LocalLLMProvider, status: Binding<ConnectionStatus>, isTesting: Binding<Bool>) {
        isTesting.wrappedValue = true
        status.wrappedValue = .checking
        
        Task {
            defer {
                Task { @MainActor in
                    isTesting.wrappedValue = false
                }
            }
            
            do {
                let models = try await LocalProviderService.fetchModels(for: provider)
                await MainActor.run {
                    status.wrappedValue = .connected(modelCount: models.count)
                }
            } catch {
                await MainActor.run {
                    status.wrappedValue = .disconnected(error: error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Agent Settings View
struct AgentSettingsView: View {
    @ObservedObject private var settings = AgentSettings.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var showResetConfirmation = false
    @State private var newBlockedPattern: String = ""
    @State private var isBlockedCommandsExpanded: Bool = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Default Behavior Section
                defaultBehaviorSection
                
                // Execution Limits Section
                executionLimitsSection
                
                // Planning & Reflection Section
                planningReflectionSection
                
                // Context & Memory Section
                contextMemorySection
                
                // Output Handling Section
                outputHandlingSection
                
                // Safety Section
                safetySection
                
                // Test Runner Section
                testRunnerSection
                
                // Advanced Section
                advancedSection
                
                // Reset Button
                resetSection
            }
            .padding(24)
        }
        .frame(minWidth: 500)
        .onChange(of: settings.defaultAgentMode) { _ in settings.save() }
        .onChange(of: settings.defaultAgentProfile) { _ in settings.save() }
        .onChange(of: settings.maxIterations) { _ in settings.save() }
        .onChange(of: settings.maxToolCallsPerStep) { _ in settings.save() }
        .onChange(of: settings.maxFixAttempts) { _ in settings.save() }
        .onChange(of: settings.commandTimeout) { _ in settings.save() }
        // Dynamic context settings
        .onChange(of: settings.outputCapturePercent) { _ in settings.save() }
        .onChange(of: settings.agentMemoryPercent) { _ in settings.save() }
        .onChange(of: settings.maxOutputCaptureCap) { _ in settings.save() }
        .onChange(of: settings.maxAgentMemoryCap) { _ in settings.save() }
        .onChange(of: settings.minOutputCapture) { _ in settings.save() }
        .onChange(of: settings.minContextSize) { _ in settings.save() }
        // Legacy (kept for compatibility)
        .onChange(of: settings.maxOutputCapture) { _ in settings.save() }
        .onChange(of: settings.maxContextSize) { _ in settings.save() }
        .onChange(of: settings.outputSummarizationThreshold) { _ in settings.save() }
        .onChange(of: settings.enableOutputSummarization) { _ in settings.save() }
        .onChange(of: settings.maxFullOutputBuffer) { _ in settings.save() }
        .onChange(of: settings.enablePlanning) { _ in settings.save() }
        .onChange(of: settings.reflectionInterval) { _ in settings.save() }
        .onChange(of: settings.enableReflection) { _ in settings.save() }
        .onChange(of: settings.stuckDetectionThreshold) { _ in settings.save() }
        .onChange(of: settings.requireCommandApproval) { _ in settings.save() }
        .onChange(of: settings.autoApproveReadOnly) { _ in settings.save() }
        .onChange(of: settings.requireFileEditApproval) { _ in settings.save() }
        .onChange(of: settings.enableApprovalNotifications) { newValue in
            settings.save()
            // Request notification permissions when enabling
            if newValue {
                SystemNotificationService.shared.requestAuthorization()
            }
        }
        .onChange(of: settings.enableApprovalNotificationSound) { _ in settings.save() }
        .onChange(of: settings.verboseLogging) { _ in settings.save() }
        .onChange(of: settings.testRunnerEnabled) { _ in settings.save() }
        .alert("Reset Agent Settings", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
            }
        } message: {
            Text("Are you sure you want to reset all agent settings to their default values?")
        }
    }
    
    // MARK: - Default Behavior Section
    private var defaultBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Default Behavior", subtitle: "Control how new chat sessions behave")
            
            VStack(spacing: 16) {
                // Default Agent Mode
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default Agent Mode")
                            .font(.system(size: 13, weight: .medium))
                        Text("The agent mode that new chat sessions will start with.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Picker("", selection: $settings.defaultAgentMode) {
                        ForEach(AgentMode.allCases, id: \.self) { mode in
                            HStack(spacing: 6) {
                                Image(systemName: mode.icon)
                                    .foregroundColor(mode.color)
                                Text(mode.rawValue)
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
                
                // Mode descriptions
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AgentMode.allCases, id: \.self) { mode in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 11))
                                .foregroundColor(mode.color)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                                Text(mode.detailedDescription)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 8)
                
                Divider()
                
                // Default Agent Profile
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default Agent Profile")
                            .font(.system(size: 13, weight: .medium))
                        Text("The task profile that new chat sessions will start with.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Picker("", selection: $settings.defaultAgentProfile) {
                        ForEach(AgentProfile.allCases, id: \.self) { profile in
                            HStack(spacing: 6) {
                                Image(systemName: profile.icon)
                                    .foregroundColor(profile.color)
                                Text(profile.rawValue)
                            }
                            .tag(profile)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
                
                // Profile descriptions
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AgentProfile.allCases, id: \.self) { profile in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: profile.icon)
                                .font(.system(size: 11))
                                .foregroundColor(profile.color)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                                Text(profile.detailedDescription)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
            .settingsCard()
        }
    }
    
    // MARK: - Execution Limits Section
    private var executionLimitsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Execution Limits", subtitle: "Control how the agent executes commands")
            
            VStack(spacing: 16) {
                // Max Iterations
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Maximum Steps")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        TextField("", value: Binding(
                            get: { settings.maxIterations },
                            set: { settings.maxIterations = max(0, min(500, $0)) }
                        ), format: .number)
                        .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxIterations) },
                        set: { settings.maxIterations = Int($0) }
                    ), in: 0...500, step: 10)
                    
                    Text("Maximum number of steps (0 = unlimited). Recommended: 50-200 for complex tasks.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Max Tool Calls Per Step
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tool Calls Per Step")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        TextField("", value: Binding(
                            get: { settings.maxToolCallsPerStep },
                            set: { settings.maxToolCallsPerStep = max(10, min(500, $0)) }
                        ), format: .number)
                        .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxToolCallsPerStep) },
                        set: { settings.maxToolCallsPerStep = Int($0) }
                    ), in: 10...500, step: 10)
                    
                    Text("Maximum tool calls within a single step. Increase for complex multi-tool operations.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Max Fix Attempts
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Maximum Fix Attempts")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(settings.maxFixAttempts)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxFixAttempts) },
                        set: { settings.maxFixAttempts = Int($0) }
                    ), in: 1...10, step: 1)
                    
                    Text("How many times the agent will try to fix a failed command.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Command Timeout
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Command Timeout")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(formatTimeout(settings.commandTimeout))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $settings.commandTimeout, in: 30...3600, step: 30)
                    
                    Text("Default wait time for command output. Agent can override per-command for long tasks. Recommended: 5-10 minutes.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .settingsCard()
        }
    }
    
    // MARK: - Planning & Reflection Section
    private var planningReflectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Planning & Reflection", subtitle: "Control how the agent plans and reviews progress")
            
            VStack(spacing: 16) {
                // Enable Planning
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Planning Phase")
                            .font(.system(size: 13, weight: .medium))
                        Text("Generate a step-by-step plan before executing commands.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.enablePlanning)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                Divider()
                
                // Enable Reflection
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Periodic Reflection")
                            .font(.system(size: 13, weight: .medium))
                        Text("Pause to assess progress and adjust approach if needed.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.enableReflection)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                if settings.enableReflection {
                    // Reflection Interval
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Reflection Interval")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("Every \(settings.reflectionInterval) steps")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: Binding(
                            get: { Double(settings.reflectionInterval) },
                            set: { settings.reflectionInterval = Int($0) }
                        ), in: 3...25, step: 1)
                        
                        Text("How often the agent pauses to review progress.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                // Stuck Detection
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Stuck Detection Threshold")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(settings.stuckDetectionThreshold) similar commands")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.stuckDetectionThreshold) },
                        set: { settings.stuckDetectionThreshold = Int($0) }
                    ), in: 2...10, step: 1)
                    
                    Text("Trigger a strategy change after this many similar failed commands.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .settingsCard()
            .animation(.easeInOut(duration: 0.2), value: settings.enableReflection)
        }
    }
    
    // MARK: - Context & Memory Section
    private var contextMemorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Context Budget", subtitle: "Dynamic allocation based on model's context window")
            
            VStack(spacing: 16) {
                // Info about dynamic scaling
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text("Context limits scale automatically with your model's capabilities. A 128K model gets much more context than a 4K model.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
                
                Divider()
                
                // Per-Output Capture Percent
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Per-Output Capture")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(Int(settings.outputCapturePercent * 100))% of context")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $settings.outputCapturePercent, in: 0.05...0.30, step: 0.01)
                    
                    HStack {
                        Text("How much of the model's context each file read or command output can use.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Min: \(formatChars(settings.minOutputCapture))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                
                Divider()
                
                // Agent Memory Percent
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Agent Working Memory")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(Int(settings.agentMemoryPercent * 100))% of context")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $settings.agentMemoryPercent, in: 0.20...0.60, step: 0.05)
                    
                    HStack {
                        Text("Total context budget for the agent's accumulated memory during long tasks.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Min: \(formatChars(settings.minContextSize))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                
                Divider()
                
                // Example allocation display
                contextBudgetExample
            }
            .settingsCard()
            
            // Advanced limits (collapsed by default)
            DisclosureGroup("Advanced Limits") {
                VStack(spacing: 12) {
                    // Hard caps
                    HStack {
                        Text("Output Capture Cap")
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(formatChars(settings.maxOutputCaptureCap))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxOutputCaptureCap) },
                        set: { settings.maxOutputCaptureCap = Int($0) }
                    ), in: 20000...100000, step: 5000)
                    
                    Divider()
                    
                    HStack {
                        Text("Agent Memory Cap")
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(formatChars(settings.maxAgentMemoryCap))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxAgentMemoryCap) },
                        set: { settings.maxAgentMemoryCap = Int($0) }
                    ), in: 50000...200000, step: 10000)
                    
                    Text("Hard limits prevent excessive memory use even with very large context models.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .padding(.top, 8)
            }
            .settingsCard()
        }
    }
    
    // MARK: - Context Budget Example
    private var contextBudgetExample: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Example Allocations")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            
            HStack(spacing: 16) {
                contextExampleColumn(modelName: "32K Model", tokens: 32_000)
                Divider().frame(height: 50)
                contextExampleColumn(modelName: "128K Model", tokens: 128_000)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(6)
        }
    }
    
    private func contextExampleColumn(modelName: String, tokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(modelName)
                .font(.system(size: 11, weight: .semibold))
            
            let outputLimit = settings.effectiveOutputCaptureLimit(forContextTokens: tokens)
            let memoryLimit = settings.effectiveAgentMemoryLimit(forContextTokens: tokens)
            
            Text("Per-output: \(formatChars(outputLimit))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            
            Text("Memory: \(formatChars(memoryLimit))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func formatChars(_ chars: Int) -> String {
        if chars >= 1000 {
            return "\(chars / 1000)K"
        }
        return "\(chars)"
    }
    
    private func formatTimeout(_ seconds: TimeInterval) -> String {
        let secs = Int(seconds)
        if secs >= 3600 {
            let hours = secs / 3600
            let mins = (secs % 3600) / 60
            if mins > 0 {
                return "\(hours)h \(mins)m"
            }
            return "\(hours)h"
        } else if secs >= 60 {
            let mins = secs / 60
            let remainingSecs = secs % 60
            if remainingSecs > 0 {
                return "\(mins)m \(remainingSecs)s"
            }
            return "\(mins)m"
        }
        return "\(secs)s"
    }
    
    // MARK: - Output Handling Section
    private var outputHandlingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Long Output Handling", subtitle: "Control how large terminal outputs are processed")
            
            VStack(spacing: 16) {
                // Enable Output Summarization
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Output Summarization")
                            .font(.system(size: 13, weight: .medium))
                        Text("Automatically summarize long command outputs to preserve context.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.enableOutputSummarization)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                if settings.enableOutputSummarization {
                    Divider()
                    
                    // Summarization Threshold
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Summarization Threshold")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("\(settings.outputSummarizationThreshold) chars")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: Binding(
                            get: { Double(settings.outputSummarizationThreshold) },
                            set: { settings.outputSummarizationThreshold = Int($0) }
                        ), in: 1000...20000, step: 1000)
                        
                        Text("Outputs longer than this will be summarized to preserve key information.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                // Full Output Buffer
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Full Output Buffer")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(settings.maxFullOutputBuffer / 1000)K chars")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxFullOutputBuffer) },
                        set: { settings.maxFullOutputBuffer = Int($0) }
                    ), in: 10000...100000, step: 10000)
                    
                    Text("Full outputs are stored up to this size for search and reference.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .settingsCard()
            .animation(.easeInOut(duration: 0.2), value: settings.enableOutputSummarization)
        }
    }
    
    // MARK: - Safety Section
    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Safety", subtitle: "Control command execution approval")
            
            VStack(spacing: 16) {
                // Require Command Approval
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Require Command Approval")
                            .font(.system(size: 13, weight: .medium))
                        Text("Ask for confirmation before executing each command.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.requireCommandApproval)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                if settings.requireCommandApproval {
                    Divider()
                    
                    // Auto-approve Read-Only
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto-Approve Read-Only Commands")
                                .font(.system(size: 13, weight: .medium))
                            Text("Automatically approve safe commands like ls, cat, git status, etc.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: $settings.autoApproveReadOnly)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                
                Divider()
                
                // Require File Edit Approval
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Require File Edit Approval")
                            .font(.system(size: 13, weight: .medium))
                        Text("Show a diff preview and ask for confirmation before modifying files.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.requireFileEditApproval)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                Divider()
                
                // System Notifications
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("System Notifications")
                            .font(.system(size: 13, weight: .medium))
                        Text("Show macOS notifications when approvals are needed while you're away.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.enableApprovalNotifications)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                if settings.enableApprovalNotifications {
                    // Notification Sound
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Text("Notification Sound")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            Text("Play a sound when approval notifications appear.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: $settings.enableApprovalNotificationSound)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .padding(.leading, 16)
                }
            }
            .settingsCard()
            .animation(.easeInOut(duration: 0.2), value: settings.requireCommandApproval)
            .animation(.easeInOut(duration: 0.2), value: settings.enableApprovalNotifications)
            
            // Command Blocklist Section
            commandBlocklistSection
        }
    }
    
    // MARK: - Command Blocklist Section
    private var commandBlocklistSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Blocked Commands", subtitle: "Commands that always require approval, regardless of other settings")
            
            VStack(spacing: 16) {
                // Info callout
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                    
                    Text("These command patterns will always require your approval before execution. This helps prevent accidental data loss or system changes.")
                        .font(.system(size: 12))
                        .foregroundColor(.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
                
                // Add new pattern
                HStack(spacing: 8) {
                    TextField("Add command pattern (e.g., npm publish)", text: $newBlockedPattern)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        .onSubmit {
                            addNewBlockedPattern()
                        }
                    
                    Button(action: addNewBlockedPattern) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(newBlockedPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                
                Divider()
                
                // Collapsible blocked patterns list
                VStack(spacing: 0) {
                    // Header button to expand/collapse
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isBlockedCommandsExpanded.toggle()
                        }
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: isBlockedCommandsExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 12)
                            
                            Text("Blocked Patterns")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            
                            // Count badge
                            Text("\(settings.blockedCommandPatterns.count)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.orange)
                                )
                            
                            Spacer()
                            
                            Text(isBlockedCommandsExpanded ? "Hide" : "Show")
                                .font(.system(size: 11))
                                .foregroundColor(.accentColor)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    
                    // Expandable list
                    if isBlockedCommandsExpanded {
                        if settings.blockedCommandPatterns.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "checkmark.shield")
                                        .font(.system(size: 24))
                                        .foregroundColor(.secondary.opacity(0.5))
                                    Text("No blocked commands")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 20)
                                Spacer()
                            }
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(settings.blockedCommandPatterns.enumerated()), id: \.offset) { index, pattern in
                                    HStack(spacing: 12) {
                                        Image(systemName: "xmark.octagon.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(.red.opacity(0.7))
                                        
                                        Text(pattern)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(.primary)
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            settings.removeBlockedPattern(pattern)
                                        }) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove this pattern")
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        index % 2 == 0 
                                            ? Color.clear 
                                            : Color.primary.opacity(0.02)
                                    )
                                    
                                    if index < settings.blockedCommandPatterns.count - 1 {
                                        Divider()
                                            .padding(.leading, 36)
                                    }
                                }
                            }
                            .padding(.top, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.02))
                            )
                        }
                        
                        // Reset to defaults button (inside expanded area)
                        HStack {
                            Spacer()
                            
                            Button(action: {
                                settings.resetBlockedPatternsToDefaults()
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 11))
                                    Text("Reset to Defaults")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Restore the default blocked command patterns")
                        }
                        .padding(.top, 12)
                    }
                }
            }
            .settingsCard()
            .animation(.easeInOut(duration: 0.2), value: isBlockedCommandsExpanded)
        }
    }
    
    private func addNewBlockedPattern() {
        let trimmed = newBlockedPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.addBlockedPattern(trimmed)
        newBlockedPattern = ""
    }
    
    // MARK: - Test Runner Section
    private var testRunnerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Test Runner", subtitle: "Automated test detection and execution")
            
            VStack(spacing: 16) {
                // Enable Test Runner
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Test Runner")
                            .font(.system(size: 13, weight: .medium))
                        Text("Show the Test Runner button in the chat toolbar to analyze and run project tests.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.testRunnerEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            .settingsCard()
        }
    }
    
    // MARK: - Advanced Section
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Advanced", subtitle: "Developer and debugging options")
            
            VStack(spacing: 16) {
                // Verbose Logging
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Verbose Logging")
                            .font(.system(size: 13, weight: .medium))
                        Text("Log detailed agent operations to the console (for debugging).")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.verboseLogging)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            .settingsCard()
        }
    }
    
    // MARK: - Reset Section
    private var resetSection: some View {
        HStack {
            Spacer()
            
            Button(action: { showResetConfirmation = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12))
                    Text("Reset to Defaults")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Data Settings View
struct DataSettingsView: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var showFactoryResetConfirmation = false
    @State private var showClearHistoryConfirmation = false
    @State private var factoryResetError: String?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Data Location Section
                dataLocationSection
                
                // Chat History Section
                chatHistorySection
                
                // Factory Reset Section
                factoryResetSection
            }
            .padding(24)
        }
        .frame(minWidth: 500)
        .alert("Clear Chat History", isPresented: $showClearHistoryConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                Task { @MainActor in
                    ChatHistoryManager.shared.clearAllEntries()
                }
            }
        } message: {
            Text("Are you sure you want to clear all chat history? Active sessions will not be affected.")
        }
        .alert("Factory Reset", isPresented: $showFactoryResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset & Quit", role: .destructive) {
                performFactoryReset()
            }
        } message: {
            Text("This will delete ALL TermAI data including:\n\n- All chat sessions and messages\n- All settings and preferences\n- Token usage statistics\n- Chat history\n\nThe app will quit after reset. This cannot be undone.")
        }
        .alert("Reset Failed", isPresented: Binding(
            get: { factoryResetError != nil },
            set: { if !$0 { factoryResetError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(factoryResetError ?? "An unknown error occurred.")
        }
    }
    
    // MARK: - Data Location Section
    private var dataLocationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Data Location", subtitle: "Where TermAI stores your data")
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                    
                    Text(dataPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Button(action: openDataFolder) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 11))
                            Text("Open in Finder")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                
                Text("This folder contains all your chat sessions, settings, and usage data.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
            )
        }
    }
    
    // MARK: - Chat History Section
    private var chatHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Chat History", subtitle: "Archived chat sessions")
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clear Chat History")
                        .font(.system(size: 13, weight: .medium))
                    Text("Remove all archived chat sessions. Active sessions will not be affected.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { showClearHistoryConfirmation = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                        Text("Clear History")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
            )
        }
    }
    
    // MARK: - Factory Reset Section
    private var factoryResetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Factory Reset", subtitle: "Start fresh with a clean slate")
            
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.red)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reset All Data")
                            .font(.system(size: 14, weight: .semibold))
                        
                        Text("This will permanently delete all TermAI data and quit the app. When you relaunch, TermAI will start fresh as if it was just installed.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What will be deleted:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            
                            Group {
                                Label("All chat sessions and messages", systemImage: "bubble.left.and.bubble.right")
                                Label("All settings and preferences", systemImage: "gearshape")
                                Label("Token usage statistics", systemImage: "chart.bar")
                                Label("Chat history archive", systemImage: "clock.arrow.circlepath")
                                Label("Provider API key overrides", systemImage: "key")
                            }
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                        }
                        .padding(.top, 4)
                    }
                }
                
                HStack {
                    Spacer()
                    
                    Button(action: { showFactoryResetConfirmation = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 12))
                            Text("Factory Reset")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
            )
        }
    }
    
    // MARK: - Helpers
    
    private var dataPath: String {
        (try? PersistenceService.appSupportDirectory().path) ?? "~/Library/Application Support/TermAI"
    }
    
    private func openDataFolder() {
        if let url = try? PersistenceService.appSupportDirectory() {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func performFactoryReset() {
        do {
            try PersistenceService.clearAllData()
            // Quit immediately to prevent any background saves from recreating files
            NSApplication.shared.terminate(nil)
        } catch {
            factoryResetError = error.localizedDescription
        }
    }
}
