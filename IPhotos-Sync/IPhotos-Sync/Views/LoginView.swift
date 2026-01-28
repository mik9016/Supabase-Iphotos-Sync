import SwiftUI

struct LoginView: View {
    @ObservedObject private var authService = SupabaseAuthService.shared

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // App icon and title
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 64))
                        .foregroundColor(.accentColor)

                    Text("IPhotos Sync")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Sign in to sync your photos")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // Login form
                VStack(spacing: 16) {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                }
                .padding(.horizontal)

                // Error message
                if let errorMessage = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                    .padding(.horizontal)
                }

                // Sign in button
                Button {
                    signIn()
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .padding(.trailing, 8)
                        }
                        Text(isLoading ? "Signing In..." : "Sign In")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isFormValid ? Color.accentColor : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(!isFormValid || isLoading)
                .padding(.horizontal)

                Spacer()
                Spacer()
            }
            .navigationBarHidden(true)
        }
    }

    private var isFormValid: Bool {
        !email.isEmpty && !password.isEmpty && email.contains("@")
    }

    private func signIn() {
        guard isFormValid else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await authService.signIn(email: email, password: password)
                // Success - the app will automatically show ContentView
                // due to the isAuthenticated binding
            } catch let error as SupabaseAuthError {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

#if DEBUG
struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
    }
}
#endif
