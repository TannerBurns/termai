import SwiftUI
import AppKit
import TermAIModels

// MARK: - File Diff Approval Sheet

/// Modal sheet for approving file changes with diff preview
/// Supports per-hunk accept/reject for granular control over changes
struct FileChangeApprovalSheet: View {
    let approval: PendingFileChangeApproval
    let onApprove: () -> Void
    let onReject: () -> Void
    
    /// Optional callback for partial approval with hunk decisions
    var onPartialApprove: (([UUID: HunkDecision], String) -> Void)? = nil
    
    @Environment(\.colorScheme) var colorScheme
    @State private var diff: FileDiff?
    @State private var hunkDecisions: [UUID: HunkDecision] = [:]
    
    private var theme: DiffTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    /// Whether any hunks have been decided (not pending)
    private var hasHunkDecisions: Bool {
        !hunkDecisions.isEmpty && hunkDecisions.values.contains(where: { $0 != .pending })
    }
    
    /// Whether all hunks are rejected
    private var allHunksRejected: Bool {
        guard let diff = diff, !diff.hunks.isEmpty else { return false }
        return diff.hunks.allSatisfy { hunkDecisions[$0.id] == .rejected }
    }
    
    /// Whether all hunks are accepted (or pending - default to accept)
    private var allHunksAccepted: Bool {
        guard let diff = diff, !diff.hunks.isEmpty else { return true }
        return diff.hunks.allSatisfy { hunkDecisions[$0.id] != .rejected }
    }
    
    /// Count of accepted hunks
    private var acceptedHunkCount: Int {
        guard let diff = diff else { return 0 }
        return diff.hunks.filter { hunkDecisions[$0.id] == .accepted || hunkDecisions[$0.id] == nil }.count
    }
    
    /// Count of rejected hunks
    private var rejectedHunkCount: Int {
        guard let diff = diff else { return 0 }
        return diff.hunks.filter { hunkDecisions[$0.id] == .rejected }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
            
            // Diff view with hunk-level actions
            if let diff = diff {
                FileDiffView(
                    fileChange: approval.fileChange,
                    diff: diff,
                    isApprovalMode: true,
                    hunkDecisions: $hunkDecisions
                )
            } else {
                loadingView
            }
            
            Divider()
            
            // Action buttons
            actionButtons
        }
        .frame(minWidth: 700, minHeight: 500)
        .frame(maxWidth: 1000, maxHeight: 700)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            diff = FileDiff(fileChange: approval.fileChange)
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack(spacing: 12) {
            // Warning icon
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundColor(.orange)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("File Change Approval Required")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.foreground)
                
                HStack(spacing: 8) {
                    Text("The agent wants to \(approval.fileChange.operationType.description.lowercased()) this file")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                    
                    // Hunk decision summary
                    if hasHunkDecisions, let diff = diff {
                        Text("•")
                            .foregroundColor(theme.secondaryText)
                        
                        if acceptedHunkCount > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9))
                                Text("\(acceptedHunkCount)")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(theme.addedText)
                        }
                        
                        if rejectedHunkCount > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 9))
                                Text("\(rejectedHunkCount)")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(theme.removedText)
                        }
                    }
                }
            }
            
            Spacer()
            
            // Tool info
            VStack(alignment: .trailing, spacing: 2) {
                Text(approval.toolName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                
                Text(approval.fileChange.fileName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.secondaryText.opacity(0.8))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(theme.headerBackground)
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            
            Text("Computing diff...")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Info text
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                
                if hasHunkDecisions && !allHunksAccepted && !allHunksRejected {
                    Text("Partial approval: \(acceptedHunkCount) hunks will be applied")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                } else {
                    Text("Review the changes above before approving")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
            }
            
            Spacer()
            
            // Reject button (rejects all)
            Button(action: onReject) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Reject All")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            
            // Approve button - handles both full and partial approval
            Button(action: handleApprove) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    
                    if hasHunkDecisions && rejectedHunkCount > 0 && !allHunksRejected {
                        Text("Apply \(acceptedHunkCount) Hunks")
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Text("Approve & Apply")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(allHunksRejected ? Color.gray : Color.green)
                )
            }
            .buttonStyle(.plain)
            .disabled(allHunksRejected)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.headerBackground)
    }
    
    private func handleApprove() {
        guard let diff = diff else {
            onApprove()
            return
        }
        
        // Check if we have partial approval (some hunks rejected)
        let hasRejections = diff.hunks.contains { hunkDecisions[$0.id] == .rejected }
        
        if hasRejections, let partialCallback = onPartialApprove {
            // Generate content with only accepted hunks
            // For hunks without explicit decisions, default to accepted
            var finalDecisions = hunkDecisions
            for hunk in diff.hunks {
                if finalDecisions[hunk.id] == nil {
                    finalDecisions[hunk.id] = .accepted
                }
            }
            
            let modifiedContent = diff.applyPartialHunks(decisions: finalDecisions)
            partialCallback(finalDecisions, modifiedContent)
        } else {
            // Full approval - all hunks accepted
            onApprove()
        }
    }
}

