import Foundation
import LocalAuthentication
import os

/// A single LocalAuthentication prompt. This small seam lets AuthManager retain
/// and invalidate the exact context currently presenting system UI, while tests
/// can deterministically complete an authentication after a lock transition.
@MainActor
protocol AuthenticationContext: AnyObject {
    var biometryType: LABiometryType { get }
    func canEvaluateBiometrics() -> Bool
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws
    func invalidate()
}

@MainActor
protocol AuthenticationContextFactory {
    func makeContext() -> any AuthenticationContext
}

@MainActor
private final class SystemAuthenticationContext: AuthenticationContext {
    private let context = LAContext()

    var biometryType: LABiometryType { context.biometryType }

    func canEvaluateBiometrics() -> Bool {
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws {
        try await context.evaluatePolicy(policy, localizedReason: localizedReason)
    }

    func invalidate() {
        context.invalidate()
    }

    func hideSystemFallback() {
        context.localizedFallbackTitle = ""
    }
}

@MainActor
private struct SystemAuthenticationContextFactory: AuthenticationContextFactory {
    func makeContext() -> any AuthenticationContext {
        SystemAuthenticationContext()
    }
}

@MainActor @Observable
final class AuthManager {
    static let shared = AuthManager()

    private(set) var isUnlocked = false
    private(set) var isEvaluating = false
    private(set) var biometryType: LABiometryType = .none
    private(set) var biometryAvailable = false
    private var authTask: Task<Void, Never>?
    private var activeContext: (any AuthenticationContext)?
    /// Incremented for every cancellation/lock. An evaluation can still finish
    /// after `Task.cancel()`; this token prevents that late success from
    /// changing lock state.
    private var authenticationGeneration = 0
    private let contextFactory: any AuthenticationContextFactory
    /// Exists only for the injectable initializer used by unit tests. Production
    /// continues to persist the setting in the Keychain below.
    private var enabledOverride: Bool?

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
            if let enabledOverride { return enabledOverride }
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
            if enabledOverride != nil {
                enabledOverride = newValue
                return
            }
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
        self.contextFactory = SystemAuthenticationContextFactory()
        refreshBiometry()
        let enabled = isEnabled
        if !enabled { isUnlocked = true }
        syncExternalPortfolioAccess(locked: enabled)
    }

    /// Test-only initializer. The injected context factory avoids a real
    /// LocalAuthentication prompt and makes cancellation races reproducible.
    init(isEnabled: Bool, contextFactory: any AuthenticationContextFactory) {
        self.contextFactory = contextFactory
        self.enabledOverride = isEnabled
        self.isUnlocked = !isEnabled
        refreshBiometry()
    }

    func authenticate() {
        guard isEnabled, !isUnlocked, !isEvaluating else { return }

        isEvaluating = true
        let generation = authenticationGeneration
        authTask = Task {
            defer { finishAuthenticationAttempt(generation: generation) }
            await evaluateAuthentication(generation: generation)
        }
    }

    func lock() {
        guard isEnabled else { return }
        cancelAuthenticationAttempt()
        isUnlocked = false
        syncExternalPortfolioAccess(locked: true)
    }

    func setEnabled(_ enabled: Bool) {
        cancelAuthenticationAttempt()
        isEnabled = enabled
        isUnlocked = !enabled
        syncExternalPortfolioAccess(locked: enabled)
    }

    private func evaluateAuthentication(generation: Int) async {
        // `lock()` can run after the unstructured Task is created but before it
        // starts. Do not present a new system prompt for that already-revoked
        // attempt.
        guard generation == authenticationGeneration,
              isEnabled,
              !Task.isCancelled else { return }

        // Skip biometrics if hardware isn't available — go straight to passcode.
        let biometricContext = contextFactory.makeContext()
        activeContext = biometricContext
        biometryType = biometricContext.biometryType
        biometryAvailable = biometricContext.canEvaluateBiometrics()

        if biometryAvailable {
            if let systemContext = biometricContext as? SystemAuthenticationContext {
                // We handle passcode fallback ourselves rather than showing the
                // system's fallback button.
                systemContext.hideSystemFallback()
            }

            do {
                try await biometricContext.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Unlock EscapeMint to view your portfolio"
                )
                unlockIfCurrent(generation: generation)
                return
            } catch let error as LAError where error.code == .biometryLockout || error.code == .biometryNotAvailable || error.code == .userFallback {
                // Fall through to passcode.
            } catch {
                Self.logger.info("Auth cancelled: \(error.localizedDescription)")
                return
            }
        }

        let passcodeContext = contextFactory.makeContext()
        activeContext = passcodeContext
        do {
            try await passcodeContext.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock EscapeMint with your passcode"
            )
            unlockIfCurrent(generation: generation)
        } catch {
            Self.logger.info("Auth failed: \(error.localizedDescription)")
        }
    }

    private func unlockIfCurrent(generation: Int) {
        guard generation == authenticationGeneration,
              isEnabled,
              !Task.isCancelled else { return }
        isUnlocked = true
        // A widget or App Intent cannot verify this in-app authentication event.
        // Keep the cross-process snapshot redacted for the full lifetime of an
        // enabled biometric lock; disabling the lock restores its normal data
        // sharing behavior.
    }

    private func cancelAuthenticationAttempt() {
        authenticationGeneration &+= 1
        activeContext?.invalidate()
        activeContext = nil
        authTask?.cancel()
        authTask = nil
        isEvaluating = false
    }

    private func finishAuthenticationAttempt(generation: Int) {
        // A newer lock/auth attempt owns the state now. In particular, do not
        // clear its spinner after a cancelled context returns late.
        guard generation == authenticationGeneration else { return }
        activeContext = nil
        authTask = nil
        isEvaluating = false
        refreshBiometry()
    }

    private func syncExternalPortfolioAccess(locked: Bool) {
        // The App Group snapshot is an iOS widget transport. Avoid touching the
        // group container on macOS, where it has no consumer and can trigger a
        // cross-app-data TCC prompt.
        #if os(iOS)
        WidgetDataProvider.shared.setExternalPortfolioAccessLocked(locked)
        if !locked {
            WidgetDataProvider.shared.updateSnapshot()
        }
        #endif
    }

    private func refreshBiometry() {
        let context = contextFactory.makeContext()
        biometryAvailable = context.canEvaluateBiometrics()
        biometryType = context.biometryType
    }
}
