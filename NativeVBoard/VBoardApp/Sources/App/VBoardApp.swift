import SwiftUI

@main
struct VBoardApp: App {
    @StateObject private var api = APIClient.shared
    @StateObject private var auth = AuthSessionStore()

    init() {
        VBoardColdLaunchTrace.shared.event("process_start")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch auth.state {
                case .resolving:
                    ProgressView("Opening V-Board…")
                        .task { await auth.resolveLaunchSession() }
                case .signedIn(let user):
                    LibraryView(account: user)
                case .signedOut, .authenticating, .sessionExpired, .failed:
                    LoginView()
                }
            }
            .environmentObject(api)
            .environmentObject(auth)
            .onAppear { VBoardColdLaunchTrace.shared.event("app_scene_ready") }
        }
    }
}
