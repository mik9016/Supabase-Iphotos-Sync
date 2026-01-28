import Foundation

enum Constants {
    enum App {
        static let name = "IPhotos Sync"
        static let bundleIdentifier = "com.iphotos.IPhotos-Sync"
    }

    enum BackgroundTasks {
        static let refreshIdentifier = "\(App.bundleIdentifier).refresh"
        static let processingIdentifier = "\(App.bundleIdentifier).processing"
        static let minimumBackgroundFetchInterval: TimeInterval = 15 * 60
    }

    enum Upload {
        static let multipartThreshold: Int = 5 * 1024 * 1024
        static let partSize: Int = 5 * 1024 * 1024
        static let maxRetries = 3
        static let retryDelay: TimeInterval = 2.0
    }

    enum UI {
        static let thumbnailSize: CGFloat = 80
        static let gridSpacing: CGFloat = 2
        static let cornerRadius: CGFloat = 12
    }
}
