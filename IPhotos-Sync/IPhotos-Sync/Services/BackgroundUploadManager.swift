import Foundation
import UIKit
import Photos
import AVFoundation

protocol BackgroundUploadDelegate: AnyObject {
    func uploadDidComplete(filename: String, success: Bool, error: String?)
    func uploadDidProgress(filename: String, progress: Double)
    func allUploadsCompleted()
}

final class BackgroundUploadManager: NSObject {
    static let shared = BackgroundUploadManager()

    private let sessionIdentifier = "com.iphotos.IPhotos-Sync.backgroundUpload"
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 60 * 60 * 2 // 2 hours for large files
        config.timeoutIntervalForRequest = 60 * 10      // 10 minutes per request
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    weak var delegate: BackgroundUploadDelegate?

    // Track pending uploads
    private var pendingUploads: [String: UploadInfo] = [:] // taskIdentifier -> UploadInfo
    private var uploadQueue: [QueuedUpload] = []
    private var retryQueue: [QueuedUpload] = [] // For retrying failed uploads
    private var isProcessingQueue = false
    private let maxConcurrentUploads = 2 // Reduced to avoid server overload
    private let maxRetries = 3

    private let tempDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // Completion handler for background session
    var backgroundCompletionHandler: (() -> Void)?

    // Track completion state
    private var hasCalledAllCompleted = false
    private var totalQueued = 0
    private var activeExports = 0  // Track in-progress video exports

    struct UploadInfo {
        let filename: String
        let tempFileURL: URL
        let contentType: String
        let originalFileURL: URL?
        let originalData: Data?
        let originalPHAsset: PHAsset?  // For deferred video export retries
        let startTime: Date
        var retryCount: Int
    }

    struct QueuedUpload {
        let data: Data?
        let fileURL: URL?
        let phAsset: PHAsset?  // For deferred video export
        let filename: String
        let contentType: String
        var retryCount: Int = 0
    }

    private override init() {
        super.init()
        // Initialize the session
        _ = backgroundSession
    }

    // MARK: - Public API

    func queueUpload(data: Data, filename: String, contentType: String) {
        let upload = QueuedUpload(data: data, fileURL: nil, phAsset: nil, filename: filename, contentType: contentType)
        uploadQueue.append(upload)
        totalQueued += 1
        processQueue()
    }

    func queueUpload(fileURL: URL, filename: String, contentType: String) {
        let upload = QueuedUpload(data: nil, fileURL: fileURL, phAsset: nil, filename: filename, contentType: contentType)
        uploadQueue.append(upload)
        totalQueued += 1
        processQueue()
    }

    func queueVideoUpload(asset: PHAsset, filename: String, contentType: String) {
        let upload = QueuedUpload(data: nil, fileURL: nil, phAsset: asset, filename: filename, contentType: contentType)
        uploadQueue.append(upload)
        totalQueued += 1
        processQueue()
    }

    func resetState() {
        hasCalledAllCompleted = false
        totalQueued = 0
        activeExports = 0
        retryQueue.removeAll()
    }

