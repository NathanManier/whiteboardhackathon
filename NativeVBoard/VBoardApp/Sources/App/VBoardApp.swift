import SwiftUI

@main
struct VBoardApp: App {
    @StateObject private var api = APIClient.shared

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(api)
        }
    }
}
