import Foundation

/// Infrastructure adapter that conforms `MacroRunner` to the
/// `MacroRunning` port defined in ApplicationServices.
///
/// Layers review M2/M3: `MacroRunner` now uses the ApplicationServices-side
/// `MacroInput` / `MacroOutput` / `MacroRunningError` types directly (legal
/// inward dependency: Infrastructure -> ApplicationServices port), so this
/// adapter no longer translates inputs, outputs, or errors. It exists only to
/// satisfy the port/adapter shape so `PasteCoordinator` depends on the
/// `MacroRunning` protocol rather than the concrete Infrastructure enum.
final class MacroRunnerAdapter: MacroRunning {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func runAsync(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
    ) async throws -> MacroOutput {
        try await MacroRunner.runAsync(
            script: script,
            input: input,
            verifyFingerprint: verifyFingerprint,
            timeoutSeconds: settings.macroTimeoutSeconds
        )
    }

    func debugRunAsync(
        script: MacroScript,
        input: MacroInput,
        verifyFingerprint: Bool
    ) async throws -> MacroDebugReport {
        try await MacroRunner.debugRunAsync(
            script: script,
            input: input,
            verifyFingerprint: verifyFingerprint,
            timeoutSeconds: settings.macroTimeoutSeconds
        )
    }
}
