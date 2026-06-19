import SwiftUI

/// A rounded white card container with subtle blue stroke + shadow.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.cardStroke, lineWidth: 1)
            )
            .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 3)
    }
}

/// A headline statistic tile.
struct StatTile: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var systemImage: String
    var tint: Color = Theme.primary

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(tint.opacity(0.14))
                            .frame(width: 32, height: 32)
                        Image(systemName: systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(.uppercase)
                    Spacer()
                }
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Section title used above cards.
struct SectionTitle: View {
    let text: String
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.primary)
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

/// A small labeled value row.
struct StatRow: View {
    let label: String
    let value: String
    var color: Color = Theme.textPrimary
    var body: some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
        }
    }
}

/// Empty / hint state.
struct HintBox: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        Card {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.sky)
                Text(title).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message).font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }
}