    func cancelAllUploads() {
        uploadQueue.removeAll()
        retryQueue.removeAll()
        backgroundSession.getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
            uploadTasks.forEach { $0.cancel() }
        }
        cleanupTempFiles()
        resetState()
    }

    var activeUploadCount: Int {
        return pendingUploads.count
    }

    var queuedUploadCount: Int {
        return uploadQueue.count + retryQueue.count
    }

    // MARK: - Private Methods

    private func processQueue() {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Process main queue first, then retry queue
            while self.pendingUploads.count < self.maxConcurrentUploads {
                if !self.uploadQueue.isEmpty {
                    let upload = self.uploadQueue.removeFirst()
                    self.startUpload(upload)
                } else if !self.retryQueue.isEmpty {
                    // Add delay before retry
                    Thread.sleep(forTimeInterval: 2.0)
                    let upload = self.retryQueue.removeFirst()
                    self.startUpload(upload)
                } else {
                    break
                }
            }

            self.isProcessingQueue = false
        }
    }

    private func startUpload(_ upload: QueuedUpload) {
        // Check if this file is already being uploaded
        let isAlreadyUploading = pendingUploads.values.contains { $0.filename == upload.filename }
        if isAlreadyUploading {
            #if DEBUG
            print("Skipping duplicate upload: \(upload.filename)")
            #endif
            return
        }

        guard let accessToken = SupabaseAuthService.shared.accessToken else {
            DispatchQueue.main.async {
                self.delegate?.uploadDidComplete(filename: upload.filename, success: false, error: "Not authenticated")
                self.checkIfAllCompleted()
            }
            return
        }

        // Handle deferred video export - export just-in-time to avoid temp file cleanup race condition
        if let phAsset = upload.phAsset {
            exportVideoAndUpload(upload, asset: phAsset)
            return  // Async path
        }

        // Determine the file URL to upload from
        let tempFileURL: URL

        if let sourceFileURL = upload.fileURL {
            // For videos: copy to temp location (background upload needs file in our control)
            tempFileURL = tempDirectory.appendingPathComponent(UUID().uuidString + "." + sourceFileURL.pathExtension)
            do {
                try FileManager.default.copyItem(at: sourceFileURL, to: tempFileURL)
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.uploadDidComplete(filename: upload.filename, success: false, error: "Failed to copy file: \(error.localizedDescription)")
                    self.checkIfAllCompleted()
                }
                return
            }
        } else if let data = upload.data {
            // For images: write data to temp file
            tempFileURL = tempDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try data.write(to: tempFileURL)
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.uploadDidComplete(filename: upload.filename, success: false, error: "Failed to write temp file: \(error.localizedDescription)")
                    self.checkIfAllCompleted()
                }
                return
            }
        } else {
            DispatchQueue.main.async {
                self.delegate?.uploadDidComplete(filename: upload.filename, success: false, error: "No data or file URL provided")
                self.checkIfAllCompleted()
            }
            return
        }

        continueUploadWithFile(upload, tempFileURL: tempFileURL)
    }

    private func exportVideoAndUpload(_ upload: QueuedUpload, asset: PHAsset) {
        activeExports += 1  // Track that export is in progress

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        PHImageManager.default().requestExportSession(
            forVideo: asset,
            options: options,
            exportPreset: AVAssetExportPresetPassthrough  // Original quality for backups
        ) { [weak self] exportSession, info in
            guard let self = self else { return }

            if let error = info?[PHImageErrorKey] as? Error {
                self.activeExports -= 1  // Export failed early
                self.handleExportFailure(upload, error: error.localizedDescription)
                return
            }

            guard let exportSession = exportSession else {
                self.activeExports -= 1  // Export failed early
                self.handleExportFailure(upload, error: "Failed to get export session")
                return
            }

            let outputURL = self.tempDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mov

            exportSession.exportAsynchronously { [weak self] in
                guard let self = self else { return }

                self.activeExports -= 1  // Export finished

                switch exportSession.status {
                case .completed:
                    #if DEBUG
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                       let size = attrs[.size] as? Int64 {
                        print("Video export completed for: \(upload.filename) - Size: \(size / 1_000_000) MB")
                    } else {
                        print("Video export completed for: \(upload.filename)")
                    }
                    #endif
                    self.continueUploadWithFile(upload, tempFileURL: outputURL)
                case .failed:
                    self.handleExportFailure(upload, error: exportSession.error?.localizedDescription ?? "Export failed")
                case .cancelled:
                    self.handleExportFailure(upload, error: "Export cancelled")
                default:
                    self.handleExportFailure(upload, error: "Export status: \(exportSession.status.rawValue)")
                }
            }
        }
    }

    private func handleExportFailure(_ upload: QueuedUpload, error: String) {
        #if DEBUG
        print("Video export failed for \(upload.filename): \(error)")
        #endif

        DispatchQueue.main.async {
            self.delegate?.uploadDidComplete(filename: upload.filename, success: false, error: "Video export failed: \(error)")
            self.processQueue()
            self.checkIfAllCompleted()
        }
    }

    /// Sanitizes filename to be compatible with Supabase storage (ASCII-only, safe characters)
    private func sanitizeFilename(_ filename: String) -> String {
        // Separate name and extension
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension
        let name = url.deletingPathExtension().lastPathComponent

        // Transliterate to ASCII (e.g., "ź" -> "z", "ó" -> "o")
        let asciiName = name.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false) ?? name

        // Remove any remaining non-ASCII and problematic characters
        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = asciiName.unicodeScalars.filter { allowedChars.contains($0) }
        let sanitizedName = String(String.UnicodeScalarView(sanitized))

        // Ensure we have a valid name
        let finalName = sanitizedName.isEmpty ? UUID().uuidString : sanitizedName

        return ext.isEmpty ? finalName : "\(finalName).\(ext)"
    }

    private func continueUploadWithFile(_ upload: QueuedUpload, tempFileURL: URL) {
        guard let accessToken = SupabaseAuthService.shared.accessToken else {
            try? FileManager.default.removeItem(at: tempFileURL)
            DispatchQueue.main.async {
                self.delegate?.uploadDidComplete(filename: upload.filename, success: false, error: "Not authenticated")
                self.checkIfAllCompleted()
            }
            return
        }

        // Build the upload URL with sanitized filename
        let folderPath = SupabaseAuthService.shared.userFolderPath
        let sanitizedFilename = sanitizeFilename(upload.filename)
        let objectPath = folderPath + sanitizedFilename

        guard let encodedPath = objectPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(SupabaseAuthService.shared.storageAPIURL)/object/\(SupabaseAuthService.bucketName)/\(encodedPath)") else {
            try? FileManager.default.removeItem(at: tempFileURL)
            DispatchQueue.main.async {
                self.delegate?.uploadDidComplete(filename: upload.filename, success: false, error: "Invalid URL")
                self.checkIfAllCompleted()
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(upload.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")

        let task = backgroundSession.uploadTask(with: request, fromFile: tempFileURL)
        task.taskDescription = upload.filename

        pendingUploads["\(task.taskIdentifier)"] = UploadInfo(
            filename: upload.filename,
            tempFileURL: tempFileURL,
            contentType: upload.contentType,
            originalFileURL: upload.fileURL,
            originalData: upload.data,
            originalPHAsset: upload.phAsset,
            startTime: Date(),
            retryCount: upload.retryCount
        )

        task.resume()

        #if DEBUG
        print("Started upload: \(upload.filename) (attempt \(upload.retryCount + 1))")
        #endif
    }

    private func retryUpload(_ info: UploadInfo) {
        let newRetryCount = info.retryCount + 1

        // Double-check we haven't exceeded max retries
        guard newRetryCount < maxRetries else {
            #if DEBUG
            print("Max retries reached for: \(info.filename)")
            #endif
            return
        }

        // Check if already in retry queue to avoid duplicates
        if retryQueue.contains(where: { $0.filename == info.filename }) {
            #if DEBUG
            print("Already in retry queue: \(info.filename)")
            #endif
            return
        }

        let upload = QueuedUpload(
            data: info.originalData,
            fileURL: info.originalFileURL,
            phAsset: info.originalPHAsset,
            filename: info.filename,
            contentType: info.contentType,
            retryCount: newRetryCount
        )
        retryQueue.append(upload)

        #if DEBUG
        print("Queued for retry: \(info.filename) (attempt \(newRetryCount + 1) of \(maxRetries + 1))")
        #endif
    }

    private func checkIfAllCompleted() {
        DispatchQueue.main.async {
            if self.pendingUploads.isEmpty && self.uploadQueue.isEmpty && self.retryQueue.isEmpty && self.activeExports == 0 && !self.hasCalledAllCompleted {
                self.hasCalledAllCompleted = true
                self.delegate?.allUploadsCompleted()
            }
        }
    }

    private func cleanupTempFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func cleanupTempFiles() {
        for (_, info) in pendingUploads {
            cleanupTempFile(at: info.tempFileURL)
        }
        pendingUploads.removeAll()

        // Clean entire temp directory
        try? FileManager.default.removeItem(at: tempDirectory)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
}

// MARK: - URLSessionDelegate

extension BackgroundUploadManager: URLSessionDelegate {
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}

// MARK: - URLSessionTaskDelegate

extension BackgroundUploadManager: URLSessionTaskDelegate, URLSessionDataDelegate {
    // Capture response body for error debugging
    private static var responseData: [Int: Data] = [:]

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let taskId = dataTask.taskIdentifier
        if BackgroundUploadManager.responseData[taskId] != nil {
            BackgroundUploadManager.responseData[taskId]?.append(data)
        } else {
            BackgroundUploadManager.responseData[taskId] = data
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskKey = "\(task.taskIdentifier)"
        guard let uploadInfo = pendingUploads.removeValue(forKey: taskKey) else { return }

        // Get and clear response body
        let responseBody = BackgroundUploadManager.responseData.removeValue(forKey: task.taskIdentifier)
        if let body = responseBody, let bodyString = String(data: body, encoding: .utf8) {
            #if DEBUG
            print("Response body for \(uploadInfo.filename): \(bodyString)")
            #endif
        }

        // Cleanup temp file
        cleanupTempFile(at: uploadInfo.tempFileURL)

        let filename = uploadInfo.filename
        var success = false
        var errorMessage: String?
        var shouldRetry = false

        if let error = error {
            errorMessage = error.localizedDescription
            // Retry on network errors
            if uploadInfo.retryCount < maxRetries {
                shouldRetry = true
            }
        } else if let httpResponse = task.response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                success = true
                #if DEBUG
                print("Upload completed: \(filename)")
                #endif

            case 401, 403:
                // Token expired - try to refresh and retry
                errorMessage = "Authentication expired"
                if uploadInfo.retryCount < maxRetries {
                    shouldRetry = true
                    // Refresh token in background (will be ready for retry)
                    Task {
                        try? await SupabaseAuthService.shared.refreshAccessToken()
                    }
                }

            case 400:
                // Check if it's actually an auth error in the response body
                if let body = responseBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let message = json["message"] as? String,
                   message.lowercased().contains("jwt") || message.lowercased().contains("expired") || message.lowercased().contains("unauthorized") {
                    // Auth error disguised as 400 - refresh and retry
                    errorMessage = "Authentication expired"
                    if uploadInfo.retryCount < maxRetries {
                        shouldRetry = true
                        Task {
                            try? await SupabaseAuthService.shared.refreshAccessToken()
                        }
                    }
                } else if let body = responseBody, let bodyString = String(data: body, encoding: .utf8) {
                    errorMessage = "Server rejected file (400): \(bodyString)"
                } else {
                    errorMessage = "File rejected by server (400)"
                }

            case 413:
                // Payload too large
                errorMessage = "File too large (413). Server limit exceeded."

            case 502, 503, 504:
                // Server/gateway errors - retry
                errorMessage = "Server error (\(httpResponse.statusCode))"
                if uploadInfo.retryCount < maxRetries {
                    shouldRetry = true
                }

            case 500..<600:
                // Other server errors - retry
                errorMessage = "Server error (\(httpResponse.statusCode))"
                if uploadInfo.retryCount < maxRetries {
                    shouldRetry = true
                }

            default:
                errorMessage = "Upload failed (\(httpResponse.statusCode))"
            }
        } else {
            errorMessage = "Invalid response"
        }

        if shouldRetry {
            #if DEBUG
            print("Will retry: \(filename) after error: \(errorMessage ?? "unknown")")
            #endif
            retryUpload(uploadInfo)
            processQueue()
            return
        }

        DispatchQueue.main.async {
            self.delegate?.uploadDidComplete(filename: filename, success: success, error: errorMessage)

            // Process next in queue
            self.processQueue()

            // Check if all done
            self.checkIfAllCompleted()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let filename = task.taskDescription else { return }

        let progress = totalBytesExpectedToSend > 0 ? Double(totalBytesSent) / Double(totalBytesExpectedToSend) : 0

        DispatchQueue.main.async {
            self.delegate?.uploadDidProgress(filename: filename, progress: progress)
        }
    }
}
