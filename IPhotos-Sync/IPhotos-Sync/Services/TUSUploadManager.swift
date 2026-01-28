import Foundation
import Photos
import AVFoundation

protocol TUSUploadDelegate: AnyObject {
    func tusUploadDidProgress(filename: String, progress: Double)
    func tusUploadDidComplete(filename: String, success: Bool, error: String?)
}

/// TUS (resumable upload) manager for large video files
final class TUSUploadManager {
    static let shared = TUSUploadManager()

    weak var delegate: TUSUploadDelegate?

    private let chunkSize: Int = 5 * 1024 * 1024  // 5MB chunks
    private let tusVersion = "1.0.0"

    private var activeUploads: [String: TUSUploadState] = [:]
    private let uploadQueue = DispatchQueue(label: "com.iphotos.tus.upload", qos: .userInitiated)

    private let tempDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tus-uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    struct TUSUploadState {
        let filename: String
        let fileURL: URL
        let fileSize: Int64
        var uploadURL: URL?
        var offset: Int64 = 0
        var retryCount: Int = 0
        let contentType: String
    }

    private init() {}

    // MARK: - Public API

    /// Start a TUS upload for a video file
    func uploadVideo(fileURL: URL, filename: String, contentType: String) {
        uploadQueue.async { [weak self] in
            self?.startTUSUpload(fileURL: fileURL, filename: filename, contentType: contentType)
        }
    }

    /// Upload video from PHAsset (exports first, then uploads via TUS)
    func uploadVideo(asset: PHAsset, filename: String, contentType: String) {
        exportVideoAndUpload(asset: asset, filename: filename, contentType: contentType)
    }

    func cancelUpload(filename: String) {
        activeUploads.removeValue(forKey: filename)
    }

    func cancelAllUploads() {
        activeUploads.removeAll()
    }

    // MARK: - Video Export

    private func exportVideoAndUpload(asset: PHAsset, filename: String, contentType: String) {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        PHImageManager.default().requestExportSession(
            forVideo: asset,
            options: options,
            exportPreset: AVAssetExportPresetPassthrough
        ) { [weak self] exportSession, info in
            guard let self = self else { return }

            if let error = info?[PHImageErrorKey] as? Error {
                self.notifyFailure(filename: filename, error: "Export failed: \(error.localizedDescription)")
                return
            }

            guard let exportSession = exportSession else {
                self.notifyFailure(filename: filename, error: "Failed to get export session")
                return
            }

            let outputURL = self.tempDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mov

            exportSession.exportAsynchronously { [weak self] in
                guard let self = self else { return }

                switch exportSession.status {
                case .completed:
                    #if DEBUG
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                       let size = attrs[.size] as? Int64 {
                        print("TUS: Video exported for \(filename) - Size: \(size / 1_000_000) MB")
                    }
                    #endif
                    self.uploadQueue.async {
                        self.startTUSUpload(fileURL: outputURL, filename: filename, contentType: contentType)
                    }
                case .failed:
                    self.notifyFailure(filename: filename, error: exportSession.error?.localizedDescription ?? "Export failed")
                case .cancelled:
                    self.notifyFailure(filename: filename, error: "Export cancelled")
                default:
                    self.notifyFailure(filename: filename, error: "Export failed with status: \(exportSession.status.rawValue)")
                }
            }
        }
    }

    // MARK: - TUS Protocol Implementation

    private func startTUSUpload(fileURL: URL, filename: String, contentType: String) {
        guard let fileSize = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 else {
            notifyFailure(filename: filename, error: "Cannot determine file size")
            return
        }

        let state = TUSUploadState(
            filename: filename,
            fileURL: fileURL,
            fileSize: fileSize,
            contentType: contentType
        )

        activeUploads[filename] = state

        #if DEBUG
        print("TUS: Starting upload for \(filename), size: \(fileSize / 1_000_000) MB")
        #endif

        // Step 1: Create the upload
        createTUSUpload(state: state)
    }

