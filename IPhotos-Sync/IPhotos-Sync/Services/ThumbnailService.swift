import Foundation
import Photos
import UIKit
import AVFoundation

/// Service for generating JPEG thumbnails from photos and videos
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let thumbnailSize = CGSize(width: 400, height: 400)
    private let jpegQuality: CGFloat = 0.7

    private init() {}

    /// Generate a JPEG thumbnail for a PHAsset (photo or video)
    func generateThumbnail(for asset: PHAsset) async -> Data? {
        if asset.mediaType == .video {
            return await generateVideoThumbnail(for: asset)
        } else {
            return await generatePhotoThumbnail(for: asset)
        }
    }

    /// Generate thumbnail for a photo asset (handles HEIC, JPEG, PNG, etc.)
    private func generatePhotoThumbnail(for asset: PHAsset) async -> Data? {
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.resizeMode = .exact

            // Calculate target size maintaining aspect ratio
            let aspectRatio = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
            var targetSize: CGSize

            if aspectRatio > 1 {
                // Landscape
                targetSize = CGSize(width: thumbnailSize.width, height: thumbnailSize.width / aspectRatio)
            } else {
                // Portrait or square
                targetSize = CGSize(width: thumbnailSize.height * aspectRatio, height: thumbnailSize.height)
            }

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard let image = image else {
                    continuation.resume(returning: nil)
                    return
                }

                // Convert to JPEG data
                let jpegData = image.jpegData(compressionQuality: self.jpegQuality)
                continuation.resume(returning: jpegData)
            }
        }
    }

    /// Generate thumbnail for a video asset (extracts frame at 0.5 seconds or first frame)
    private func generateVideoThumbnail(for asset: PHAsset) async -> Data? {
        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: options
            ) { avAsset, _, _ in
                guard let avAsset = avAsset else {
                    continuation.resume(returning: nil)
                    return
                }

                let imageGenerator = AVAssetImageGenerator(asset: avAsset)
                imageGenerator.appliesPreferredTrackTransform = true
                imageGenerator.maximumSize = self.thumbnailSize

                // Try to get frame at 0.5 seconds, or first frame
                let time = CMTime(seconds: 0.5, preferredTimescale: 600)

                do {
                    let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
                    let uiImage = UIImage(cgImage: cgImage)
                    let jpegData = uiImage.jpegData(compressionQuality: self.jpegQuality)
                    continuation.resume(returning: jpegData)
                } catch {
                    // Try first frame if 0.5s fails
                    do {
                        let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
                        let uiImage = UIImage(cgImage: cgImage)
                        let jpegData = uiImage.jpegData(compressionQuality: self.jpegQuality)
                        continuation.resume(returning: jpegData)
                    } catch {
                        #if DEBUG
                        print("Failed to generate video thumbnail: \(error.localizedDescription)")
                        #endif
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}
