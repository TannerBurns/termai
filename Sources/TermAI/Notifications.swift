import Foundation

extension Notification.Name {
    static let TermAIExecuteCommand = Notification.Name("TermAIExecuteCommand")
    static let TermAICommandFinished = Notification.Name("TermAICommandFinished")
    
    // Command approval flow
    static let TermAICommandPendingApproval = Notification.Name("TermAICommandPendingApproval")
    static let TermAICommandApprovalResponse = Notification.Name("TermAICommandApprovalResponse")
}


