import Foundation
import SwiftData

@MainActor
final class LocalStore {

    static let shared = LocalStore()

    let container: ModelContainer

    private init() {
        let schema = Schema([
            MediaAsset.self,
        ])

        let configuration = ModelConfiguration(
            "RawcutStore",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            container = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        } catch {
            // Schema migration failed — delete the store and retry
            print("[Rawcut] ModelContainer failed: \(error.localizedDescription). Deleting store and retrying...")
            let storeURL = URL.applicationSupportDirectory
                .appendingPathComponent("RawcutStore.store")
            for suffix in ["", "-wal", "-shm"] {
                let fileURL = storeURL.appendingPathExtension(suffix.isEmpty ? "store" : suffix)
                try? FileManager.default.removeItem(at: fileURL)
            }
            // Also try the default SwiftData location
            let defaultURL = URL.applicationSupportDirectory
                .appendingPathComponent("default.store")
            try? FileManager.default.removeItem(at: defaultURL)

            do {
                container = try ModelContainer(
                    for: schema,
                    configurations: [configuration]
                )
            } catch {
                fatalError("[Rawcut] Failed to create ModelContainer after reset: \(error.localizedDescription)")
            }
        }
    }
}
