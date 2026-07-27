import Foundation

/// Infrastructure adapter that conforms `MacroRunner` to the
/// `MacroRunning` port defined in ApplicationServices.
///
/// The original `MacroRunner` enum keeps its static implementation; this
/// adapter wraps it so `PasteCoordinator` can depend on the protocol instead
/// of the concrete Infrastructure type.
final class MacroRunnerAdapter: MacroRunning {
    func runAsync(
        script: MacroScript,
        input: MacroRunner.MacroInput,
        verifyFingerprint: Bool
    ) async throws -> MacroRunner.MacroOutput {
        try await MacroRunner.runAsync(script: script, input: input, verifyFingerprint: verifyFingerprint)
    }
}
