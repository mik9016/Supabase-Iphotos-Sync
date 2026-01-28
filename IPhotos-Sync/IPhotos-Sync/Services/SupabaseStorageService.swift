import Foundation

enum SupabaseStorageError: LocalizedError {
    case notConfigured
    case notAuthenticated
    case invalidURL
    case uploadFailed(statusCode: Int, message: String)
    case deleteFailed(statusCode: Int, message: String)
    case networkError(Error)
    case invalidResponse
    case tokenRefreshFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase is not configured. Please check your settings."
        case .notAuthenticated:
            return "Not authenticated. Please sign in."
        case .invalidURL:
            return "Invalid Supabase URL"
        case .uploadFailed(let code, let message):
            return "Upload failed (\(code)): \(message)"
        case .deleteFailed(let code, let message):
            return "Delete failed (\(code)): \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from Supabase"
        case .tokenRefreshFailed:
            return "Failed to refresh authentication token"
        }
    }
}

struct UploadProgress {
    let bytesUploaded: Int64
    let totalBytes: Int64
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesUploaded) / Double(totalBytes)
    }
}

final class SupabaseStorageService {
    static let shared = SupabaseStorageService()

    private let authService = SupabaseAuthService.shared
    private let settings = AppSettings.shared
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    /// Test connection by listing bucket contents
    func testConnection() async throws -> Bool {
        guard authService.isAuthenticated else {
            throw SupabaseStorageError.notAuthenticated
        }

        guard let accessToken = authService.accessToken else {
            throw SupabaseStorageError.notAuthenticated
        }

        // Try to list the bucket to verify connection
        let url = URL(string: "\(authService.storageAPIURL)/object/list/\(SupabaseAuthService.bucketName)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Search for the user's folder
        let userFolder = authService.userFolderPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let body = ["prefix": userFolder, "limit": 1] as [String: Any]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseStorageError.invalidResponse
        }

        // Handle 401 with token refresh
        if httpResponse.statusCode == 401 {
            try await authService.refreshAccessToken()
            return try await testConnection()
        }

        // 200 = success, 400 = bucket exists but maybe empty
        return httpResponse.statusCode == 200 || httpResponse.statusCode == 400
    }

    /// Upload a file to Supabase Storage
    func uploadFile(
        data: Data,
        filename: String,
        contentType: String,
        progressHandler: ((UploadProgress) -> Void)? = nil
    ) async throws {
        try await uploadFileWithRetry(
            data: data,
            filename: filename,
            contentType: contentType,
            progressHandler: progressHandler,
            isRetry: false
        )
    }

    private func uploadFileWithRetry(
        data: Data,
        filename: String,
        contentType: String,
        progressHandler: ((UploadProgress) -> Void)?,
        isRetry: Bool
    ) async throws {
        guard authService.isAuthenticated else {
            throw SupabaseStorageError.notAuthenticated
        }

        guard let accessToken = authService.accessToken else {
            throw SupabaseStorageError.notAuthenticated
        }

        let folderPath = authService.userFolderPath
        let objectPath = folderPath + filename

        // URL encode the path
        guard let encodedPath = objectPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw SupabaseStorageError.invalidURL
        }

        let url = URL(string: "\(authService.storageAPIURL)/object/\(SupabaseAuthService.bucketName)/\(encodedPath)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        // Upsert to overwrite if exists
        request.setValue("true", forHTTPHeaderField: "x-upsert")

        progressHandler?(UploadProgress(bytesUploaded: 0, totalBytes: Int64(data.count)))

        let (responseData, response) = try await session.upload(for: request, from: data)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseStorageError.invalidResponse
        }

        // Handle 401 with token refresh (only retry once)
        if httpResponse.statusCode == 401 && !isRetry {
            do {
                try await authService.refreshAccessToken()
                try await uploadFileWithRetry(
                    data: data,
                    filename: filename,
                    contentType: contentType,
                    progressHandler: progressHandler,
                    isRetry: true
                )
                return
            } catch {
                throw SupabaseStorageError.tokenRefreshFailed
            }
        }

        if httpResponse.statusCode != 200 {
            let errorMessage = parseErrorMessage(from: responseData) ?? "Unknown error"
            throw SupabaseStorageError.uploadFailed(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        progressHandler?(UploadProgress(bytesUploaded: Int64(data.count), totalBytes: Int64(data.count)))

        #if DEBUG
        print("Successfully uploaded: \(filename)")
        #endif
    }

    /// Delete a file from Supabase Storage
    func deleteFile(filename: String) async throws {
        try await deleteFileWithRetry(filename: filename, isRetry: false)
    }

    private func deleteFileWithRetry(filename: String, isRetry: Bool) async throws {
        guard authService.isAuthenticated else {
            throw SupabaseStorageError.notAuthenticated
        }

        guard let accessToken = authService.accessToken else {
            throw SupabaseStorageError.notAuthenticated
        }

        let folderPath = authService.userFolderPath
        let objectPath = folderPath + filename

        guard let encodedPath = objectPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw SupabaseStorageError.invalidURL
        }

        let url = URL(string: "\(authService.storageAPIURL)/object/\(SupabaseAuthService.bucketName)/\(encodedPath)")!

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (responseData, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseStorageError.invalidResponse
        }

        // Handle 401 with token refresh (only retry once)
        if httpResponse.statusCode == 401 && !isRetry {
            do {
                try await authService.refreshAccessToken()
                try await deleteFileWithRetry(filename: filename, isRetry: true)
                return
            } catch {
                throw SupabaseStorageError.tokenRefreshFailed
            }
        }

        // 200 = deleted, 404 = already doesn't exist (also ok)
        if httpResponse.statusCode != 200 && httpResponse.statusCode != 404 {
            let errorMessage = parseErrorMessage(from: responseData) ?? "Unknown error"
            throw SupabaseStorageError.deleteFailed(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        #if DEBUG
        print("Successfully deleted from storage: \(filename)")
        #endif
    }

    private func parseErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["message"] as? String {
                return message
            }
            if let error = json["error"] as? String {
                return error
            }
            if let statusCode = json["statusCode"] as? String, let errorMsg = json["error"] as? String {
                return "\(errorMsg) (\(statusCode))"
            }
        }
        return String(data: data, encoding: .utf8)
    }
}
