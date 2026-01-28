import SwiftUI

@main
struct IPhotosSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var authService = SupabaseAuthService.shared

    var body: some Scene {
        WindowGroup {
            if authService.isAuthenticated {
                ContentView()
            } else {
                LoginView()
            }
        }
    }
}
