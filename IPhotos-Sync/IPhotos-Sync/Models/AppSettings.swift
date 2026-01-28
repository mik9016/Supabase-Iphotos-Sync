import Foundation
import Combine

enum SyncMode: String, Codable, CaseIterable {
    case auto = "auto"       // Sync oldest photos automatically
    case manual = "manual"   // Manually pick photos to sync

    var displayName: String {
        switch self {
        case .auto: return "Auto (Oldest First)"
        case .manual: return "Manual Selection"
        }
    }
}

enum PhotoCountSetting: Codable, Equatable, Hashable {
    case count(Int)
    case all

    var displayValue: String {
        switch self {
        case .count(let n):
            return "\(n)"
        case .all:
            return "All"
        }
    }

    var intValue: Int? {
        switch self {
        case .count(let n):
            return n
        case .all:
            return nil
        }
    }

    static let presets: [PhotoCountSetting] = [
        .count(10),
        .count(25),
        .count(50),
        .count(100)
    ]
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var photoCountSetting: PhotoCountSetting {
        didSet {
            if let encoded = try? JSONEncoder().encode(photoCountSetting) {
                defaults.set(encoded, forKey: Keys.photoCount)
            }
        }
    }

    @Published var autoSyncEnabled: Bool {
        didSet {
            defaults.set(autoSyncEnabled, forKey: Keys.autoSyncEnabled)
        }
    }

    @Published var syncMode: SyncMode {
        didSet {
            defaults.set(syncMode.rawValue, forKey: Keys.syncMode)
        }
    }

    @Published var lastSyncDate: Date? {
        didSet {
            defaults.set(lastSyncDate, forKey: Keys.lastSyncDate)
        }
    }

    /// Check if the app is configured and ready to sync
    var isConfigured: Bool {
        SupabaseAuthService.shared.isAuthenticated
    }

    /// Returns the Storage API base URL
    var storageAPIURL: String {
        return SupabaseAuthService.shared.storageAPIURL
    }

    /// Returns the user's folder path: {userId}/
    var userFolderPath: String {
        return SupabaseAuthService.shared.userFolderPath
    }

    private init() {
        if let photoCountData = defaults.data(forKey: Keys.photoCount),
           let photoCount = try? JSONDecoder().decode(PhotoCountSetting.self, from: photoCountData) {
            self.photoCountSetting = photoCount
        } else {
            self.photoCountSetting = .count(50)
        }

        self.autoSyncEnabled = defaults.bool(forKey: Keys.autoSyncEnabled)
        self.lastSyncDate = defaults.object(forKey: Keys.lastSyncDate) as? Date

        if let syncModeRaw = defaults.string(forKey: Keys.syncMode),
           let mode = SyncMode(rawValue: syncModeRaw) {
            self.syncMode = mode
        } else {
            self.syncMode = .auto
        }
    }

    func clearAll() {
        defaults.removeObject(forKey: Keys.photoCount)
        defaults.removeObject(forKey: Keys.autoSyncEnabled)
        defaults.removeObject(forKey: Keys.lastSyncDate)
        defaults.removeObject(forKey: Keys.syncMode)

        photoCountSetting = .count(50)
        autoSyncEnabled = false
        lastSyncDate = nil
        syncMode = .auto
    }
}

private enum Keys {
    static let photoCount = "photo_count_setting"
    static let autoSyncEnabled = "auto_sync_enabled"
    static let lastSyncDate = "last_sync_date"
    static let syncMode = "sync_mode"
}
