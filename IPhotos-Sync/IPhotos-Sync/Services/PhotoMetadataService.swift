import Foundation
import Photos
import CoreLocation

/// Represents photo metadata to be stored in Supabase
struct PhotoMetadata: Codable {
    let user_id: String
    let filename: String
    let storage_path: String
    let thumbnail_path: String?
    let taken_at: String?
    let year: Int?
    let month: Int?
    let day: Int?
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let country: String?
    let location_name: String?
    let media_type: String
    let mime_type: String
    let file_size: Int64?
    let width: Int
    let height: Int
    let duration: Double?
    let device_id: String
}

/// Service for saving photo metadata to Supabase database
final class PhotoMetadataService {
    static let shared = PhotoMetadataService()

    private let session: URLSession
    private let geocoder = CLGeocoder()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Save metadata for a photo after successful upload
    func saveMetadata(for photo: PhotoAsset, storagePath: String, thumbnailPath: String? = nil) async throws {
        guard let accessToken = SupabaseAuthService.shared.accessToken,
              let userId = SupabaseAuthService.shared.userId else {
            throw MetadataError.notAuthenticated
        }

        let asset = photo.asset
        let calendar = Calendar.current

        // Extract date components
        var year: Int? = nil
        var month: Int? = nil
        var day: Int? = nil
        var takenAtString: String? = nil

        if let creationDate = asset.creationDate {
            let components = calendar.dateComponents([.year, .month, .day], from: creationDate)
            year = components.year
            month = components.month
            day = components.day

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            takenAtString = formatter.string(from: creationDate)
        }

        // Extract location and reverse geocode
        var latitude: Double? = nil
        var longitude: Double? = nil
        var city: String? = nil
        var country: String? = nil
        var locationName: String? = nil

        if let location = asset.location {
            latitude = location.coordinate.latitude
            longitude = location.coordinate.longitude

            // Reverse geocode to get city and country
            let geocodeResult = await reverseGeocode(location: location)
            city = geocodeResult.city
            country = geocodeResult.country
            locationName = geocodeResult.locationName
        }

        // Get file size (estimate)
        let resources = PHAssetResource.assetResources(for: asset)
        let fileSize = resources.first.flatMap { resource -> Int64? in
            return resource.value(forKey: "fileSize") as? Int64
        }

        let metadata = PhotoMetadata(
            user_id: userId,
            filename: photo.filename,
            storage_path: storagePath,
            thumbnail_path: thumbnailPath,
            taken_at: takenAtString,
            year: year,
            month: month,
            day: day,
            latitude: latitude,
            longitude: longitude,
            city: city,
            country: country,
            location_name: locationName,
            media_type: asset.mediaType == .video ? "video" : "image",
            mime_type: photo.mimeType,
            file_size: fileSize,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            duration: asset.mediaType == .video ? asset.duration : nil,
            device_id: asset.localIdentifier
        )

        try await insertMetadata(metadata, accessToken: accessToken)
    }

    /// Reverse geocode a location to get city and country
    private func reverseGeocode(location: CLLocation) async -> (city: String?, country: String?, locationName: String?) {
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else {
                return (nil, nil, nil)
            }

            let city = placemark.locality
            let country = placemark.country

            // Build a formatted location name
            var nameParts: [String] = []
            if let locality = placemark.locality {
                nameParts.append(locality)
            }
            if let adminArea = placemark.administrativeArea, adminArea != placemark.locality {
                nameParts.append(adminArea)
            }
            if let countryName = placemark.country {
                nameParts.append(countryName)
            }
            let locationName = nameParts.isEmpty ? nil : nameParts.joined(separator: ", ")

            return (city, country, locationName)
        } catch {
            #if DEBUG
            print("Reverse geocoding failed: \(error.localizedDescription)")
            #endif
            return (nil, nil, nil)
        }
    }

    private func insertMetadata(_ metadata: PhotoMetadata, accessToken: String) async throws {
        guard let url = URL(string: "\(SupabaseAuthService.supabaseURL)/rest/v1/photos") else {
            throw MetadataError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(SupabaseAuthService.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // Upsert based on user_id + device_id constraint
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(metadata)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MetadataError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            #if DEBUG
            print("Metadata save error (\(httpResponse.statusCode)): \(errorMessage)")
            #endif
            // Don't throw - metadata save failure shouldn't fail the upload
        } else {
            #if DEBUG
            print("Metadata saved for: \(metadata.filename)")
            #endif
        }
    }
}

enum MetadataError: LocalizedError {
    case notAuthenticated
    case invalidURL
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated"
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response"
        case .serverError(let message):
            return "Server error: \(message)"
        }
    }
}
