import Foundation
import Photos
import UIKit
import AVFoundation

enum UploadStatus: Equatable {
    case pending
    case uploading(progress: Double)
    case uploaded
    case failed(error: String)

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    var isUploading: Bool {
        if case .uploading = self { return true }
        return false
    }

    var isUploaded: Bool {
        if case .uploaded = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

final class PhotoAsset: Identifiable, ObservableObject {
    let id: String
    let asset: PHAsset
    let creationDate: Date

    @Published var uploadStatus: UploadStatus = .pending
    @Published var thumbnail: UIImage?

    var filename: String {
        // Create a short unique suffix from asset ID to handle duplicate filenames
        let uniqueSuffix = String(asset.localIdentifier.prefix(8))
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "-", with: "")

        if let resource = PHAssetResource.assetResources(for: asset).first {
            let originalName = resource.originalFilename
            let url = URL(fileURLWithPath: originalName)
            let ext = url.pathExtension
            let name = url.deletingPathExtension().lastPathComponent
            // Append unique suffix: "photo.jpg" -> "photo-ABC123.jpg"
            return ext.isEmpty ? "\(name)-\(uniqueSuffix)" : "\(name)-\(uniqueSuffix).\(ext)"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateString = formatter.string(from: creationDate)
        let ext = asset.mediaType == .video ? "mov" : "jpg"
        return "IMG_\(dateString)-\(uniqueSuffix).\(ext)"
    }

    var fileExtension: String {
        let resources = PHAssetResource.assetResources(for: asset)
        if let resource = resources.first {
            let filename = resource.originalFilename
            if let ext = filename.split(separator: ".").last {
                return String(ext).lowercased()
            }
        }
        return asset.mediaType == .video ? "mov" : "jpg"
    }

    var mimeType: String {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "heic":
            return "image/heic"
        case "gif":
            return "image/gif"
        case "mov":
            return "video/quicktime"
        case "mp4":
            return "video/mp4"
        default:
            return "application/octet-stream"
        }
    }

    var isVideo: Bool {
        asset.mediaType == .video
    }

    var isImage: Bool {
        asset.mediaType == .image
    }

    init(asset: PHAsset) {
        self.id = asset.localIdentifier
        self.asset = asset
        self.creationDate = asset.creationDate ?? Date.distantPast
    }

    func loadThumbnail(size: CGSize = CGSize(width: 100, height: 100)) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: size,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            DispatchQueue.main.async {
                self?.thumbnail = image
            }
        }
    }

    func getImageData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: PhotoAssetError.dataNotAvailable)
                }
            }
        }
    }

    func getVideoURL() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.version = .current

            // Use requestExportSession for better compatibility with all video formats
            PHImageManager.default().requestExportSession(
                forVideo: asset,
                options: options,
                exportPreset: AVAssetExportPresetPassthrough
            ) { exportSession, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let exportSession = exportSession else {
                    // Fallback to AVAsset method
                    PHImageManager.default().requestAVAsset(
                        forVideo: self.asset,
                        options: options
                    ) { avAsset, _, info in
                        if let error = info?[PHImageErrorKey] as? Error {
                            continuation.resume(throwing: error)
                        } else if let urlAsset = avAsset as? AVURLAsset {
                            continuation.resume(returning: urlAsset.url)
                        } else {
                            continuation.resume(throwing: PhotoAssetError.videoURLNotAvailable)
                        }
                    }
                    return
                }

                // Export to temp file
                let tempDir = FileManager.default.temporaryDirectory
                let outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".mov")

                exportSession.outputURL = outputURL
                exportSession.outputFileType = .mov

                exportSession.exportAsynchronously {
                    switch exportSession.status {
                    case .completed:
                        continuation.resume(returning: outputURL)
                    case .failed:
                        continuation.resume(throwing: exportSession.error ?? PhotoAssetError.videoURLNotAvailable)
                    case .cancelled:
                        continuation.resume(throwing: PhotoAssetError.videoURLNotAvailable)
                    default:
                        continuation.resume(throwing: PhotoAssetError.videoURLNotAvailable)
                    }
                }
            }
        }
    }
}

enum PhotoAssetError: LocalizedError {
    case dataNotAvailable
    case videoURLNotAvailable

    var errorDescription: String? {
        switch self {
        case .dataNotAvailable:
            return "Unable to retrieve photo data"
        case .videoURLNotAvailable:
            return "Unable to retrieve video URL"
        }
    }
}
