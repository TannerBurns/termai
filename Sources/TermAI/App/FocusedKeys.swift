import SwiftUI

struct NewTabActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues { var newTabAction: (() -> Void)? { get { self[NewTabActionKey.self] } set { self[NewTabActionKey.self] = newValue } } }
extension Notification.Name { static let requestNewGlobalTab = Notification.Name("requestNewGlobalTab") }


