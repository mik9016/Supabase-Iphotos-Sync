import SwiftUI

struct SyncProgressView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var syncManager = SyncManager.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch syncManager.state {
                case .idle:
                    idleView
                case .preparingPhotos:
                    preparingView
                case .syncing(let current, let total, let currentPhoto):
                    syncingView(current: current, total: total, currentPhoto: currentPhoto)
                case .completed(let uploaded, let deleted):
                    completedView(uploaded: uploaded, deleted: deleted)
                case .error(let message):
                    errorView(message: message)
                case .cancelled:
                    cancelledView
                }

                if !syncManager.photosToSync.isEmpty && syncManager.isSyncing {
                    PhotoGridView(photos: syncManager.photosToSync)
                        .frame(maxHeight: 200)
                }

                Spacer()

                actionButtons
            }
            .padding()
            .navigationTitle("Sync Progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !syncManager.isSyncing {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(syncManager.isSyncing)
        }
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "cloud")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text("Ready to Sync")
                .font(.title2)
                .fontWeight(.semibold)
        }
    }

    private var preparingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Preparing Photos...")
                .font(.title3)
                .foregroundColor(.secondary)
        }
    }

    private func syncingView(current: Int, total: Int, currentPhoto: String) -> some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: CGFloat(current - 1) / CGFloat(total) + (syncManager.currentPhotoProgress / CGFloat(total)))
                    .stroke(
                        LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: syncManager.currentPhotoProgress)

                VStack {
                    Text("\(current)")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("of \(total)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack(spacing: 8) {
                Text("Uploading...")
                    .font(.headline)
                Text(currentPhoto)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                ProgressView(value: syncManager.currentPhotoProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
            }
        }
    }

    private func completedView(uploaded: Int, deleted: Int) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Sync Complete")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(.blue)
                    Text("\(uploaded) photos uploaded")
                }

                HStack {
                    Image(systemName: "trash.circle.fill")
                        .foregroundColor(.orange)
                    Text("\(deleted) photos deleted")
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text("Sync Failed")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var cancelledView: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("Sync Cancelled")
                .font(.title2)
                .fontWeight(.semibold)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if syncManager.isSyncing {
                Button(role: .destructive) {
                    syncManager.cancelSync()
                } label: {
                    HStack {
                        Image(systemName: "xmark")
                        Text("Cancel Sync")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .cornerRadius(Constants.UI.cornerRadius)
                }
            } else {
                switch syncManager.state {
                case .error, .cancelled:
                    Button {
                        syncManager.startSync()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(Constants.UI.cornerRadius)
                    }
                case .completed:
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(Constants.UI.cornerRadius)
                    }
                default:
                    EmptyView()
                }
            }
        }
        .padding(.bottom)
    }
}

#if DEBUG
struct SyncProgressView_Previews: PreviewProvider {
    static var previews: some View {
        SyncProgressView()
    }
}
#endif
