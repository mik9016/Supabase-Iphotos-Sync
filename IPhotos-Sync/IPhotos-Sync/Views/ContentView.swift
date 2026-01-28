import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject private var syncManager = SyncManager.shared
    @ObservedObject private var photoLibrary = PhotoLibraryService.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var showSettings = false
    @State private var showSyncProgress = false
    @State private var showPhotoPicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                headerSection

                statusSection

                Spacer()

                actionSection

                Spacer()

                footerSection
            }
            .padding()
            .navigationTitle("IPhotos Sync")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showSyncProgress) {
                SyncProgressView()
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPickerView { selectedPhotos in
                    syncManager.startSync(with: selectedPhotos)
                }
            }
            .onChange(of: syncManager.isSyncing) { isSyncing in
                if isSyncing {
                    showSyncProgress = true
                }
            }
            .onAppear {
                checkAuthorization()
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    refreshPhotoCount()
                }
            }
        }
    }

    private func refreshPhotoCount() {
        Task {
            await photoLibrary.updatePhotoCount()
        }
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 60))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Sync Photos to S3")
                .font(.title2)
                .fontWeight(.semibold)
        }
        .padding(.top, 20)
    }

    private var statusSection: some View {
        VStack(spacing: 16) {
            statusCard(
                icon: "photo.on.rectangle.angled",
                title: "Photos Available",
                value: "\(photoLibrary.photoCount)",
                color: .blue
            )

            if settings.isConfigured {
                statusCard(
                    icon: "externaldrive.fill.badge.checkmark",
                    title: "Supabase Storage",
                    value: SupabaseAuthService.bucketName,
                    color: .green
                )
            } else {
                statusCard(
                    icon: "exclamationmark.triangle.fill",
                    title: "Storage",
                    value: "Not Configured",
                    color: .orange
                )
            }

            if let lastSync = settings.lastSyncDate {
                statusCard(
                    icon: "clock.fill",
                    title: "Last Sync",
                    value: lastSync.formatted(date: .abbreviated, time: .shortened),
                    color: .purple
                )
            }
        }
    }

    private func statusCard(icon: String, title: String, value: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(Constants.UI.cornerRadius)
    }

    private var actionSection: some View {
        VStack(spacing: 16) {
            Button {
                if settings.syncMode == .manual {
                    showPhotoPicker = true
                } else {
                    syncManager.startSync()
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Sync Now")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    syncManager.canSync ?
                    LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing) :
                    LinearGradient(colors: [.gray, .gray], startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(Constants.UI.cornerRadius)
            }
            .disabled(!syncManager.canSync)

            if !photoLibrary.authorizationStatus.canAccess {
                Button {
                    Task {
                        await photoLibrary.requestAuthorization()
                    }
                } label: {
                    HStack {
                        Image(systemName: "photo.badge.plus")
                        Text("Grant Photo Access")
                    }
                    .font(.subheadline)
                    .foregroundColor(.blue)
                }
            }
        }
    }

    private var footerSection: some View {
        VStack(spacing: 8) {
            if settings.syncMode == .manual {
                Text("Mode: Manual Selection")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Photos to sync: \(settings.photoCountSetting.displayValue) (oldest first)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !settings.isConfigured {
                Text("Configure S3 settings to start syncing")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.bottom)
    }

    private func checkAuthorization() {
        if photoLibrary.authorizationStatus == .notDetermined {
            Task {
                await photoLibrary.requestAuthorization()
            }
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
