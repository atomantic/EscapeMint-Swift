import Foundation
import LocalAuthentication
import os

@MainActor @Observable
final class AuthManager {
    static let shared = AuthManager()

    private(set) var isUnlocked = false
    private(set) var isEvaluating = false

    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "AuthManager")

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "escapemint-biometric-auth") }
        set { UserDefaults.standard.set(newValue, forKey: "escapemint-biometric-auth") }
    }

    /// True when biometric hardware is available on this device
    var biometryAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Human-readable name: "Face ID", "Touch ID", or "Optic ID"
    var biometryName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Biometric Auth"
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        @unknown default: return "Biometric Auth"
        }
    }

    private init() {
        // If auth is not enabled, start unlocked
        if !isEnabled { isUnlocked = true }
    }

    /// Attempt biometric authentication. Falls back to device passcode.
    func authenticate() {
        guard isEnabled, !isUnlocked, !isEvaluating else { return }
        isEvaluating = true

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        Task {
            defer { isEvaluating = false }
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Unlock EscapeMint to view your portfolio"
                )
                if success { isUnlocked = true }
            } catch {
                Self.logger.info("Auth failed: \(error.localizedDescription)")
            }
        }
    }

    /// Lock the app (call on scene phase change to background)
    func lock() {
        guard isEnabled else { return }
        isUnlocked = false
    }

    /// Called when the user toggles auth on/off
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { isUnlocked = true }
    }
}
