import Foundation
import LocalAuthentication
import os

@MainActor @Observable
final class AuthManager {
    static let shared = AuthManager()

    private(set) var isUnlocked = false
    private(set) var isEvaluating = false
    private(set) var biometryType: LABiometryType = .none
    private(set) var biometryAvailable = false

    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "AuthManager")

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "escapemint-biometric-auth") }
        set { UserDefaults.standard.set(newValue, forKey: "escapemint-biometric-auth") }
    }

    var biometryName: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        @unknown default: return "Biometric Auth"
        }
    }

    private init() {
        refreshBiometry()
        if !isEnabled { isUnlocked = true }
    }

    func authenticate() {
        guard isEnabled, !isUnlocked, !isEvaluating else { return }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        isEvaluating = true
        Task {
            defer {
                isEvaluating = false
                refreshBiometry()
            }
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

    func lock() {
        guard isEnabled else { return }
        isUnlocked = false
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { isUnlocked = true }
    }

    private func refreshBiometry() {
        let context = LAContext()
        var error: NSError?
        biometryAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        biometryType = context.biometryType
    }
}
