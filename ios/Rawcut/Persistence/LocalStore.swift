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
            fatalError("[Rawcut] Failed to create ModelContainer: \(error.localizedDescription)")
        }
    }
}
