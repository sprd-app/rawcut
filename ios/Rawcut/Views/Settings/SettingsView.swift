import SwiftUI
import SwiftData

/// Settings screen with account info, cost comparison dashboard,
/// sync status, and about section.
struct SettingsView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var syncEngine: SyncEngine
    @EnvironmentObject private var storageManager: StorageManager
    @Query private var assets: [MediaAsset]

    @AppStorage("syncOnWiFiOnly") private var syncOnWiFiOnly = true
    @AppStorage("optimizeStorage") private var optimizeStorage = true

    @State private var showFreeSpaceConfirm = false
    @State private var spaceEstimate: StorageManager.SpaceRecoveryEstimate?
    @State private var iCloudPhotosEnabled: Bool = false
    @State private var cloudHealth: APIClient.SyncHealthResponse?
    @State private var isLoadingHealth = false

    var body: some View {
        List {
            accountSection
            if iCloudPhotosEnabled {
                iCloudWarningSection
            }
            cloudHealthSection
            storageSection
            syncSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            iCloudPhotosEnabled = FileManager.default.ubiquityIdentityToken != nil
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        Section {
            HStack(spacing: Spacing.md) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.rcTextSecondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(authManager.displayName ?? "User")
                        .font(.rcTitleMedium)

                    if authManager.isAuthenticated {
                        Text("Signed in with Apple")
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextSecondary)
                    }
                }

                Spacer()
            }

            if authManager.isAuthenticated {
                Button(role: .destructive) {
                    authManager.signOut()
                } label: {
                    Text("Sign Out")
                        .font(.rcBody)
                }
                    .accessibilityLabel("Sign Out")
            }
        } header: {
            Text("Account")
        }
    }

    // MARK: - iCloud Warning Section

    private var iCloudWarningSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.icloud.fill")
                        .foregroundStyle(Color.rcWarning)
                    Text("iCloud Photos Enabled")
                        .font(.rcBodyMedium)
                        .foregroundStyle(Color.rcTextPrimary)
                }

                Text("Your media is uploading to both iCloud and rawcut. To avoid double storage costs, go to Settings → iCloud → Photos and turn off sync.")
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextSecondary)

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open iPhone Settings")
                        .font(.rcCaptionBold)
                        .foregroundStyle(Color.rcAccent)
                }
            }
            .padding(.vertical, Spacing.xs)
        } header: {
            Text("Warning")
                .foregroundStyle(Color.rcWarning)
        }
    }

    // MARK: - Cloud Health Section

    private var cloudHealthSection: some View {
        Section {
            if let health = cloudHealth {
                // Main status indicator
                HStack(spacing: Spacing.md) {
                    Image(systemName: healthIcon(for: health))
                        .font(.system(size: 28))
                        .foregroundStyle(healthColor(for: health))

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(healthTitle(for: health))
                            .font(.rcBodyMedium)
                            .foregroundStyle(Color.rcTextPrimary)

                        Text("\(health.synced_count) items safely in cloud")
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextSecondary)
                    }

                    Spacer()

                    Text(String(format: "%.1f%%", health.success_rate * 100))
                        .font(.rcStat)
                        .foregroundStyle(healthColor(for: health))
                }
                .padding(.vertical, Spacing.xs)

                // Detail rows
                if health.failed_count > 0 {
                    HStack {
                        Text("Failed uploads")
                            .font(.rcBody)
                            .foregroundStyle(Color.rcTextSecondary)
                        Spacer()
                        Text("\(health.failed_count)")
                            .font(.rcBody)
                            .foregroundStyle(Color.rcError)
                    }
                }

                if health.pending_count > 0 {
                    HStack {
                        Text("Pending")
                            .font(.rcBody)
                            .foregroundStyle(Color.rcTextSecondary)
                        Spacer()
                        Text("\(health.pending_count)")
                            .font(.rcBody)
                            .foregroundStyle(Color.rcTextTertiary)
                    }
                }

                if let alert = health.alert {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.rcWarning)
                        Text(alert)
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcWarning)
                    }
                }
            } else if isLoadingHealth {
                HStack {
                    ProgressView()
                    Text("Checking cloud status...")
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextSecondary)
                        .padding(.leading, Spacing.sm)
                }
            } else {
                Button {
                    loadCloudHealth()
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(Color.rcAccent)
                        Text("Check Cloud Health")
                            .font(.rcBody)
                            .foregroundStyle(Color.rcTextPrimary)
                    }
                }
            }
        } header: {
            Text("Cloud Health")
        }
        .onAppear { loadCloudHealth() }
    }

    private func healthIcon(for health: APIClient.SyncHealthResponse) -> String {
        if health.failed_count > 0 || health.alert != nil {
            return "exclamationmark.shield.fill"
        }
        if health.pending_count > 0 {
            return "arrow.triangle.2.circlepath"
        }
        return "checkmark.shield.fill"
    }

    private func healthColor(for health: APIClient.SyncHealthResponse) -> Color {
        if health.failed_count > 0 || health.alert != nil { return Color.rcError }
        if health.pending_count > 0 { return Color.rcWarning }
        return Color.rcAccent
    }

    private func healthTitle(for health: APIClient.SyncHealthResponse) -> String {
        if health.failed_count > 0 { return "Attention Needed" }
        if health.pending_count > 0 { return "Syncing..." }
        return "All Safe"
    }

    private func loadCloudHealth() {
        guard let token = authManager.authToken else { return }
        isLoadingHealth = true
        Task {
            do {
                cloudHealth = try await APIClient.getSyncHealth(authToken: token)
            } catch {
                print("[Rawcut] Failed to load cloud health: \(error.localizedDescription)")
            }
            isLoadingHealth = false
        }
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        Section {
            // Storage usage bar
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Storage Usage")
                    .font(.rcBody)

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
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Storage Usage: \(formattedStorageUsed)")

            // Cost comparison card
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Cost Comparison")
                    .font(.rcBodyMedium)
                    .foregroundStyle(Color.rcTextPrimary)

                costRow(label: "iCloud cost:", value: iCloudCostString, color: Color.rcTextSecondary)
                costRow(label: "rawcut cost:", value: rawcutCostString, color: Color.rcTextSecondary)

                Text("Storage: Cool tier $0.01/GB + egress ~$0.087/GB")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.rcTextTertiary)

                Divider()

                HStack {
                    Text("You save:")
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextPrimary)
                    Spacer()
                    Text(savingsString)
                        .font(.rcStat)
                        .foregroundStyle(savings > 0 ? Color.rcAccent : Color.rcError)
                }
            }
            .padding(.vertical, Spacing.xs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Cost Comparison: iCloud \(iCloudCostString), rawcut \(rawcutCostString), you save \(savingsString)")
        } header: {
            Text("Storage")
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

                Text("Sync Status")
                    .font(.rcBody)

                Spacer()

                Text(syncHealthLabel)
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sync Status: \(syncHealthLabel)")

            HStack {
                Text("Last synced")
                    .font(.rcBody)
                Spacer()
                Text(lastSyncedText)
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextSecondary)
            }

            Toggle(isOn: $syncOnWiFiOnly) {
                Text("Sync on Wi-Fi only")
                    .font(.rcBody)
            }
            .tint(Color.rcToggleTint)
            .accessibilityLabel("Sync on Wi-Fi only")

            // Optimize Storage (like iCloud's "Optimize iPhone Storage")
            Toggle(isOn: $optimizeStorage) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Optimize iPhone Storage")
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextPrimary)
                    Text("Automatically removes old media when storage is low")
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcTextSecondary)
                }
            }
            .tint(Color.rcToggleTint)
            .accessibilityLabel("Optimize iPhone Storage")

            // Device free space indicator
            HStack {
                Text("Device Free Space")
                    .font(.rcBody)
                Spacer()
                Text(formattedDeviceFreeSpace)
                    .font(.rcCaption)
                    .foregroundStyle(storageManager.isStorageLow ? Color.rcError : Color.rcTextSecondary)
            }
            .onAppear { storageManager.refreshDeviceFreeSpace() }

            // Free Up Space
            Button {
                spaceEstimate = storageManager.estimateRecoverableSpace()
                showFreeSpaceConfirm = true
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Color.rcAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Free Up Space")
                            .font(.rcBody)
                            .foregroundStyle(Color.rcTextPrimary)
                        Text("Remove local copies of synced media")
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcTextSecondary)
                    }
                    Spacer()
                    if let count = storageManager.lastFreedCount, count > 0 {
                        Text("\(count) freed")
                            .font(.rcCaption)
                            .foregroundStyle(Color.rcAccent)
                    }
                }
            }
            .confirmationDialog(
                "Free Up Space",
                isPresented: $showFreeSpaceConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete \(spaceEstimate?.assetCount ?? 0) local copies (\(spaceEstimate?.formattedSize ?? "0 bytes"))") {
                    Task {
                        _ = await storageManager.freeUpSpace()
                        syncEngine.refreshProgress()
                    }
                }
                Button("Only older than 30 days") {
                    Task {
                        _ = await storageManager.freeUpSpace(olderThan: 30)
                        syncEngine.refreshProgress()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Cloud copies will be kept. You can download originals anytime. \(spaceEstimate?.assetCount ?? 0) items, \(spaceEstimate?.formattedSize ?? "0 bytes") recoverable.")
            }
        } header: {
            Text("Sync")
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .font(.rcBody)
                Spacer()
                Text(appVersion)
                    .font(.rcCaption)
                    .foregroundStyle(Color.rcTextSecondary)
            }

            Link(destination: URL(string: "https://rawcut.app/privacy")!) {
                HStack {
                    Text("Privacy Policy")
                        .font(.rcBody)
                        .foregroundStyle(Color.rcTextPrimary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.rcCaption)
                        .foregroundStyle(Color.rcTextTertiary)
                }
            }
            .accessibilityLabel("Open Privacy Policy")
        } header: {
            Text("About")
        }
    }

    // MARK: - Computed Properties

    private var lastSyncedText: String {
        guard let date = syncEngine.lastSyncedDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private var totalSyncedBytes: Int64 {
        assets.filter { $0.syncStatus == .synced || $0.syncStatus == .cloudOnly }
            .reduce(0) { $0 + $1.fileSize }
    }

    private var totalStorageGB: Double {
        Double(totalSyncedBytes) / 1_073_741_824
    }

    private var formattedStorageUsed: String {
        if totalStorageGB >= 1 {
            return String(format: "%.1f GB synced to cloud", totalStorageGB)
        } else {
            let mb = totalStorageGB * 1024
            return String(format: "%.0f MB synced to cloud", mb)
        }
    }

    private func storageBarWidth(in totalWidth: CGFloat) -> CGFloat {
        let maxGB: Double = 200 // Assume 200 GB max scale
        let ratio = min(totalStorageGB / maxGB, 1.0)
        return max(totalWidth * ratio, 2)
    }

    /// iCloud pricing: $0.99/50GB, $2.99/200GB, $9.99/2TB, $32.99/12TB
    private var iCloudCostPerMonth: Double {
        if totalStorageGB <= 5 { return 0 }
        if totalStorageGB <= 50 { return 0.99 }
        if totalStorageGB <= 200 { return 2.99 }
        if totalStorageGB <= 2048 { return 9.99 }
        return 32.99
    }

    /// rawcut: Azure Blob Cool tier ~$0.01/GB/month
    /// Plus estimated egress for occasional downloads (~5% of storage per month)
    private var rawcutCostPerMonth: Double {
        let storageCost = totalStorageGB * 0.01 // Cool tier
        let estimatedEgress = totalStorageGB * 0.05 * 0.087 // 5% downloaded at $0.087/GB
        return storageCost + estimatedEgress
    }

    private var iCloudCostString: String {
        String(format: "$%.2f/mo", iCloudCostPerMonth)
    }

    private var rawcutCostString: String {
        String(format: "$%.2f/mo", rawcutCostPerMonth)
    }

    private var savings: Double {
        iCloudCostPerMonth - rawcutCostPerMonth
    }

    private var savingsString: String {
        if savings >= 0 {
            return String(format: "$%.2f/mo", savings)
        } else {
            return String(format: "-$%.2f/mo", abs(savings))
        }
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
        let syncedCount = assets.filter { $0.syncStatus == .synced || $0.syncStatus == .cloudOnly }.count
        let cloudOnlyCount = assets.filter { $0.syncStatus == .cloudOnly }.count
        if failedCount > 0 { return "\(failedCount) failed" }
        if uploadingCount > 0 { return "\(uploadingCount) uploading" }
        if cloudOnlyCount > 0 { return "\(syncedCount) synced (\(cloudOnlyCount) cloud-only)" }
        return "\(syncedCount) synced"
    }

    private var formattedDeviceFreeSpace: String {
        let bytes = storageManager.deviceFreeSpace
        if bytes <= 0 { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
