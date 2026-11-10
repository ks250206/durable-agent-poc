import AppLocalization
import SwiftUI

/// Standalone settings control; #33 owns placement and shared scene injection.
/// Pass the live localization owner's localizer from body to update labels without remounting.
@MainActor public struct AppearancePickerView: View {
    @Bindable private var settings: AppearanceSettings
    private let localizer: Localizer

    public init(settings: AppearanceSettings, localizer: Localizer) {
        self.settings = settings
        self.localizer = localizer
    }

    public var body: some View {
        HStack {
            Picker(selection: $settings.choice) {
                ForEach(AppearanceChoice.allCases) { choice in
                    Text(verbatim: localizer.string(choice.nameKey, table: .appearance)).tag(choice)
                }
            } label: {
                Text(verbatim: localizer.string("Appearance", table: .appearance))
            }
            .help(localizer.string("Use the system appearance, or always use Light or Dark.", table: .appearance))
            Button {
                settings.resetToSystem()
            } label: {
                Text(verbatim: localizer.string("Reset to System", table: .appearance))
            }
        }
    }
}
