import Foundation

extension Notification.Name {
    static let TermAIExecuteCommand = Notification.Name("TermAIExecuteCommand")
    static let TermAICommandFinished = Notification.Name("TermAICommandFinished")
    static let TermAICWDUpdated = Notification.Name("TermAICWDUpdated")
    
    // Command approval flow
    static let TermAICommandPendingApproval = Notification.Name("TermAICommandPendingApproval")
    static let TermAICommandApprovalResponse = Notification.Name("TermAICommandApprovalResponse")
    
    // File change approval flow
    static let TermAIFileChangePendingApproval = Notification.Name("TermAIFileChangePendingApproval")
    static let TermAIFileChangeApprovalResponse = Notification.Name("TermAIFileChangeApprovalResponse")
    
    // Test runner flow
    static let TermAITestRunnerShow = Notification.Name("TermAITestRunnerShow")
    static let TermAITestRunnerStatusUpdate = Notification.Name("TermAITestRunnerStatusUpdate")
    static let TermAITestRunnerCompleted = Notification.Name("TermAITestRunnerCompleted")
    
    // File change notifications (agent tools → editor)
    /// Posted when an agent tool modifies a file on disk
    /// userInfo: ["path": String] - the absolute file path that was modified
    static let TermAIFileModifiedOnDisk = Notification.Name("TermAIFileModifiedOnDisk")
    
    // File/Plan opening notifications
    /// Posted to request opening a file in the editor
    /// userInfo: ["path": String] - the absolute file path to open
    static let TermAIOpenFileInEditor = Notification.Name("TermAIOpenFileInEditor")
    
    /// Posted to request opening a plan in the editor
    /// userInfo: ["planId": UUID] - the plan ID to open
    static let TermAIOpenPlanInEditor = Notification.Name("TermAIOpenPlanInEditor")
}


