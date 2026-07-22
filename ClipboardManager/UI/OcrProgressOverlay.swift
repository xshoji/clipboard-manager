import SwiftUI

/// Full-window modal overlay shown while OCR recognition is in progress.
///
/// Dimmed background blocks all interaction with the underlying content so the
/// user cannot trigger duplicate actions or modify state during processing.
/// The overlay is driven by `.ocrProgressDidChange` notifications and dismisses
/// automatically when `inProgress` becomes `false`.
struct OcrProgressOverlay: View {
    var body: some View {
        ZStack {
            // Semi-transparent dim that covers the entire window and absorbs clicks.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Running OCR…")
                    .font(.headline)
                Text("Extracting text from image")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .background(Color.appBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.tertiary.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: true)
    }
}
