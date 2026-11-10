import SwiftUI

extension Localizer {
    /// Verbatim avoids a second lookup in Bundle.main or markdown interpretation of user arguments.
    public func text(_ message: LocalizedMessage) -> Text { Text(verbatim: string(message)) }
}

extension LocalizationSettings {
    /// Call inside body so Observation tracks language reads; don't cache the resulting Text/String.
    public func text(_ message: LocalizedMessage) -> Text { Text(verbatim: string(message)) }
}

/// Standalone setting only; the application owns placement and the shared settings instance.
@MainActor public struct LanguagePickerView: View {
    @Bindable private var localization: LocalizationSettings

    public init(localization: LocalizationSettings) { self.localization = localization }

    public var body: some View {
        Picker(selection: $localization.choice) {
            ForEach(LanguageChoice.allCases) { choice in
                Text(verbatim: localization.string(choice.nameKey)).tag(choice)
            }
        } label: {
            Text(verbatim: localization.string("Language"))
        }
        .environment(\.locale, localization.locale)
    }
}
