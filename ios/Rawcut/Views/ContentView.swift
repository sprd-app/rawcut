import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var storageManager: StorageManager
    @EnvironmentObject private var syncEngine: SyncEngine

    @State private var selectedTab: Tab = .library
    @State private var isOnboardingComplete: Bool =
        UserDefaults.standard.bool(forKey: UserDefaults.Keys.hasCompletedOnboarding)

    enum Tab: Hashable {
        case library
        case create
        case projects
        case settings
    }

    var body: some View {
        Group {
            if authManager.isAuthenticated {
                authenticatedContent
            } else {
                SignInView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToCreateTab)) { _ in
            selectedTab = .create
        }
    }

    // MARK: - Authenticated Content

    private var authenticatedContent: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                VStack(spacing: 0) {
                    // Storage optimization banner
                    if let recommendation = storageManager.optimizationRecommendation {
                        StorageOptimizationBanner(recommendation: recommendation) {
                            Task {
                                _ = await storageManager.executeOptimization()
                                syncEngine.refreshProgress()
                            }
                        } onDismiss: {
                            storageManager.optimizationRecommendation = nil
                        }
                    }

                    MediaHubView()
                }
            }
            .tabItem {
                Label("Library", systemImage: "photo.on.rectangle.angled")
            }
            .tag(Tab.library)

            NavigationStack {
                ChatView()
            }
            .tabItem {
                Label("Create", systemImage: "plus.circle.fill")
            }
            .tag(Tab.create)

            NavigationStack {
                ProjectsView()
            }
            .tabItem {
                Label("Projects", systemImage: "film.stack")
            }
            .tag(Tab.projects)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(Tab.settings)
        }
        .tint(Color.rcAccent)
        .fullScreenCover(isPresented: Binding(
            get: { !isOnboardingComplete },
            set: { isOnboardingComplete = !$0 }
        )) {
            OnboardingView(isOnboardingComplete: $isOnboardingComplete)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted from ProjectsView to switch to Create tab and resume a chat session.
    static let switchToCreateTab = Notification.Name("com.rawcut.switchToCreateTab")
}

// MARK: - Placeholder Views

private struct CreatePlaceholderView: View {
    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()
            EmptyStateView(
                icon: "plus.circle",
                title: "Create a Vlog",
                description: "Select footage, write a script, and let rawcut handle the rest."
            )
        }
        .navigationTitle("Create")
    }
}

private struct ProjectsPlaceholderView: View {
    var body: some View {
        ZStack {
            Color.rcBackground.ignoresSafeArea()
            EmptyStateView(
                icon: "film.stack",
                title: "No Projects Yet",
                description: "Your finished vlogs will appear here."
            )
        }
        .navigationTitle("Projects")
    }
}

// MARK: - UserDefaults Keys

extension UserDefaults {
    enum Keys {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }
}

// MARK: - Design Tokens

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

extension Color {
    static let rcBackground = Color(red: 0, green: 0, blue: 0)
    static let rcSurface = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)        // Apple secondarySystemBackground
    static let rcSurfaceElevated = Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255) // Apple tertiarySystemBackground
    static let rcAccent = Color.white
    static let rcAccentDim = Color(red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xA6 / 255)      // Apple systemGray2
    static let rcTextPrimary = Color.white
    static let rcTextSecondary = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)   // Apple systemGray
    static let rcTextTertiary = Color(red: 0x48 / 255, green: 0x48 / 255, blue: 0x4A / 255)    // Apple systemGray3
    static let rcError = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)            // Apple systemRed (dark)
    static let rcWarning = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)          // Apple systemOrange (dark)
    static let rcToggleTint = Color(red: 0x63 / 255, green: 0x63 / 255, blue: 0x66 / 255)     // Toggle track — contrasts with white knob
}

extension Font {
    // Display fonts — clean, modern
    static let rcDisplay = Font.system(size: 32, weight: .semibold, design: .default)
    static let rcDisplayMedium = Font.system(size: 26, weight: .semibold, design: .default)

    // Title fonts
    static let rcTitleLarge = Font.system(size: 28, weight: .medium, design: .default)
    static let rcTitleMedium = Font.system(size: 20, weight: .medium, design: .default)

    // Body + UI fonts
    static let rcBody = Font.system(size: 15, weight: .regular, design: .default)
    static let rcBodyMedium = Font.system(size: 15, weight: .medium, design: .default)
    static let rcCaption = Font.system(size: 12, weight: .regular, design: .default)
    static let rcCaptionBold = Font.system(size: 12, weight: .medium, design: .default)
    static let rcTabBar = Font.system(size: 10, weight: .medium, design: .default)

    // Accent font — clean monospaced for numbers, stats
    static let rcStat = Font.system(size: 24, weight: .medium, design: .monospaced)
}

#Preview {
    ContentView()
}
