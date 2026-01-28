import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var authService = SupabaseAuthService.shared

    @State private var isTestingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?
    @State private var isSigningOut = false

    enum ConnectionTestResult {
        case success
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                syncConfigurationSection
                connectionTestSection
                signOutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var accountSection: some View {
        Section {
            HStack {
                Label("Email", systemImage: "envelope")
                Spacer()
                Text(authService.userEmail ?? "Unknown")
                    .foregroundColor(.secondary)
            }

            HStack {
                Label("User ID", systemImage: "person")
                Spacer()
                Text(authService.userId?.prefix(8).appending("...") ?? "Unknown")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Photos are uploaded to your personal folder in the cloud.")
        }
    }

    private var syncConfigurationSection: some View {
        Section {
            Picker("Sync Mode", selection: $settings.syncMode) {
                ForEach(SyncMode.allCases, id: \.self) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                }
            }

            if settings.syncMode == .auto {
                Picker("Photos to Sync", selection: $settings.photoCountSetting) {
                    ForEach(PhotoCountSetting.presets, id: \.displayValue) { preset in
                        Text(preset.displayValue)
                            .tag(preset)
                    }
                }
            }
        } header: {
            Text("Sync Configuration")
        } footer: {
            if settings.syncMode == .auto {
                Text("Oldest photos will be uploaded first. After successful upload, photos are permanently deleted from your device.")
            } else {
                Text("Manually select which photos to sync. After successful upload, photos are permanently deleted from your device.")
            }
        }
    }

    private var connectionTestSection: some View {
        Section {
            Button {
                testConnection()
            } label: {
                HStack {
                    if isTestingConnection {
                        ProgressView()
                            .padding(.trailing, 8)
                    }
                    Text(isTestingConnection ? "Testing..." : "Test Connection")
                }
            }
            .disabled(isTestingConnection)

            if let result = connectionTestResult {
                switch result {
                case .success:
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Connection successful")
                            .foregroundColor(.green)
                    }
                case .failure(let error):
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text("Connection failed")
                                .foregroundColor(.red)
                        }
                        Text(error)
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
        } header: {
            Text("Connection Test")
        }
    }

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                signOut()
            } label: {
                HStack {
                    if isSigningOut {
                        ProgressView()
                            .padding(.trailing, 8)
                    }
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text(isSigningOut ? "Signing Out..." : "Sign Out")
                }
            }
            .disabled(isSigningOut)
        } header: {
            Text("Account Actions")
        }
    }

    private func testConnection() {
        isTestingConnection = true
        connectionTestResult = nil

        Task {
            let result = await SyncManager.shared.testConnection()

            await MainActor.run {
                isTestingConnection = false
                switch result {
                case .success:
                    connectionTestResult = .success
                case .failure(let error):
                    connectionTestResult = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func signOut() {
        isSigningOut = true

        Task {
            do {
                try await authService.signOut()
                settings.clearAll()
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSigningOut = false
                }
            }
        }
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
#endif
