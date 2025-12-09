import SwiftUI
// MARK: - Data Settings View
struct DataSettingsView: View {
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var planManager = PlanManager.shared
    @State private var showFactoryResetConfirmation = false
    @State private var showClearHistoryConfirmation = false
    @State private var showClearPlansConfirmation = false
    @State private var factoryResetError: String?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Data Location Section
                dataLocationSection
                
                // Chat History Section
                chatHistorySection
                
                // Plan History Section
                planHistorySection
                
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
        .alert("Clear Plan History", isPresented: $showClearPlansConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                Task { @MainActor in
                    PlanManager.shared.clearAllPlans()
                }
            }
        } message: {
            Text("Are you sure you want to clear all implementation plans? This cannot be undone.")
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
    
    // MARK: - Plan History Section
    private var planHistorySection: some View {
        let navigatorColor = Color(red: 0.7, green: 0.4, blue: 0.9)
        
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Implementation Plans", subtitle: "Plans created by Navigator mode")
            
            VStack(alignment: .leading, spacing: 12) {
                // Plans list
                if planManager.plans.isEmpty {
                    HStack {
                        Image(systemName: "map")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No plans yet")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Use Navigator mode to create implementation plans for your projects.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                    }
                    .padding(12)
                } else {
                    // Plan count and clear button
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(planManager.plans.count) Implementation Plan\(planManager.plans.count == 1 ? "" : "s")")
                                .font(.system(size: 13, weight: .medium))
                            Text("Plans created by Navigator mode to guide Copilot/Pilot implementations.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button(action: { showClearPlansConfirmation = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                Text("Clear All")
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
                    
                    Divider()
                    
                    // Plans list (most recent first, limited to 10)
                    ForEach(planManager.plans.prefix(10)) { plan in
                        PlanHistoryRow(plan: plan, navigatorColor: navigatorColor)
                    }
                    
                    if planManager.plans.count > 10 {
                        Text("+ \(planManager.plans.count - 10) more plans")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
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
                                Label("Implementation plans", systemImage: "map")
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

// MARK: - Plan History Row

private struct PlanHistoryRow: View {
    let plan: Plan
    let navigatorColor: Color
    
    @State private var isHovering = false
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter
    }()
    
    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            ZStack {
                Circle()
                    .fill(plan.status.color.opacity(0.15))
                    .frame(width: 28, height: 28)
                
                Image(systemName: plan.status.icon)
                    .font(.system(size: 12))
                    .foregroundColor(plan.status.color)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: plan.createdDate))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    if plan.checklistItemCount > 0 {
                        Text("\(plan.completedItemCount)/\(plan.checklistItemCount) items")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    
                    Text(plan.status.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(plan.status.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(plan.status.color.opacity(0.1))
                        )
                }
            }
            
            Spacer()
            
            // Action buttons (shown on hover)
            if isHovering {
                HStack(spacing: 8) {
                    // View button
                    Button(action: { openPlan() }) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundColor(navigatorColor)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(navigatorColor.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("View plan")
                    
                    // Delete button
                    Button(action: { deletePlan() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.red.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("Delete plan")
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.primary.opacity(0.03) : Color.clear)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
    
    private func openPlan() {
        // Post notification to open plan in editor
        NotificationCenter.default.post(
            name: .TermAIOpenPlanInEditor,
            object: nil,
            userInfo: ["planId": plan.id]
        )
    }
    
    private func deletePlan() {
        Task { @MainActor in
            PlanManager.shared.deletePlan(id: plan.id)
        }
    }
}
