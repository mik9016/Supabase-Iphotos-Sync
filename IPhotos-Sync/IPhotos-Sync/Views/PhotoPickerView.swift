import SwiftUI
import Photos

struct PhotoPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var photoLibrary = PhotoLibraryService.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var allPhotos: [PhotoAsset] = []
    @State private var selectedPhotos: Set<String> = []  // asset IDs
    @State private var isLoading = true

    let onSync: ([PhotoAsset]) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Selection info bar
                HStack {
                    Text("\(selectedPhotos.count) selected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    if selectedPhotos.count > 0 {
                        Button("Clear") {
                            selectedPhotos.removeAll()
                        }
                        .font(.subheadline)
                    }

                    Button(selectedPhotos.count == allPhotos.count ? "Deselect All" : "Select All") {
                        if selectedPhotos.count == allPhotos.count {
                            selectedPhotos.removeAll()
                        } else {
                            selectedPhotos = Set(allPhotos.map { $0.id })
                        }
                    }
                    .font(.subheadline)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))

                // Photo grid
                if isLoading {
                    Spacer()
                    ProgressView("Loading photos...")
                    Spacer()
                } else if allPhotos.isEmpty {
                    Spacer()
                    Text("No photos available")
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(allPhotos) { photo in
                                PhotoThumbnailCell(
                                    photo: photo,
                                    isSelected: selectedPhotos.contains(photo.id)
                                )
                                .onTapGesture {
                                    toggleSelection(photo)
                                }
                            }
                        }
                        .padding(2)
                    }
                }
            }
            .navigationTitle("Select Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Sync \(selectedPhotos.count)") {
                        let photosToSync = allPhotos.filter { selectedPhotos.contains($0.id) }
                        dismiss()
                        onSync(photosToSync)
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedPhotos.isEmpty)
                }
            }
            .task {
                await loadPhotos()
            }
        }
    }

    private func toggleSelection(_ photo: PhotoAsset) {
        if selectedPhotos.contains(photo.id) {
            selectedPhotos.remove(photo.id)
        } else {
            // Limit selection to max count
            let maxCount = settings.photoCountSetting.intValue ?? 100
            if selectedPhotos.count < maxCount {
                selectedPhotos.insert(photo.id)
            }
        }
    }

    private func loadPhotos() async {
        isLoading = true
        // Load all photos for selection (not limited by count setting)
        allPhotos = await photoLibrary.fetchPhotos(count: .all)

        // Load thumbnails
        for photo in allPhotos {
            photo.loadThumbnail(size: CGSize(width: 200, height: 200))
        }

        isLoading = false
    }
}

struct PhotoThumbnailCell: View {
    @ObservedObject var photo: PhotoAsset
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail
            if let thumbnail = photo.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 80, maxHeight: 100)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 80, maxHeight: 100)
                    .overlay(
                        ProgressView()
                    )
            }

            // Video indicator
            if photo.isVideo {
                HStack(spacing: 2) {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                    if photo.asset.duration > 0 {
                        Text(formatDuration(photo.asset.duration))
                            .font(.caption2)
                    }
                }
                .foregroundColor(.white)
                .padding(4)
                .background(Color.black.opacity(0.6))
                .cornerRadius(4)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            // Selection indicator
            ZStack {
                Circle()
                    .fill(isSelected ? Color.blue : Color.white.opacity(0.8))
                    .frame(width: 24, height: 24)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Circle()
                        .stroke(Color.gray, lineWidth: 1)
                        .frame(width: 22, height: 22)
                }
            }
            .padding(6)
        }
        .overlay(
            isSelected ?
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.blue, lineWidth: 3)
            : nil
        )
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
