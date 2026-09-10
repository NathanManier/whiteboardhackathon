import AuthenticationServices
import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthSessionStore

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "rectangle.and.pencil.and.ellipsis")
                .font(.system(size: 62, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("V-Board")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Turn a whiteboard into an editable study canvas.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SignInWithAppleButton(.continue) { request in
                auth.prepare(request)
            } onCompletion: { result in
                Task { await auth.complete(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(width: 300, height: 52)
            .disabled(auth.state == .authenticating)
            if auth.state == .authenticating {
                ProgressView("Signing in…")
            }
            if case .failed(let message) = auth.state {
                VStack(spacing: 10) {
                    Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
                    Button("Try Again") { auth.returnToSignIn() }
                }
                .frame(maxWidth: 420)
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["VBOARD_SHOW_DEBUG_LOGIN"] == "1" {
                Button("Use Simulator Test Account") {
                    Task { await auth.signInAsSimulatorTestUser() }
                }
                .buttonStyle(.bordered)
            }
            #endif
            Spacer()
            HStack(spacing: 20) {
                Link("Privacy Policy", destination: URL(string: "https://chsinteract.com/privacy")!)
                Link("Terms", destination: URL(string: "https://chsinteract.com/terms")!)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}

struct AccountView: View {
    @EnvironmentObject private var auth: AuthSessionStore
    let user: AccountUser
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var deletionError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Name", value: user.displayName ?? "V-Board User")
                    if let email = user.email { LabeledContent("Email", value: email) }
                }
                Section {
                    Button("Sign Out") { Task { await auth.signOut(); dismiss() } }
                    Button("Delete Account", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Deleting your account permanently removes your lectures, boards, uploaded sources, generated vectors, notes, study history, and workspace layouts.")
                }
                if let deletionError {
                    Section { Text(deletionError).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Account")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog(
                "Permanently delete your V-Board account?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Account and All Data", role: .destructive) {
                    Task {
                        do { try await auth.deleteAccount(); dismiss() }
                        catch { deletionError = "Couldn’t delete your account. Please try again." }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
        }
    }
}