// MARK: - File Diff Detail Sheet

/// Sheet for viewing file changes after they've been applied (non-approval mode)
/// Supports navigation through file change history when provided
struct FileDiffDetailSheet: View {
    @State private var currentFileChange: FileChange
    let onDismiss: () -> Void
    
    /// Optional history for navigation - when provided, shows prev/next buttons
    var history: [DiffHistoryEntry]?
    
    /// Callback when navigating to a different file change
    var onNavigate: ((FileChange) -> Void)?
    
    @Environment(\.colorScheme) var colorScheme
    @State private var diff: FileDiff?
    @State private var showHistoryPanel = false
    
    private var theme: DiffTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    /// Initialize with just a file change (no history navigation)
    init(fileChange: FileChange, onDismiss: @escaping () -> Void) {
        self._currentFileChange = State(initialValue: fileChange)
        self.onDismiss = onDismiss
        self.history = nil
        self.onNavigate = nil
    }
    
    /// Initialize with history for navigation
    init(fileChange: FileChange, history: [DiffHistoryEntry], onDismiss: @escaping () -> Void, onNavigate: ((FileChange) -> Void)? = nil) {
        self._currentFileChange = State(initialValue: fileChange)
        self.onDismiss = onDismiss
        self.history = history
        self.onNavigate = onNavigate
    }
    
    private var currentIndex: Int? {
        history?.firstIndex { $0.fileChange.id == currentFileChange.id }
    }
    
    private var canNavigatePrevious: Bool {
        guard let index = currentIndex else { return false }
        return index > 0
    }
    
    private var canNavigateNext: Bool {
        guard let index = currentIndex, let history = history else { return false }
        return index < history.count - 1
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Main content
            VStack(spacing: 0) {
                // Header with navigation
                header
                
                Divider()
                
                // Diff view
                if let diff = diff {
                    FileDiffView(fileChange: currentFileChange, diff: diff)
                } else {
                    loadingView
                }
                
                Divider()
                
                // Footer
                footer
            }
            
            // History sidebar (when toggled)
            if showHistoryPanel, let history = history, !history.isEmpty {
                Divider()
                historyPanel(history: history)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .frame(maxWidth: showHistoryPanel ? 1200 : 1000, maxHeight: 700)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            diff = FileDiff(fileChange: currentFileChange)
        }
        .onChange(of: currentFileChange.id) { _ in
            diff = FileDiff(fileChange: currentFileChange)
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack(spacing: 12) {
            // Navigation buttons (when history available)
            if history != nil {
                HStack(spacing: 4) {
                    Button(action: navigatePrevious) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(canNavigatePrevious ? .accentColor : theme.secondaryText.opacity(0.3))
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(theme.headerBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canNavigatePrevious)
                    
                    Button(action: navigateNext) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(canNavigateNext ? .accentColor : theme.secondaryText.opacity(0.3))
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(theme.headerBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canNavigateNext)
                }
            }
            
            // Icon
            ZStack {
                Circle()
                    .fill(operationColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: currentFileChange.operationType.icon)
                    .font(.system(size: 18))
                    .foregroundColor(operationColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("File Changes")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.foreground)
                    
                    // Position indicator when history available
                    if let index = currentIndex, let history = history {
                        Text("\(index + 1) of \(history.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(theme.headerBackground)
                            )
                    }
                }
                
                Text(currentFileChange.filePath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            // History toggle button (when history available)
            if let history = history, !history.isEmpty {
                Button(action: { withAnimation { showHistoryPanel.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11))
                        Text("History")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(showHistoryPanel ? .white : .accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(showHistoryPanel ? Color.accentColor : Color.accentColor.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            }
            
            // Close button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(theme.headerBackground)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(theme.headerBackground)
    }
    
    private var operationColor: Color {
        switch currentFileChange.operationType {
        case .create: return .green
        case .edit: return .blue
        case .insert: return .cyan
        case .delete, .deleteFile: return .red
        case .overwrite: return .orange
        }
    }
    
    // MARK: - History Panel
    
    private func historyPanel(history: [DiffHistoryEntry]) -> some View {
        VStack(spacing: 0) {
            // Panel header
            HStack {
                Text("Change History")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.foreground)
                
                Spacer()
                
                Text("\(history.count) changes")
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.panelHeader)
            
            Divider()
            
            // History list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, entry in
                        historyRow(entry: entry, index: index, isSelected: entry.fileChange.id == currentFileChange.id)
                    }
                }
            }
        }
        .frame(width: 260)
        .background(theme.background)
    }
    
    private func historyRow(entry: DiffHistoryEntry, index: Int, isSelected: Bool) -> some View {
        Button(action: { navigateTo(entry: entry) }) {
            HStack(spacing: 10) {
                // Sequence number
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 20)
                
                // Timeline indicator
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(index == 0 ? Color.clear : theme.divider)
                        .frame(width: 2, height: 8)
                    
                    Circle()
                        .fill(isSelected ? Color.accentColor : operationColor(for: entry.fileChange.operationType))
                        .frame(width: 8, height: 8)
                    
                    Rectangle()
                        .fill(index == (history?.count ?? 0) - 1 ? Color.clear : theme.divider)
                        .frame(width: 2, height: 8)
                }
                
                // File info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: entry.fileChange.operationType.icon)
                            .font(.system(size: 9))
                            .foregroundColor(operationColor(for: entry.fileChange.operationType))
                        
                        Text(entry.fileChange.fileName)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? .accentColor : theme.foreground)
                            .lineLimit(1)
                    }
                    
                    Text(entry.formattedTime)
                        .font(.system(size: 9))
                        .foregroundColor(theme.secondaryText)
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }
    