    /// Step 1: POST to create upload and get upload URL
    private func createTUSUpload(state: TUSUploadState) {
        guard let accessToken = SupabaseAuthService.shared.accessToken else {
            notifyFailure(filename: state.filename, error: "Not authenticated")
            return
        }

        let bucketName = SupabaseAuthService.bucketName
        let folderPath = SupabaseAuthService.shared.userFolderPath
        let sanitizedFilename = sanitizeFilename(state.filename)
        let objectPath = folderPath + sanitizedFilename

        // Encode metadata as base64
        let metadata = [
            "bucketName": bucketName,
            "objectName": objectPath,
            "contentType": state.contentType,
            "cacheControl": "3600"
        ]
        let metadataString = metadata.map { key, value in
            let base64Value = Data(value.utf8).base64EncodedString()
            return "\(key) \(base64Value)"
        }.joined(separator: ",")

        guard let url = URL(string: "\(SupabaseAuthService.shared.storageAPIURL)/upload/resumable") else {
            notifyFailure(filename: state.filename, error: "Invalid TUS URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tusVersion, forHTTPHeaderField: "Tus-Resumable")
        request.setValue("\(state.fileSize)", forHTTPHeaderField: "Upload-Length")
        request.setValue(metadataString, forHTTPHeaderField: "Upload-Metadata")
        request.setValue("true", forHTTPHeaderField: "x-upsert")

        #if DEBUG
        print("TUS: Creating upload at \(url)")
        #endif

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                self.handleCreateError(state: state, error: error.localizedDescription)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.handleCreateError(state: state, error: "Invalid response")
                return
            }

            #if DEBUG
            print("TUS: Create response status: \(httpResponse.statusCode)")
            if let data = data, let body = String(data: data, encoding: .utf8) {
                print("TUS: Create response body: \(body)")
            }
            #endif

            if httpResponse.statusCode == 409 {
                // File already exists on server - treat as success
                #if DEBUG
                print("TUS: File already exists on server: \(state.filename)")
                #endif
                self.uploadComplete(state: state)
                return
            }

            if httpResponse.statusCode == 201,
               let locationHeader = httpResponse.value(forHTTPHeaderField: "Location"),
               let uploadURL = URL(string: locationHeader, relativeTo: url) {

                var updatedState = state
                updatedState.uploadURL = uploadURL.absoluteURL
                self.activeUploads[state.filename] = updatedState

                #if DEBUG
                print("TUS: Upload URL created: \(uploadURL.absoluteURL)")
                #endif

                // Step 2: Start uploading chunks
                self.uploadNextChunk(state: updatedState)
            } else {
                var errorMsg = "Failed to create upload (HTTP \(httpResponse.statusCode))"
                if let data = data, let body = String(data: data, encoding: .utf8) {
                    errorMsg += ": \(body)"
                }
                self.handleCreateError(state: state, error: errorMsg)
            }
        }
        task.resume()
    }

