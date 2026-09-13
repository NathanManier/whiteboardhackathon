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
                #if DEBUG
                if let reviewState = Self.graphReviewState {
                    GraphWorkspaceReviewView(state: reviewState)
                } else {
                    authenticatedRoot
                }
                #else
                authenticatedRoot
                #endif
            }
            .environmentObject(api)
            .environmentObject(auth)
            .onAppear { VBoardColdLaunchTrace.shared.event("app_scene_ready") }
        }
    }

    @ViewBuilder
    private var authenticatedRoot: some View {
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

    #if DEBUG
    private static var graphReviewState: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-VBoardGraphReview"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    #endif
}
