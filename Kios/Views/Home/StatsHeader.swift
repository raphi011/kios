import SwiftUI

/// 4-cell stats strip displayed at the top of the Home tab. Pure
/// presentation — takes the computed `HomeStats` and renders.
struct StatsHeader: View {
    let stats: HomeStats

    var body: some View {
        HStack(spacing: 0) {
            cell(value: StatsFormatters.count(stats.booksRead), label: "BOOKS")
            divider
            cell(value: StatsFormatters.time(seconds: stats.totalSeconds), label: "TIME")
            divider
            cell(value: StatsFormatters.pages(stats.totalPages), label: "PAGES")
            divider
            cell(value: StatsFormatters.streak(days: stats.streakDays), label: "STREAK")
        }
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private func cell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 1, height: 28)
    }
}

#Preview {
    StatsHeader(stats: HomeStats(
        booksRead: 12, totalSeconds: 87 * 3600, totalPages: 4210, streakDays: 12
    ))
    .padding()
    .background(Color(.systemGroupedBackground))
}