    private func operationColor(for operationType: FileOperationType) -> Color {
        switch operationType {
        case .create: return .green
        case .edit: return .blue
        case .insert: return .cyan
        case .delete, .deleteFile: return .red
        case .overwrite: return .orange
        }
    }
    
    // MARK: - Navigation
    
    private func navigatePrevious() {
        guard let index = currentIndex, index > 0, let history = history else { return }
        let newEntry = history[index - 1]
        currentFileChange = newEntry.fileChange
        onNavigate?(newEntry.fileChange)
    }
    
    private func navigateNext() {
        guard let index = currentIndex, let history = history, index < history.count - 1 else { return }
        let newEntry = history[index + 1]
        currentFileChange = newEntry.fileChange
        onNavigate?(newEntry.fileChange)
    }
    
    private func navigateTo(entry: DiffHistoryEntry) {
        currentFileChange = entry.fileChange
        onNavigate?(entry.fileChange)
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            
            Text("Computing diff...")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Footer
    
    private var footer: some View {
        HStack {
            // Keyboard hint for navigation
            if history != nil && (canNavigatePrevious || canNavigateNext) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 9))
                    Text("Navigate with arrows")
                        .font(.system(size: 10))
                }
                .foregroundColor(theme.secondaryText.opacity(0.7))
            }
            
            Spacer()
            
            // Done button
            Button(action: onDismiss) {
                Text("Done")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.headerBackground)
    }
}

// MARK: - View Changes Button

/// Button to show diff details for a file change
/// Can optionally include approval buttons for pending approvals
struct ViewChangesButton: View {
    let fileChange: FileChange
    /// If set, shows approve/reject buttons in the sheet
    var pendingApprovalId: UUID? = nil
    var toolName: String? = nil
    var onApprovalHandled: (() -> Void)? = nil
    
    @State private var showingSheet = false
    @State private var isHovered = false
    @Environment(\.colorScheme) var colorScheme
    