    /// Step 2: PATCH to upload chunks
    private func uploadNextChunk(state: TUSUploadState) {
        guard let uploadURL = state.uploadURL else {
            notifyFailure(filename: state.filename, error: "No upload URL")
            return
        }

        guard let accessToken = SupabaseAuthService.shared.accessToken else {
            notifyFailure(filename: state.filename, error: "Not authenticated")
            return
        }

        // Check if upload is complete
        if state.offset >= state.fileSize {
            uploadComplete(state: state)
            return
        }

        // Read next chunk
        guard let fileHandle = try? FileHandle(forReadingFrom: state.fileURL) else {
            notifyFailure(filename: state.filename, error: "Cannot read file")
            return
        }

        defer { try? fileHandle.close() }

        try? fileHandle.seek(toOffset: UInt64(state.offset))
        let chunkData = fileHandle.readData(ofLength: chunkSize)

        if chunkData.isEmpty {
            uploadComplete(state: state)
            return
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tusVersion, forHTTPHeaderField: "Tus-Resumable")
        request.setValue("\(state.offset)", forHTTPHeaderField: "Upload-Offset")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(chunkData.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = chunkData

        // Longer timeout for chunk uploads
        request.timeoutInterval = 300  // 5 minutes per chunk

        #if DEBUG
        let progress = Double(state.offset) / Double(state.fileSize) * 100
        print("TUS: Uploading chunk at offset \(state.offset), progress: \(String(format: "%.1f", progress))%")
        #endif

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                self.handleChunkError(state: state, error: error.localizedDescription)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.handleChunkError(state: state, error: "Invalid response")
                return
            }

            if httpResponse.statusCode == 204 || httpResponse.statusCode == 200 || httpResponse.statusCode == 409 {
                // Success - 409 means file already exists (already uploaded)
                if httpResponse.statusCode == 409 {
                    #if DEBUG
                    print("TUS: File already exists on server, treating as success: \(state.filename)")
                    #endif
                    self.uploadComplete(state: state)
                    return
                }
                // Success - get new offset from response
                let newOffset: Int64
                if let offsetHeader = httpResponse.value(forHTTPHeaderField: "Upload-Offset"),
                   let offset = Int64(offsetHeader) {
                    newOffset = offset
                } else {
                    newOffset = state.offset + Int64(chunkData.count)
                }

                var updatedState = state
                updatedState.offset = newOffset
                updatedState.retryCount = 0  // Reset retry count on success
                self.activeUploads[state.filename] = updatedState

                // Report progress
                let progress = Double(newOffset) / Double(state.fileSize)
                DispatchQueue.main.async {
                    self.delegate?.tusUploadDidProgress(filename: state.filename, progress: progress)
                }

                // Upload next chunk
                self.uploadNextChunk(state: updatedState)
            } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                // Auth error - refresh token and retry
                Task {
                    try? await SupabaseAuthService.shared.refreshAccessToken()
                    self.handleChunkError(state: state, error: "Auth expired, retrying...")
                }
            } else {
                var errorMsg = "Chunk upload failed (HTTP \(httpResponse.statusCode))"
                if let data = data, let body = String(data: data, encoding: .utf8) {
                    errorMsg += ": \(body)"
                }
                self.handleChunkError(state: state, error: errorMsg)
            }
        }
        task.resume()
    }

    // MARK: - Error Handling

    private func handleCreateError(state: TUSUploadState, error: String) {
        #if DEBUG
        print("TUS: Create error for \(state.filename): \(error)")
        #endif

        var updatedState = state
        updatedState.retryCount += 1

        if updatedState.retryCount < 3 {
            activeUploads[state.filename] = updatedState
            // Retry after delay
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.createTUSUpload(state: updatedState)
            }
        } else {
            notifyFailure(filename: state.filename, error: error)
        }
    }

    private func handleChunkError(state: TUSUploadState, error: String) {
        #if DEBUG
        print("TUS: Chunk error for \(state.filename): \(error)")
        #endif

        var updatedState = state
        updatedState.retryCount += 1

        if updatedState.retryCount < 5 {  // More retries for chunks
            activeUploads[state.filename] = updatedState
            // Retry after delay (exponential backoff)
            let delay = Double(updatedState.retryCount) * 2.0
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.uploadNextChunk(state: updatedState)
            }
        } else {
            notifyFailure(filename: state.filename, error: error)
        }
    }

    private func uploadComplete(state: TUSUploadState) {
        #if DEBUG
        print("TUS: Upload complete for \(state.filename)")
        #endif

        // Cleanup
        activeUploads.removeValue(forKey: state.filename)
        try? FileManager.default.removeItem(at: state.fileURL)

        DispatchQueue.main.async {
            self.delegate?.tusUploadDidComplete(filename: state.filename, success: true, error: nil)
        }
    }

    private func notifyFailure(filename: String, error: String) {
        #if DEBUG
        print("TUS: Upload failed for \(filename): \(error)")
        #endif

        if let state = activeUploads[filename] {
            try? FileManager.default.removeItem(at: state.fileURL)
        }
        activeUploads.removeValue(forKey: filename)

        DispatchQueue.main.async {
            self.delegate?.tusUploadDidComplete(filename: filename, success: false, error: error)
        }
    }

    // MARK: - Helpers

    private func sanitizeFilename(_ filename: String) -> String {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension
        let name = url.deletingPathExtension().lastPathComponent

        let asciiName = name.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false) ?? name

        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = asciiName.unicodeScalars.filter { allowedChars.contains($0) }
        let sanitizedName = String(String.UnicodeScalarView(sanitized))

        let finalName = sanitizedName.isEmpty ? UUID().uuidString : sanitizedName

        return ext.isEmpty ? finalName : "\(finalName).\(ext)"
    }
}
