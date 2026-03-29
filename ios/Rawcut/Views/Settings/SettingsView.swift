import SwiftUI
import SwiftData

/// Settings screen with account info, cost comparison dashboard,
/// sync status, and about section.
struct SettingsView: View {
    @EnvironmentObject private var authManager: AuthManager
    @Query private var assets: [MediaAsset]

    @AppStorage("syncOnWiFiOnly") private var syncOnWiFiOnly = true

    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()

            List {
                accountSection
                storageSection
                syncSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
        }
        .navigationTitle("설정")
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Account Section

    private var accountSection: some View {
        Section {
            HStack(spacing: Spacing.md) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.rcAccent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(authManager.displayName ?? "사용자")
                        .font(.rcTitleMedium)
                        .foregroundStyle(Color.rcTextPrimary)

                    if authManager.isAuthenticated {
                        Text("Apple로 로그인됨")
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextSecondary)
                    }
                }

                Spacer()
            }
            .listRowBackground(Color.rcSurface)

            if authManager.isAuthenticated {
                Button(role: .destructive) {
                    authManager.signOut()
                } label: {
                    Text("로그아웃")
                        .font(.rcBody)
                }
                .listRowBackground(Color.rcSurface)
                .accessibilityLabel("로그아웃")
            }
        } header: {
            Text("계정")
                .font(.rcCaption)
                .foregroundStyle(Color.rcTextSecondary)
        }
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        Section {
            // Storage usage bar
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("저장공간 사용량")
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextPrimary)

                // Storage bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.rcSurfaceElevated)
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.rcAccent)
                            .frame(width: storageBarWidth(in: geometry.size.width), height: 8)
                    }
                }
                .frame(height: 8)

                Text(formattedStorageUsed)
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextSecondary)
            }
            .padding(.vertical, Spacing.xs)
            .listRowBackground(Color.rcSurface)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("저장공간 사용량: \(formattedStorageUsed)")

            // Cost comparison card
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("비용 비교")
                    .font(.rcBody)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.rcTextPrimary)

                costRow(label: "iCloud 비용:", value: iCloudCostString, color: Color.rcTextSecondary)
                costRow(label: "rawcut 비용:", value: rawcutCostString, color: Color.rcTextSecondary)

                Divider()
                    .overlay(Color.rcSurfaceElevated)

                HStack {
                    Text("절약 금액:")
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextPrimary)
                    Spacer()
                    Text(savingsString)
                        .font(.rcTitleMedium)
                        .foregroundStyle(Color.rcAccent)
                }
            }
            .padding(.vertical, Spacing.xs)
            .listRowBackground(Color.rcSurface)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("비용 비교: iCloud \(iCloudCostString), rawcut \(rawcutCostString), 절약 \(savingsString)")
        } header: {
            Text("저장공간")
                .font(.rcCaption)
                .foregroundStyle(Color.rcTextSecondary)
        }
    }

    private func costRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.rcBody)
                .foregroundStyle(Color.rcTextSecondary)
            Spacer()
            Text(value)
                .font(.rcBody)
                .foregroundStyle(color)
        }
    }

    // MARK: - Sync Section

    private var syncSection: some View {
        Section {
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(syncHealthColor)
                    .frame(width: 10, height: 10)

                Text("동기화 상태")
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextPrimary)

                Spacer()

                Text(syncHealthLabel)
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextSecondary)
            }
            .listRowBackground(Color.rcSurface)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("동기화 상태: \(syncHealthLabel)")

            HStack {
                Text("마지막 동기화")
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextPrimary)
                Spacer()
                Text("5분 전")
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextSecondary)
            }
            .listRowBackground(Color.rcSurface)

            Toggle(isOn: $syncOnWiFiOnly) {
                Text("Wi-Fi에서만 동기화")
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextPrimary)
            }
            .tint(Color.rcAccent)
            .listRowBackground(Color.rcSurface)
            .accessibilityLabel("Wi-Fi에서만 동기화")
        } header: {
            Text("동기화")
                .font(.rcCaption)
                .foregroundStyle(Color.rcTextSecondary)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            HStack {
                Text("버전")
                    .font(.rcBody)
                    .foregroundStyle(Color.rcTextPrimary)
                Spacer()
                Text(appVersion)
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextSecondary)
            }
            .listRowBackground(Color.rcSurface)

            Link(destination: URL(string: "https://rawcut.app/privacy")!) {
                HStack {
                    Text("개인정보 처리방침")
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextPrimary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcTextTertiary)
                }
            }
            .listRowBackground(Color.rcSurface)
            .accessibilityLabel("개인정보 처리방침 열기")
        } header: {
            Text("정보")
                .font(.rcCaption)
                .foregroundStyle(Color.rcTextSecondary)
        }
    }

    // MARK: - Computed Properties

    private var totalSyncedBytes: Int64 {
        assets.filter { $0.syncStatus == .synced }.reduce(0) { $0 + $1.fileSize }
    }

    private var totalStorageGB: Double {
        Double(totalSyncedBytes) / 1_073_741_824
    }

    private var formattedStorageUsed: String {
        if totalStorageGB >= 1 {
            return String(format: "%.1f GB 클라우드에 동기화됨", totalStorageGB)
        } else {
            let mb = totalStorageGB * 1024
            return String(format: "%.0f MB 클라우드에 동기화됨", mb)
        }
    }

    private func storageBarWidth(in totalWidth: CGFloat) -> CGFloat {
        let maxGB: Double = 200 // Assume 200 GB max scale
        let ratio = min(totalStorageGB / maxGB, 1.0)
        return max(totalWidth * ratio, 2)
    }

    /// iCloud pricing: $0.99/50GB, $2.99/200GB, $9.99/2TB
    private var iCloudCostPerMonth: Double {
        if totalStorageGB <= 5 { return 0 }
        if totalStorageGB <= 50 { return 0.99 }
        if totalStorageGB <= 200 { return 2.99 }
        return 9.99
    }

    /// rawcut: ~$0.006/GB/month (R2 pricing)
    private var rawcutCostPerMonth: Double {
        totalStorageGB * 0.006
    }

    private var iCloudCostString: String {
        String(format: "$%.2f/월", iCloudCostPerMonth)
    }

    private var rawcutCostString: String {
        String(format: "$%.2f/월", rawcutCostPerMonth)
    }

    private var savingsString: String {
        let savings = max(iCloudCostPerMonth - rawcutCostPerMonth, 0)
        return String(format: "$%.2f/월", savings)
    }

    private var syncHealthColor: Color {
        let failedCount = assets.filter { $0.syncStatus == .failed }.count
        let uploadingCount = assets.filter { $0.syncStatus == .uploading }.count
        if failedCount > 0 { return Color.rcError }
        if uploadingCount > 0 { return Color.rcWarning }
        return Color.rcAccent
    }

    private var syncHealthLabel: String {
        let failedCount = assets.filter { $0.syncStatus == .failed }.count
        let uploadingCount = assets.filter { $0.syncStatus == .uploading }.count
        let syncedCount = assets.filter { $0.syncStatus == .synced }.count
        if failedCount > 0 { return "실패 \(failedCount)개" }
        if uploadingCount > 0 { return "업로드 중 \(uploadingCount)개" }
        return "완료 \(syncedCount)개"
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AuthManager())
    }
    .modelContainer(for: MediaAsset.self, inMemory: true)
}