    private var theme: DiffTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    var body: some View {
        Button(action: { showingSheet = true }) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 10))
                Text("View")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isHovered ? .white : .accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor : Color.accentColor.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .sheet(isPresented: $showingSheet) {
            if let approvalId = pendingApprovalId {
                // Show approval sheet with approve/reject buttons and hunk-level control
                FileChangeApprovalSheet(
                    approval: PendingFileChangeApproval(
                        id: approvalId,
                        sessionId: UUID(), // Not used for display
                        fileChange: fileChange,
                        toolName: toolName ?? "unknown",
                        toolArgs: [:]
                    ),
                    onApprove: {
                        NotificationCenter.default.post(
                            name: .TermAIFileChangeApprovalResponse,
                            object: nil,
                            userInfo: [
                                "approvalId": approvalId,
                                "approved": true
                            ]
                        )
                        showingSheet = false
                        onApprovalHandled?()
                    },
                    onReject: {
                        NotificationCenter.default.post(
                            name: .TermAIFileChangeApprovalResponse,
                            object: nil,
                            userInfo: [
                                "approvalId": approvalId,
                                "approved": false
                            ]
                        )
                        showingSheet = false
                        onApprovalHandled?()
                    },
                    onPartialApprove: { decisions, modifiedContent in
                        NotificationCenter.default.post(
                            name: .TermAIFileChangeApprovalResponse,
                            object: nil,
                            userInfo: [
                                "approvalId": approvalId,
                                "approved": true,
                                "partialApproval": true,
                                "hunkDecisions": decisions,
                                "modifiedContent": modifiedContent
                            ]
                        )
                        showingSheet = false
                        onApprovalHandled?()
                    }
                )
            } else {
                // Show read-only diff sheet
                FileDiffDetailSheet(fileChange: fileChange) {
                    showingSheet = false
                }
            }
        }
    }
}

// MARK: - Inline Diff Preview

/// Compact inline diff preview for agent event display
struct InlineDiffPreview: View {
    let fileChange: FileChange
    let maxLines: Int
    
    @State private var isExpanded = false
    @State private var showingFullDiff = false
    @Environment(\.colorScheme) var colorScheme
    
    private var theme: DiffTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    private var diff: FileDiff {
        FileDiff(fileChange: fileChange)
    }
    
    init(fileChange: FileChange, maxLines: Int = 6) {
        self.fileChange = fileChange
        self.maxLines = maxLines
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack {
                // Operation badge
                HStack(spacing: 4) {
                    Image(systemName: fileChange.operationType.icon)
                        .font(.system(size: 9))
                    Text(fileChange.operationType.description)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(operationColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(operationColor.opacity(0.15))
                )
                
                // File name
                Text(fileChange.fileName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.foreground)
                    .lineLimit(1)
                
                Spacer()
                
                // Summary badge
                DiffSummaryBadge(diff: diff)
                
                // Expand button
                Button(action: { withAnimation { isExpanded.toggle() } }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            
            // Preview lines (when expanded)
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(diff.lines.prefix(maxLines).enumerated()), id: \.offset) { index, line in
                        compactDiffLine(line)
                    }
                    
                    if diff.lines.count > maxLines {
                        Button(action: { showingFullDiff = true }) {
                            HStack {
                                Spacer()
                                Text("Show all \(diff.lines.count) lines...")
                                    .font(.system(size: 10))
                                    .foregroundColor(.accentColor)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .background(theme.headerBackground)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.divider, lineWidth: 0.5)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // View full diff button
            if !isExpanded {
                ViewChangesButton(fileChange: fileChange)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.headerBackground)
        )
        .sheet(isPresented: $showingFullDiff) {
            FileDiffDetailSheet(fileChange: fileChange) {
                showingFullDiff = false
            }
        }
    }
    
    private var operationColor: Color {
        switch fileChange.operationType {
        case .create: return .green
        case .edit: return .blue
        case .insert: return .cyan
        case .delete, .deleteFile: return .red
        case .overwrite: return .orange
        }
    }
    
    private func compactDiffLine(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            // Change indicator
            Text(line.type == .added ? "+" : (line.type == .removed ? "-" : " "))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(indicatorColor(for: line.type))
                .frame(width: 16)
            
            // Content
            Text(line.content)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(backgroundColor(for: line.type))
    }
    
    private func indicatorColor(for type: DiffLine.DiffLineType) -> Color {
        switch type {
        case .added: return theme.addedText
        case .removed: return theme.removedText
        default: return theme.secondaryText
        }
    }
    
    private func backgroundColor(for type: DiffLine.DiffLineType) -> Color {
        switch type {
        case .added: return theme.addedBackground.opacity(0.5)
        case .removed: return theme.removedBackground.opacity(0.5)
        default: return Color.clear
        }
    }
}

// MARK: - File Viewer Sheet with Line Range Editor

/// Sheet for viewing file content with editable line range selection
struct FileViewerSheet: View {
    let context: PinnedContext
    let onDismiss: () -> Void
    /// Optional callback for updating line ranges - when provided, shows save button
    var onUpdateLineRanges: (([LineRange]) -> Void)? = nil
    
    @State private var lineRangeText: String = ""
    @Environment(\.colorScheme) var colorScheme
    
    private var theme: DiffTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    /// Parse the current line range input
    private var parsedRanges: [LineRange] {
        LineRange.parseMultiple(lineRangeText)
    }
    
    /// Check if input is valid (empty or valid ranges)
    private var isValidInput: Bool {
        lineRangeText.isEmpty || !parsedRanges.isEmpty
    }
    
    /// Count of selected lines
    private var selectedLineCount: Int {
        parsedRanges.reduce(0) { $0 + ($1.end - $1.start + 1) }
    }
    
    /// Total lines in the file
    private var totalLineCount: Int {
        (context.fullContent ?? context.content).components(separatedBy: .newlines).count
    }
    
    /// Content to be used (selected lines or full)
    private var effectiveContent: String {
        guard !parsedRanges.isEmpty, let fullContent = context.fullContent else {
            return context.content
        }
        
        let lines = fullContent.components(separatedBy: .newlines)
        var selectedLines: [String] = []
        
        for range in parsedRanges.sorted(by: { $0.start < $1.start }) {
            let startIdx = max(0, range.start - 1)
            let endIdx = min(lines.count, range.end)
            guard startIdx < lines.count else { continue }
            selectedLines.append(contentsOf: lines[startIdx..<endIdx])
        }
        
        return selectedLines.joined(separator: "\n")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
            
            // Line range editor (always shown for files with full content)
            if context.fullContent != nil {
                lineRangeEditor
                Divider()
            }
            
            // Content view
            contentView
            
            Divider()
            
            // Footer
            footer
        }
        .frame(minWidth: 700, minHeight: 500)
        .frame(maxWidth: 1000, maxHeight: 700)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            // Initialize line range text from existing ranges
            if let ranges = context.lineRanges, !ranges.isEmpty {
                lineRangeText = ranges.map { 
                    $0.start == $0.end ? "\($0.start)" : "\($0.start)-\($0.end)"
                }.joined(separator: ",")
            }
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: context.icon)
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(context.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.foreground)
                
                Text(context.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            // Language badge
            if let lang = context.language {
                Text(lang.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.1))
                    )
            }
            
            // Close button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(theme.headerBackground)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(theme.headerBackground)
    }
    
