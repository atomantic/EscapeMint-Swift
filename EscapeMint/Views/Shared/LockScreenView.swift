import SwiftUI
import LocalAuthentication

struct LockScreenView: View {
    @State private var auth = AuthManager.shared
    // Scale the lock glyph with Dynamic Type so it grows alongside the
    // surrounding text instead of staying a fixed 48pt.
    @ScaledMetric(relativeTo: .largeTitle) private var lockIconSize: CGFloat = 48

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: lockIconSize))
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
        // .onAppear (not .task): `auth.authenticate()` is a synchronous call that
        // internally spawns its own unstructured `Task` stored as `authTask` and returns
        // immediately. A `.task` modifier would only cancel whatever runs inside its own
        // closure — since the closure returns instantly, there is nothing for `.task`
        // cancellation to stop. The real cancellation path is `AuthManager.lock()`.
        // AuthManager has an `isEvaluating` guard so duplicate re-entries are safe.
        .onAppear { auth.authenticate() }
    }

    private var biometryIcon: String {
        switch auth.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none: return "lock.open.fill"
        @unknown default: return "lock.open.fill"
        }
    }
}
