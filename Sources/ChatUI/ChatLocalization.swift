import AppLocalization
import ChatCore
import SwiftUI

/// The app injects its shared settings owner. Reading inside body tracks Observation;
/// standalone consumers may inject an explicit locale without a settings owner.
@propertyWrapper @MainActor
struct ChatLocalization: DynamicProperty {
    @Environment(LocalizationSettings.self) private var settings: LocalizationSettings?
    @Environment(\.locale) private var locale
    var wrappedValue: Localizer { settings?.localizer ?? Localizer(locale: locale) }
}

extension Localizer {
    func chat(_ key: String, _ arguments: [String: LocalizationArgument] = [:]) -> String {
        string(LocalizedMessage(key, table: .chatUI, arguments: arguments))
    }

    func chatCount(_ count: Int, one: String, other: String) -> String {
        string(.plural(count: count,
                       one: LocalizedMessage(one, table: .chatUI, arguments: ["count": .integer(count)]),
                       other: LocalizedMessage(other, table: .chatUI, arguments: ["count": .integer(count)])))
    }

    func role(_ role: MessageRole, userIsYou: Bool = false) -> String {
        switch role {
        case .user: chat(userIsYou ? "You" : "User")
        case .assistant: chat("Assistant")
        case .system: chat("System")
        case .tool: chat("Tool")
        }
    }

    func status(_ status: MessageStatus) -> String {
        switch status {
        case .complete: chat("Complete")
        case .streaming: chat("Streaming")
        case .stopped: chat("Stopped")
        case .failed: chat("Failed")
        }
    }
}

private struct ChatDiagnosticTemplatesKey: EnvironmentKey {
    static let defaultValue: [DiagnosticTemplate] = []
}

extension EnvironmentValues {
    /// App-owned canonical diagnostic adapters, provided by the composing runtime. No transcript use.
    public var chatDiagnosticTemplates: [DiagnosticTemplate] {
        get { self[ChatDiagnosticTemplatesKey.self] }
        set { self[ChatDiagnosticTemplatesKey.self] = newValue }
    }
}
