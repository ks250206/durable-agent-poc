import AppKit
import AppLocalization
import ChatCore
import SwiftUI

/// Semantic surfaces follow the system appearance and increased-contrast preferences.
enum ChatTheme {
    static let background = Color(nsColor: .textBackgroundColor)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let inset = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let transcriptWidth: CGFloat = 760
}

/// Keep the reading column usable before offering persistent auxiliary panes.
struct WorkspaceLayout: Equatable {
    let width: CGFloat
    var inlineSidebar: Bool { width >= 780 }
    var inlineMinimap: Bool { width >= 1080 }
    static let sidebarWidth: CGFloat = 248
    static let minimapWidth: CGFloat = 144
}

struct ConnectionPresentation: Equatable {
    let title: String
    let symbol: String
    let detail: String?

    init(_ state: ConnectionState, localizer: Localizer = Localizer(language: .english)) {
        switch state {
        case .connected: (title, symbol, detail) = (localizer.chat("Connected"), "checkmark.circle", nil)
        case .connecting: (title, symbol, detail) = (localizer.chat("Connecting…"), "network", localizer.chat("Waiting for the backend connection."))
        case .disconnected:
            (title, symbol, detail) = (localizer.chat("Disconnected"), "network.slash", localizer.chat("Connect a provider in Settings to send messages."))
        case .demo:
            (title, symbol, detail) = (localizer.chat("Demo · Read only"), "eye", localizer.chat("Sample conversations. Sending and creating conversations are disabled."))
        case .failed(let message): (title, symbol, detail) = (localizer.chat("Connection failed"), "exclamationmark.triangle", localizer.diagnostic(message))
        }
    }
}
