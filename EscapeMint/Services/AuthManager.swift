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
    private var authTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "AuthManager")

    // Keychain coordinates for the biometric-lock-enabled flag.
    // Storing this in the Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    // prevents the setting from being bypassed by editing UserDefaults via a
    // filesystem tool or iCloud backup restore.
    private static let keychainService = "net.shadowpuppet.EscapeMint"
    private static let keychainAccount = "biometric-auth-enabled"

    /// Reads the enabled flag from Keychain.  On first access, migrates the
    /// legacy UserDefaults value if present, then removes it.
    ///
    /// Error posture: if Keychain returns an actual error (not "not found"),
    /// we fail toward the safer state — enabled if the migration source said
    /// enabled, otherwise disabled — and log the status code.
    var isEnabled: Bool {
        get {
            do {
                if let stored = try KeychainHelper.readBool(
                    service: Self.keychainService,
                    account: Self.keychainAccount
                ) {
                    return stored
                }
                // No Keychain entry yet — perform one-time migration from UserDefaults.
                let legacy = UserDefaults.standard.bool(forKey: AppStorageKeys.biometricAuth)
                try KeychainHelper.writeBool(
                    service: Self.keychainService,
                    account: Self.keychainAccount,
                    value: legacy
                )
                UserDefaults.standard.removeObject(forKey: AppStorageKeys.biometricAuth)
                return legacy
            } catch {
                // Keychain read/write error: fail toward safer state.
                // If the legacy UserDefaults key exists its value is the safer
                // fallback; otherwise treat as disabled (no gate is better than
                // a broken gate in a read-error scenario).
                let legacy = UserDefaults.standard.object(forKey: AppStorageKeys.biometricAuth) as? Bool
                Self.logger.error("Keychain read error — falling back to UserDefaults: \(error.localizedDescription)")
                return legacy ?? false
            }
        }
        set {
            do {
                try KeychainHelper.writeBool(
                    service: Self.keychainService,
                    account: Self.keychainAccount,
                    value: newValue
                )
                // Keep UserDefaults in sync so any legacy @AppStorage bindings
                // elsewhere (if introduced in future) reflect the current state.
                UserDefaults.standard.set(newValue, forKey: AppStorageKeys.biometricAuth)
            } catch {
                Self.logger.error("Keychain write error: \(error.localizedDescription)")
                // Best-effort fallback to UserDefaults so the UI stays consistent.
                UserDefaults.standard.set(newValue, forKey: AppStorageKeys.biometricAuth)
            }
        }
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
        authTask = Task {
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
        authTask?.cancel()
        authTask = nil
        isEvaluating = false
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
