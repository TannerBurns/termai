import Foundation
import UserNotifications
import AppKit

/// Service for managing macOS system notifications for agent approval requests
/// Uses UNUserNotificationCenter to alert users when approvals are needed
final class SystemNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotificationService()
    
    /// The notification center, nil if not available (e.g., when running via `swift run`)
    private var notificationCenter: UNUserNotificationCenter?
    
    /// Whether notifications are available (requires running from an app bundle)
    var isAvailable: Bool { notificationCenter != nil }
    
    /// Category identifiers for notification actions
    private enum Category {
        static let commandApproval = "COMMAND_APPROVAL"
        static let fileChangeApproval = "FILE_CHANGE_APPROVAL"
    }
    
    private override init() {
        super.init()
        
        // UNUserNotificationCenter requires running from an app bundle
        // Check if we're in a proper bundle before trying to access it
        if Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") {
            do {
                // Try to get the notification center - this can crash if not in an app bundle
                let center = UNUserNotificationCenter.current()
                self.notificationCenter = center
                center.delegate = self
                setupCategories()
            } catch {
                print("[SystemNotificationService] Notifications unavailable: \(error)")
            }
        } else {
            print("[SystemNotificationService] Notifications unavailable - not running from app bundle")
        }
    }
    
    /// Setup notification categories for actionable notifications
    private func setupCategories() {
        guard let notificationCenter = notificationCenter else { return }
        
        let commandCategory = UNNotificationCategory(
            identifier: Category.commandApproval,
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        let fileChangeCategory = UNNotificationCategory(
            identifier: Category.fileChangeApproval,
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        notificationCenter.setNotificationCategories([commandCategory, fileChangeCategory])
    }
    
    // MARK: - Authorization
    
    /// Request notification authorization from the user
    /// - Parameter completion: Called with authorization result
    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        guard let notificationCenter = notificationCenter else {
            completion?(false)
            return
        }
        
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[SystemNotificationService] Authorization error: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                completion?(granted)
            }
        }
    }
    
    /// Check if notifications are authorized
    func checkAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        guard let notificationCenter = notificationCenter else {
            completion(.notDetermined)
            return
        }
        
        notificationCenter.getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus)
            }
        }
    }
    
    // MARK: - Post Notifications
    
    /// Post a notification for command approval request
    /// - Parameters:
    ///   - command: The command awaiting approval
    ///   - sessionId: The session ID requesting approval
    func postCommandApprovalNotification(command: String, sessionId: UUID) {
        guard AgentSettings.shared.enableApprovalNotifications,
              let notificationCenter = notificationCenter else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "TermAI: Command Approval Required"
        content.subtitle = "Agent wants to run a command"
        
        // Truncate long commands for readability
        let truncatedCommand = command.count > 80 
            ? String(command.prefix(77)) + "..." 
            : command
        content.body = truncatedCommand
        
        // Only play sound if enabled in settings
        if AgentSettings.shared.enableApprovalNotificationSound {
            content.sound = .default
        }
        content.categoryIdentifier = Category.commandApproval
        content.userInfo = [
            "type": "command_approval",
            "sessionId": sessionId.uuidString,
            "command": command
        ]
        
        // Use unique identifier so multiple pending approvals don't overwrite each other
        let identifier = "command-approval-\(sessionId.uuidString)-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        
        notificationCenter.add(request) { error in
            if let error = error {
                print("[SystemNotificationService] Failed to post command notification: \(error.localizedDescription)")
            } else {
                print("[SystemNotificationService] Posted command approval notification for: \(truncatedCommand)")
            }
        }
    }
    
    /// Post a notification for file change approval request
    /// - Parameters:
    ///   - fileName: The file being modified
    ///   - operation: Description of the operation (e.g., "edit", "create", "delete")
    ///   - sessionId: The session ID requesting approval
    func postFileChangeApprovalNotification(fileName: String, operation: String, sessionId: UUID) {
        guard AgentSettings.shared.enableApprovalNotifications,
              let notificationCenter = notificationCenter else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "TermAI: File Change Approval Required"
        content.subtitle = "Agent wants to \(operation.lowercased()) a file"
        content.body = fileName
        
        // Only play sound if enabled in settings
        if AgentSettings.shared.enableApprovalNotificationSound {
            content.sound = .default
        }
        content.categoryIdentifier = Category.fileChangeApproval
        content.userInfo = [
            "type": "file_change_approval",
            "sessionId": sessionId.uuidString,
            "fileName": fileName,
            "operation": operation
        ]
        
        // Use unique identifier so multiple pending approvals don't overwrite each other
        let identifier = "file-approval-\(sessionId.uuidString)-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        
        notificationCenter.add(request) { error in
            if let error = error {
                print("[SystemNotificationService] Failed to post file change notification: \(error.localizedDescription)")
            } else {
                print("[SystemNotificationService] Posted file change notification for: \(operation) \(fileName)")
            }
        }
    }
    
    /// Remove all pending approval notifications (e.g., when approval is handled)
    func clearPendingNotifications() {
        guard let notificationCenter = notificationCenter else { return }
        notificationCenter.removeAllDeliveredNotifications()
        notificationCenter.removeAllPendingNotificationRequests()
    }
    
    /// Remove notifications for a specific session
    func clearNotifications(forSessionId sessionId: UUID) {
        guard let notificationCenter = notificationCenter else { return }
        let sessionString = sessionId.uuidString
        
        notificationCenter.getDeliveredNotifications { [weak self] notifications in
            let identifiersToRemove = notifications
                .filter { $0.request.content.userInfo["sessionId"] as? String == sessionString }
                .map { $0.request.identifier }
            
            self?.notificationCenter?.removeDeliveredNotifications(withIdentifiers: identifiersToRemove)
        }
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    /// Called when user interacts with a notification (tap, dismiss, etc.)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Bring app to foreground when notification is clicked
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            
            // Make the main window key
            if let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        
        completionHandler()
    }
    
    /// Called when notification will be presented while app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Always show the notification - user may be focused elsewhere even with app active
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if AgentSettings.shared.enableApprovalNotificationSound {
            options.insert(.sound)
        }
        completionHandler(options)
    }
}

