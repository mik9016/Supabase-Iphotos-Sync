import Foundation
import Combine
import UIKit

enum SyncState: Equatable {
    case idle
    case preparingPhotos
    case syncing(current: Int, total: Int, currentPhoto: String)
    case completed(uploaded: Int, deleted: Int)
    case error(String)
    case cancelled

    static func == (lhs: SyncState, rhs: SyncState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.preparingPhotos, .preparingPhotos):
            return true
        case let (.syncing(c1, t1, p1), .syncing(c2, t2, p2)):
            return c1 == c2 && t1 == t2 && p1 == p2
        case let (.completed(u1, d1), .completed(u2, d2)):
            return u1 == u2 && d1 == d2
        case let (.error(e1), .error(e2)):
            return e1 == e2
        case (.cancelled, .cancelled):
            return true
        default:
            return false
        }
    }
}

final class SyncManager: ObservableObject, BackgroundUploadDelegate, TUSUploadDelegate {
    static let shared = SyncManager()

    @Published var state: SyncState = .idle
    @Published var currentPhotoProgress: Double = 0
    @Published var photosToSync: [PhotoAsset] = []

    private let photoLibrary = PhotoLibraryService.shared
    private let backgroundUploader = BackgroundUploadManager.shared
    private let tusUploader = TUSUploadManager.shared
    private let metadataService = PhotoMetadataService.shared
    private let settings = AppSettings.shared

    // For manual photo selection
    private var manuallySelectedPhotos: [PhotoAsset]?

    private var syncTask: Task<Void, Never>?
    private var isCancelled = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // Track uploads for background mode
    private var pendingPhotos: [String: PhotoAsset] = [:] // filename -> PhotoAsset
    private var pendingVideoCount = 0  // Track TUS video uploads separately
    private var uploadedPhotos: [PhotoAsset] = []
    private var failedCount = 0
    private var totalPhotosToSync = 0
    private var lastError: String?
    private var hasCompletedDeletion = false

    private init() {
        backgroundUploader.delegate = self
        tusUploader.delegate = self
    }

    var isSyncing: Bool {
        if case .syncing = state { return true }
        if case .preparingPhotos = state { return true }
        return false
    }

    var canSync: Bool {
        return settings.isConfigured && photoLibrary.authorizationStatus.canAccess && !isSyncing
    }

    @MainActor
    func startSync() {
        guard canSync else { return }

        isCancelled = false
        pendingPhotos.removeAll()
        pendingVideoCount = 0
        uploadedPhotos.removeAll()
        failedCount = 0
        lastError = nil
        hasCompletedDeletion = false

        // Reset background uploader state
        backgroundUploader.resetState()
        tusUploader.cancelAllUploads()

        // Keep screen awake during sync
        UIApplication.shared.isIdleTimerDisabled = true

        // Request background execution time
        beginBackgroundTask()

        syncTask = Task {
            // Refresh token before starting to ensure we have a fresh token
            do {
                try await SupabaseAuthService.shared.refreshAccessToken()
                #if DEBUG
                print("Token refreshed before sync")
                #endif
            } catch {
                #if DEBUG
                print("Token refresh failed: \(error.localizedDescription)")
                #endif
            }
            await performSync()
        }
    }

    /// Start sync with manually selected photos
    @MainActor
    func startSync(with photos: [PhotoAsset]) {
        manuallySelectedPhotos = photos
        startSync()
    }

    @MainActor
    func cancelSync() {
        isCancelled = true
        syncTask?.cancel()
        backgroundUploader.cancelAllUploads()
        tusUploader.cancelAllUploads()
        state = .cancelled

        // Re-enable screen sleep and end background task
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
    }

    private func beginBackgroundTask() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PhotoSync") { [weak self] in
            // Called when time is about to expire - but background uploads will continue
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    @MainActor
    private func performSync() async {
        state = .preparingPhotos
        photosToSync = []
        currentPhotoProgress = 0

        // Use manually selected photos or fetch automatically
        let photos: [PhotoAsset]
        if let manual = manuallySelectedPhotos {
            photos = manual
            manuallySelectedPhotos = nil  // Clear after use
        } else {
            photos = await photoLibrary.fetchPhotos(count: settings.photoCountSetting)
        }

        if photos.isEmpty {
            state = .completed(uploaded: 0, deleted: 0)
            settings.lastSyncDate = Date()
            UIApplication.shared.isIdleTimerDisabled = false
            endBackgroundTask()
            return
        }

        photosToSync = photos
        totalPhotosToSync = photos.count

        // Load thumbnails
        for photo in photos {
            photo.loadThumbnail()
        }

        // Queue all uploads
        for (index, photo) in photos.enumerated() {
            if isCancelled {
                state = .cancelled
                UIApplication.shared.isIdleTimerDisabled = false
                endBackgroundTask()
                return
            }

            state = .syncing(current: index + 1, total: photos.count, currentPhoto: photo.filename)
            photo.uploadStatus = .uploading(progress: 0)

            // Track this photo
            pendingPhotos[photo.filename] = photo

            if photo.isVideo {
                // For videos: use TUS resumable uploads (handles large files reliably)
                pendingVideoCount += 1
                tusUploader.uploadVideo(
                    asset: photo.asset,
                    filename: photo.filename,
                    contentType: photo.mimeType
                )
            } else {
                // For images: load data (usually small enough)
                do {
                    let data = try await photoLibrary.getImageData(for: photo)
                    backgroundUploader.queueUpload(
                        data: data,
                        filename: photo.filename,
                        contentType: photo.mimeType
                    )
                } catch {
                    photo.uploadStatus = .failed(error: error.localizedDescription)
                    pendingPhotos.removeValue(forKey: photo.filename)
                    lastError = error.localizedDescription
                    failedCount += 1
                    print("Error preparing \(photo.filename): \(error.localizedDescription)")
                }
            }
        }

        // Update state to show we're uploading
        let queuedCount = pendingPhotos.count
        if queuedCount > 0 {
            state = .syncing(current: 1, total: queuedCount, currentPhoto: "Uploading...")
        }
    }

