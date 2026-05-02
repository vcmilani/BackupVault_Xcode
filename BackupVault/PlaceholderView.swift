import SwiftUI

/// Substituto compatível com macOS 13 para ContentUnavailableView (disponível só no 14+).
struct PlaceholderView: View {
    let title: LocalizedStringKey
    var icon: String = "questionmark.circle"
    var description: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
