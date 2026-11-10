import AppLocalization

/// Presentation-only adapters for canonical app-owned String diagnostics. Never use on transcripts,
/// model names, paths, or arbitrary provider prose. Backend state always retains its original source.
public enum RuntimePresentation {
    public static let diagnosticTemplates = [
        DiagnosticTemplate("Model selected. Create a new conversation to send with {provider}."),
        DiagnosticTemplate("Cursor CLI failed (exit {code}). Check Cursor login, subscription, and limits."),
    ]

    public static func diagnostic(_ source: String, localizer: Localizer) -> String {
        localizer.diagnostic(source, templates: diagnosticTemplates)
    }
}
