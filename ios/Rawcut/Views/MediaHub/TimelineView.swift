import SwiftUI
import SwiftData

/// Date-grouped activity feed (like Apple Photos "Days" view).
/// Sections grouped by date with thumbnails in a horizontal scroll.
struct TimelineView: View {
    @Query(sort: \MediaAsset.createdDate, order: .reverse)
    private var assets: [MediaAsset]

    var body: some View {
        if assets.isEmpty {
            EmptyStateView(
                icon: "clock.arrow.circlepath",
                title: "동기화된 미디어 없음",
                description: "라이브러리 탭을 열어 동기화를 시작하세요.",
                actionTitle: nil,
                action: nil
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                    ForEach(groupedByDate, id: \.date) { group in
                        TimelineSectionView(group: group)
                    }
                }
                .padding(.vertical, Spacing.lg)
            }
        }
    }

    // MARK: - Date Grouping

    private var groupedByDate: [DateGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: assets) { asset in
            calendar.startOfDay(for: asset.createdDate)
        }
        return grouped.map { date, items in
            let videos = items.filter { $0.mediaType == .video }.count
            let photos = items.filter { $0.mediaType != .video }.count
            return DateGroup(date: date, assets: items, videoCount: videos, photoCount: photos)
        }
        .sorted { $0.date > $1.date }
    }
}

// MARK: - Data Types

private struct DateGroup: Identifiable {
    let date: Date
    let assets: [MediaAsset]
    let videoCount: Int
    let photoCount: Int

    var id: Date { date }

    var headerText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일"
        let dateStr = formatter.string(from: date)

        var parts: [String] = []
        if videoCount > 0 { parts.append("동영상 \(videoCount)개") }
        if photoCount > 0 { parts.append("사진 \(photoCount)개") }
        return "\(dateStr) — \(parts.joined(separator: ", "))"
    }
}

// MARK: - Section View

private struct TimelineSectionView: View {
    let group: DateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Section header
            Text(group.headerText)
                .font(.rcTitleMedium)
                .foregroundStyle(Color.rcTextPrimary)
                .padding(.horizontal, Spacing.lg)
                .accessibilityAddTraits(.isHeader)

            // Horizontal scroll of thumbnails
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    ForEach(group.assets) { asset in
                        AssetThumbnailView(asset: asset)
                            .frame(width: 120, height: 120)
                    }
                }
                .padding(.horizontal, Spacing.lg)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ZStack {
            Color.rcBackground.ignoresSafeArea()
            TimelineView()
        }
        .navigationTitle("rawcut")
    }
    .modelContainer(for: MediaAsset.self, inMemory: true)
}