    // MARK: - Line Range Editor
    
    private var lineRangeEditor: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
            
            Text("Line Selection:")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.foreground)
            
            TextField("e.g., 10-50 or 1-20,45-60 (empty = entire file)", text: $lineRangeText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: 280)
            
            if !lineRangeText.isEmpty && !isValidInput {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                    .help("Invalid format. Use: 10-50 or 1-20,45-60")
            }
            
            Spacer()
            
            // Selection info
            if !parsedRanges.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 10))
                    Text("\(selectedLineCount) of \(totalLineCount) lines")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.accentColor.opacity(0.1))
                )
            } else {
                Text("Entire file (\(totalLineCount) lines)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(theme.headerBackground.opacity(0.5))
    }
    
    // MARK: - Content View
    
    private var contentView: some View {
        ScrollView([.horizontal, .vertical]) {
            // Show the full file with highlighted sections based on input
            if let fullContent = context.fullContent {
                FileContentWithHighlights(
                    content: fullContent,
                    selectedRanges: parsedRanges,
                    language: context.language,
                    colorScheme: colorScheme
                )
            } else if let lang = context.language {
                // Syntax highlighted content (no full file available)
                MultiLanguageHighlighter(colorScheme: colorScheme)
                    .highlight(context.content, language: lang)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Plain text
                Text(context.content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.background)
    }
    
    // MARK: - Footer
    
    private var footer: some View {
        HStack {
            // Stats for the effective (selected) content
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    Text("\(effectiveContent.components(separatedBy: .newlines).count) lines selected")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "number")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    Text("~\(TokenEstimator.estimateTokens(effectiveContent)) tokens")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
                
                if TokenEstimator.estimateTokens(effectiveContent) > 5000 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Text("Large content")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                }
            }
            
            Spacer()
            
            // Copy button
            Button(action: copyContent) {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
            
            // Save/Update button (when callback provided and ranges changed)
            if let updateCallback = onUpdateLineRanges {
                let hasChanges = parsedRanges != (context.lineRanges ?? [])
                Button(action: { updateCallback(parsedRanges) }) {
                    HStack(spacing: 4) {
                        Image(systemName: parsedRanges.isEmpty ? "doc.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11))
                        Text(parsedRanges.isEmpty ? "Use Entire File" : "Save Selection")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(hasChanges ? Color.accentColor : Color.gray)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!hasChanges && !parsedRanges.isEmpty)
            } else {
                // Done button (read-only mode)
                Button(action: onDismiss) {
                    Text("Done")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.headerBackground)
    }
    
    private func copyContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(effectiveContent, forType: .string)
    }
}

// MARK: - File Content with Highlighted Sections

/// Displays file content with line numbers and highlighted selected sections
struct FileContentWithHighlights: View {
    let content: String
    let selectedRanges: [LineRange]
    let language: String?
    let colorScheme: ColorScheme
    
    private var theme: DiffTheme {
        colorScheme == .dark ? .dark : .light
    }
    
    private var lines: [String] {
        content.components(separatedBy: .newlines)
    }
    
    private var lineNumberWidth: CGFloat {
        let maxLineNumber = lines.count
        let digits = String(maxLineNumber).count
        return CGFloat(digits * 10 + 16)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Legend
            if !selectedRanges.isEmpty {
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 16, height: 12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                            )
                        Text("Selected lines (will be added to context)")
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                    }
                    
                    Spacer()
                    
                    Text("\(selectedRanges.map { $0.description }.joined(separator: ", "))")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.1))
                        )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(theme.headerBackground)
                
                Divider()
            }
            
            // File content with line numbers
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    // Line numbers column
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, _ in
                            let lineNumber = index + 1
                            let isSelected = isLineInRange(lineNumber)
                            
                            Text("\(lineNumber)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(isSelected ? .accentColor : theme.secondaryText.opacity(0.5))
                                .fontWeight(isSelected ? .semibold : .regular)
                                .frame(width: lineNumberWidth - 8, alignment: .trailing)
                                .padding(.trailing, 8)
                                .padding(.vertical, 1)
                                .background(
                                    isSelected
                                        ? Color.accentColor.opacity(0.1)
                                        : Color.clear
                                )
                        }
                    }
                    .background(theme.headerBackground.opacity(0.5))
                    
                    // Divider
                    Rectangle()
                        .fill(theme.divider)
                        .frame(width: 1)
                    
                    // Code content
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            let lineNumber = index + 1
                            let isSelected = isLineInRange(lineNumber)
                            
                            HStack(spacing: 0) {
                                // Selection indicator
                                if isSelected {
                                    Rectangle()
                                        .fill(Color.accentColor)
                                        .frame(width: 3)
                                }
                                
                                // Line content
                                if let lang = language {
                                    MultiLanguageHighlighter(colorScheme: colorScheme)
                                        .highlight(line.isEmpty ? " " : line, language: lang)
                                        .font(.system(size: 11, design: .monospaced))
                                        .padding(.leading, isSelected ? 8 : 11)
                                        .padding(.vertical, 1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(line.isEmpty ? " " : line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(theme.foreground)
                                        .padding(.leading, isSelected ? 8 : 11)
                                        .padding(.vertical, 1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .background(
                                isSelected
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }
    
    private func isLineInRange(_ lineNumber: Int) -> Bool {
        selectedRanges.contains { $0.contains(lineNumber) }
    }
}

// MARK: - Preview

#if DEBUG
struct FileDiffPanel_Previews: PreviewProvider {
    static var previews: some View {
        let fileChange = FileChange(
            filePath: "/Users/test/project/src/App.swift",
            operationType: .edit,
            beforeContent: """
            import SwiftUI
            
            struct App: View {
                var body: some View {
                    Text("Hello")
                }
            }
            """,
            afterContent: """
            import SwiftUI
            
            struct App: View {
                @State private var message = "Hello, World!"
                
                var body: some View {
                    VStack {
                        Text(message)
                        Button("Tap me") {
                            message = "Tapped!"
                        }
                    }
                }
            }
            """
        )
        
        let approval = PendingFileChangeApproval(
            sessionId: UUID(),
            fileChange: fileChange,
            toolName: "edit_file",
            toolArgs: ["path": fileChange.filePath]
        )
        
        FileChangeApprovalSheet(
            approval: approval,
            onApprove: {},
            onReject: {}
        )
        .frame(width: 800, height: 600)
    }
}
#endif

