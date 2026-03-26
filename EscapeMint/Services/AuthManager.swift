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
        case .none: return "Biometric Auth"
        @unknown default: return "Biometric Auth"
        }
    }

    private init() {
        refreshBiometry()
        if !isEnabled { isUnlocked = true }
    }

    func authenticate() {
        guard isEnabled, !isUnlocked, !isEvaluating else { return }

        isEvaluating = true
        Task {
            defer {
                isEvaluating = false
                refreshBiometry()
            }

            // Skip biometrics if hardware isn't available — go straight to passcode
            if biometryAvailable {
                let context = LAContext()
                // We handle passcode fallback ourselves rather than showing system's button
                context.localizedFallbackTitle = ""

                do {
                    try await context.evaluatePolicy(
                        .deviceOwnerAuthenticationWithBiometrics,
                        localizedReason: "Unlock EscapeMint to view your portfolio"
                    )
                    isUnlocked = true
                    return
                } catch let error as LAError where error.code == .biometryLockout || error.code == .biometryNotAvailable || error.code == .userFallback {
                    // Fall through to passcode
                } catch {
                    Self.logger.info("Auth cancelled: \(error.localizedDescription)")
                    return
                }
            }

            // Passcode fallback (or primary if no biometrics)
            do {
                try await LAContext().evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Unlock EscapeMint with your passcode"
                )
                isUnlocked = true
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