    // MARK: - BackgroundUploadDelegate

    func uploadDidComplete(filename: String, success: Bool, error: String?) {
        guard let photo = pendingPhotos.removeValue(forKey: filename) else { return }

        if success {
            photo.uploadStatus = .uploaded
            uploadedPhotos.append(photo)
            #if DEBUG
            print("Upload completed: \(filename)")
            #endif

            // Save metadata to database
            saveMetadata(for: photo)
        } else {
            photo.uploadStatus = .failed(error: error ?? "Unknown error")
            lastError = error
            failedCount += 1
            print("Upload failed: \(filename) - \(error ?? "Unknown error")")
        }

        // Update progress
        let completed = uploadedPhotos.count + failedCount

        state = .syncing(current: completed, total: totalPhotosToSync, currentPhoto: filename)

        // Check if all done (background uploader will call allUploadsCompleted separately)
    }

    func uploadDidProgress(filename: String, progress: Double) {
        if let photo = pendingPhotos[filename] {
            photo.uploadStatus = .uploading(progress: progress)
            currentPhotoProgress = progress
        }
    }

    func allUploadsCompleted() {
        Task { @MainActor in
            // Prevent multiple completion calls
            guard !hasCompletedDeletion else {
                #if DEBUG
                print("allUploadsCompleted called but already completed deletion")
                #endif
                return
            }

            // Make sure TUS uploads are also done
            guard pendingVideoCount <= 0 else {
                #if DEBUG
                print("Background uploads done, but \(pendingVideoCount) TUS uploads still pending")
                #endif
                return
            }

            hasCompletedDeletion = true

            // Delete all successfully uploaded photos at once (single dialog)
            var deletedCount = 0
            let photosToDelete = uploadedPhotos

            if !photosToDelete.isEmpty {
                do {
                    try await photoLibrary.deletePhotos(photosToDelete)
                    deletedCount = photosToDelete.count
                    #if DEBUG
                    print("Deleted \(deletedCount) photos")
                    #endif
                } catch {
                    print("Error deleting photos: \(error.localizedDescription)")
                    // Photos uploaded but deletion failed - still report uploads as success
                }
            }

            // Update final state
            let uploadedCount = uploadedPhotos.count

            if uploadedCount == 0 && lastError != nil {
                state = .error(lastError!)
            } else {
                state = .completed(uploaded: uploadedCount, deleted: deletedCount)
                settings.lastSyncDate = Date()
            }

            // Cleanup
            photosToSync = []
            pendingPhotos.removeAll()
            uploadedPhotos.removeAll()

            // Re-enable screen sleep
            UIApplication.shared.isIdleTimerDisabled = false
            endBackgroundTask()

            #if DEBUG
            print("Sync completed: \(uploadedCount) uploaded, \(deletedCount) deleted, \(failedCount) failed")
            #endif
        }
    }

    func testConnection() async -> Result<Bool, Error> {
        do {
            let success = try await SupabaseStorageService.shared.testConnection()
            return .success(success)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - TUSUploadDelegate

    func tusUploadDidProgress(filename: String, progress: Double) {
        if let photo = pendingPhotos[filename] {
            photo.uploadStatus = .uploading(progress: progress)
            currentPhotoProgress = progress
        }
    }

    func tusUploadDidComplete(filename: String, success: Bool, error: String?) {
        pendingVideoCount -= 1

        guard let photo = pendingPhotos.removeValue(forKey: filename) else {
            checkAllCompleted()
            return
        }

        if success {
            photo.uploadStatus = .uploaded
            uploadedPhotos.append(photo)
            #if DEBUG
            print("TUS upload completed: \(filename)")
            #endif

            // Save metadata to database
            saveMetadata(for: photo)
        } else {
            photo.uploadStatus = .failed(error: error ?? "Unknown error")
            lastError = error
            failedCount += 1
            print("TUS upload failed: \(filename) - \(error ?? "Unknown error")")
        }

        // Update progress
        let completed = uploadedPhotos.count + failedCount
        state = .syncing(current: completed, total: totalPhotosToSync, currentPhoto: filename)

        checkAllCompleted()
    }

    private func saveMetadata(for photo: PhotoAsset) {
        guard let userId = SupabaseAuthService.shared.userId else { return }

        let storagePath = "\(SupabaseAuthService.bucketName)/\(userId)/\(photo.filename)"

        Task {
            do {
                try await metadataService.saveMetadata(for: photo, storagePath: storagePath)
            } catch {
                #if DEBUG
                print("Failed to save metadata for \(photo.filename): \(error.localizedDescription)")
                #endif
                // Don't fail the sync - metadata is supplementary
            }
        }
    }

    private func checkAllCompleted() {
        // Check if all uploads (both background and TUS) are done
        let backgroundDone = backgroundUploader.activeUploadCount == 0 && backgroundUploader.queuedUploadCount == 0
        let tusDone = pendingVideoCount <= 0

        if backgroundDone && tusDone && pendingPhotos.isEmpty {
            allUploadsCompleted()
        }
    }
}
