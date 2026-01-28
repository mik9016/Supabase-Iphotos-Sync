import Foundation
import Photos
import UIKit

enum PhotoLibraryAuthorizationStatus {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted

    var canAccess: Bool {
        self == .authorized || self == .limited
    }
}

final class PhotoLibraryService: ObservableObject {
    static let shared = PhotoLibraryService()

    @Published var authorizationStatus: PhotoLibraryAuthorizationStatus = .notDetermined
    @Published var photoCount: Int = 0

    private init() {
        updateAuthorizationStatus()
    }

    func requestAuthorization() async -> PhotoLibraryAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let mappedStatus = mapAuthorizationStatus(status)

        await MainActor.run {
            self.authorizationStatus = mappedStatus
        }

        if mappedStatus.canAccess {
            await updatePhotoCount()
        }

        return mappedStatus
    }

    func updateAuthorizationStatus() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = mapAuthorizationStatus(status)

        if authorizationStatus.canAccess {
            Task {
                await updatePhotoCount()
            }
        }
    }

    private func mapAuthorizationStatus(_ status: PHAuthorizationStatus) -> PhotoLibraryAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .limited:
            return .limited
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }

    @MainActor
    func updatePhotoCount() async {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false

        let fetchResult = PHAsset.fetchAssets(with: options)
        photoCount = fetchResult.count
    }

    func fetchPhotos(limit: Int?) async -> [PhotoAsset] {
        guard authorizationStatus.canAccess else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false

        let fetchResult = PHAsset.fetchAssets(with: options)

        var photos: [PhotoAsset] = []
        let maxCount = limit ?? fetchResult.count

        fetchResult.enumerateObjects { asset, index, stop in
            if index >= maxCount {
                stop.pointee = true
                return
            }
            photos.append(PhotoAsset(asset: asset))
        }

        return photos
    }

    func fetchPhotos(count: PhotoCountSetting) async -> [PhotoAsset] {
        switch count {
        case .count(let limit):
            return await fetchPhotos(limit: limit)
        case .all:
            return await fetchPhotos(limit: nil)
        }
    }

    func deletePhotos(_ assets: [PhotoAsset]) async throws {
        let phAssets = assets.map { $0.asset }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(phAssets as NSFastEnumeration)
        }

        await updatePhotoCount()
    }

    func deletePhoto(_ asset: PhotoAsset) async throws {
        try await deletePhotos([asset])
    }

    func getImageData(for asset: PhotoAsset) async throws -> Data {
        try await asset.getImageData()
    }

    func getVideoData(for asset: PhotoAsset) async throws -> Data {
        let url = try await asset.getVideoURL()
        return try Data(contentsOf: url)
    }

    func getAssetData(for asset: PhotoAsset) async throws -> Data {
        if asset.isVideo {
            return try await getVideoData(for: asset)
        } else {
            return try await getImageData(for: asset)
        }
    }
}
