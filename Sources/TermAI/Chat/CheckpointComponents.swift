import SwiftUI
import TermAIModels

// MARK: - Checkpoint Badge

/// Small badge indicating a checkpoint with changes exists at this message
struct CheckpointBadge: View {
    let checkpoint: Checkpoint
    
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 10))
            
            Text(checkpoint.shortDescription)
                .font(.caption2)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.orange.opacity(0.12))
        )
        .help("Checkpoint: \(checkpoint.shortDescription). Right-click to edit this message.")
    }
}

// MARK: - Rollback Choice Popover

/// Simple popover that appears when editing a message with a checkpoint
/// Asks user if they want to rollback files or keep current state
struct RollbackChoicePopover: View {
    let checkpoint: Checkpoint
    @ObservedObject var session: ChatSession
    let editedMessage: String
    let originalMessage: ChatMessage  // Original message to preserve terminal context
    @Binding var isPresented: Bool
    let onComplete: () -> Void
    
    @State private var isSubmitting = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)
                
                Text("File Changes Detected")
                    .font(.headline)
            }
            
            Text("\(checkpoint.modifiedFileCount) file(s) were modified after this message.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if !checkpoint.shellCommandsRun.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("\(checkpoint.shellCommandsRun.count) shell command(s) cannot be undone")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            Divider()
            
            // Options
            VStack(spacing: 8) {
                Button {
                    submitWithRollback()
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Rollback files")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                
                Button {
                    submitKeepFiles()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text("Keep current files")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
            
            // Cancel
            Button("Cancel") {
                isPresented = false
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .foregroundColor(.secondary)
            .padding(.top, 4)
        }
        .padding()
        .frame(width: 280)
    }
    
    private func submitWithRollback() {
        isSubmitting = true
        let trimmed = editedMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        // Rollback files and remove the original user message (we're replacing it)
        _ = session.rollbackToCheckpoint(checkpoint, removeUserMessage: true)

        // Preserve terminal context from the original message
        if let ctx = originalMessage.terminalContext {
            session.setPendingTerminalContext(ctx, meta: originalMessage.terminalContextMeta)
        }
        
        // Send the edited message
        Task {
            await session.sendUserMessage(trimmed)
            await MainActor.run {
                isPresented = false
                onComplete()
            }
        }
    }
    
    private func submitKeepFiles() {
        isSubmitting = true
        let trimmed = editedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Branch without rollback
        session.branchFromCheckpoint(checkpoint, newPrompt: "")
        
        // Preserve terminal context from the original message
        if let ctx = originalMessage.terminalContext {
            session.setPendingTerminalContext(ctx, meta: originalMessage.terminalContextMeta)
        }
        
        // Send the edited message
        Task {
            await session.sendUserMessage(trimmed)
            await MainActor.run {
                isPresented = false
                onComplete()
            }
        }
    }
}

// MARK: - File Snapshot Row

/// Row showing a file snapshot in the rollback preview
struct FileSnapshotRow: View {
    let snapshot: FileSnapshot
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.wasCreated ? "trash" : "arrow.counterclockwise")
                .foregroundColor(snapshot.wasCreated ? .red : .blue)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.fileName)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                
                Text(snapshot.wasCreated ? "Will be deleted" : "Will be restored")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if let content = snapshot.contentBefore {
                Text("\(content.count) chars")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
