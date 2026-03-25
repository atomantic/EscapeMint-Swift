import SwiftUI
import LocalAuthentication

struct LockScreenView: View {
    @State private var auth = AuthManager.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundColor(.mint)
                .accessibilityHidden(true)
            Text("EscapeMint is Locked")
                .font(.title2).fontWeight(.semibold)
                .foregroundColor(.textPrimary)
            Text("Authenticate to view your portfolio")
                .font(.subheadline)
                .foregroundColor(.textMuted)
            Button {
                auth.authenticate()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: biometryIcon)
                    Text("Unlock with \(auth.biometryName)")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.mint)
                .cornerRadius(12)
            }
            .disabled(auth.isEvaluating)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg.ignoresSafeArea())
        .onAppear { auth.authenticate() }
    }

    private var biometryIcon: String {
        switch auth.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        @unknown default: return "lock.open.fill"
        }
    }
}
