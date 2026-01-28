import Foundation
import Combine

enum SupabaseAuthError: LocalizedError {
    case invalidURL
    case invalidCredentials
    case networkError(Error)
    case invalidResponse
    case tokenExpired
    case notAuthenticated
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Supabase URL"
        case .invalidCredentials:
            return "Invalid email or password"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .tokenExpired:
            return "Session expired. Please sign in again."
        case .notAuthenticated:
            return "Not authenticated"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        }
    }
}

final class SupabaseAuthService: ObservableObject {
    static let shared = SupabaseAuthService()

    // Supabase configuration from Secrets.swift
    static let supabaseURL = Secrets.supabaseURL
    static let anonKey = Secrets.supabaseAnonKey
    static let bucketName = Secrets.bucketName

    private let keychainManager = KeychainManager.shared
    private let session: URLSession

    @Published var isAuthenticated: Bool = false

    private enum KeychainKeys {
        static let accessToken = "supabase_access_token"
        static let refreshToken = "supabase_refresh_token"
        static let userId = "supabase_user_id"
        static let userEmail = "supabase_user_email"
    }

    var accessToken: String? {
        keychainManager.get(key: KeychainKeys.accessToken)
    }

    var refreshToken: String? {
        keychainManager.get(key: KeychainKeys.refreshToken)
    }

    var userId: String? {
        keychainManager.get(key: KeychainKeys.userId)
    }

    var userEmail: String? {
        keychainManager.get(key: KeychainKeys.userEmail)
    }

    /// Returns the user's folder path: {userId}/
    var userFolderPath: String {
        guard let userId = userId else { return "" }
        return "\(userId)/"
    }

    /// Returns the Storage API base URL
    var storageAPIURL: String {
        return "\(Self.supabaseURL)/storage/v1"
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)

        // Check if user is already authenticated
        self.isAuthenticated = accessToken != nil && userId != nil
    }

    // MARK: - Sign In

    func signIn(email: String, password: String) async throws {
        guard let url = URL(string: "\(Self.supabaseURL)/auth/v1/token?grant_type=password") else {
            throw SupabaseAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.anonKey, forHTTPHeaderField: "apikey")

        let body: [String: String] = [
            "email": email,
            "password": password
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseAuthError.invalidResponse
        }

        if httpResponse.statusCode == 400 {
            throw SupabaseAuthError.invalidCredentials
        }

        if httpResponse.statusCode != 200 {
            let errorMessage = parseErrorMessage(from: data) ?? "Unknown error"
            throw SupabaseAuthError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        try parseAndStoreAuthResponse(data)

        await MainActor.run {
            self.isAuthenticated = true
        }
    }

    // MARK: - Sign Out

    func signOut() async throws {
        if let token = accessToken {
            // Try to invalidate the token on the server
            if let url = URL(string: "\(Self.supabaseURL)/auth/v1/logout") {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(Self.anonKey, forHTTPHeaderField: "apikey")

                // Best effort - don't fail if server logout fails
                _ = try? await session.data(for: request)
            }
        }

        // Clear local credentials
        clearCredentials()

        await MainActor.run {
            self.isAuthenticated = false
        }
    }

    // MARK: - Token Refresh

    func refreshAccessToken() async throws {
        guard let currentRefreshToken = refreshToken else {
            throw SupabaseAuthError.notAuthenticated
        }

        guard let url = URL(string: "\(Self.supabaseURL)/auth/v1/token?grant_type=refresh_token") else {
            throw SupabaseAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.anonKey, forHTTPHeaderField: "apikey")

        let body: [String: String] = [
            "refresh_token": currentRefreshToken
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseAuthError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 400 {
            // Refresh token is invalid/expired
            clearCredentials()
            await MainActor.run {
                self.isAuthenticated = false
            }
            throw SupabaseAuthError.tokenExpired
        }

        if httpResponse.statusCode != 200 {
            let errorMessage = parseErrorMessage(from: data) ?? "Unknown error"
            throw SupabaseAuthError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        try parseAndStoreAuthResponse(data)
    }

    // MARK: - Private Helpers

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw SupabaseAuthError.networkError(error)
        }
    }

    private func parseAndStoreAuthResponse(_ data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SupabaseAuthError.invalidResponse
        }

        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let user = json["user"] as? [String: Any],
              let userId = user["id"] as? String else {
            throw SupabaseAuthError.invalidResponse
        }

        let userEmail = user["email"] as? String ?? ""

        // Store in Keychain
        keychainManager.set(key: KeychainKeys.accessToken, value: accessToken)
        keychainManager.set(key: KeychainKeys.refreshToken, value: refreshToken)
        keychainManager.set(key: KeychainKeys.userId, value: userId)
        keychainManager.set(key: KeychainKeys.userEmail, value: userEmail)
    }

    private func clearCredentials() {
        keychainManager.delete(key: KeychainKeys.accessToken)
        keychainManager.delete(key: KeychainKeys.refreshToken)
        keychainManager.delete(key: KeychainKeys.userId)
        keychainManager.delete(key: KeychainKeys.userEmail)
    }

    private func parseErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["message"] as? String {
                return message
            }
            if let error = json["error"] as? String {
                return error
            }
            if let errorDescription = json["error_description"] as? String {
                return errorDescription
            }
        }
        return String(data: data, encoding: .utf8)
    }
}
