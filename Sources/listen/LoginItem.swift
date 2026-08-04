import ServiceManagement

/// Owns Listen's native macOS login-item registration.
///
/// The ServiceManagement status is the source of truth. UserDefaults only
/// records whether the new-install default has already been considered, so a
/// choice made here or directly in System Settings is never undone at launch.
enum LoginItem {
    enum State: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound

        var isSelected: Bool {
            switch self {
            case .enabled, .requiresApproval: return true
            case .notRegistered, .notFound: return false
            }
        }
    }

    private static let service = SMAppService.mainApp

    static var state: State {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    /// Applies the default once. Existing installations are deliberately left
    /// as they are, including users who already added Listen manually.
    static func applyDefaultIfNeeded(isNewInstallation: Bool) {
        guard !Settings.startAtLoginDefaultApplied else { return }
        Settings.startAtLoginDefaultApplied = true
        guard isNewInstallation else { return }
        setEnabled(true)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                switch state {
                case .enabled, .requiresApproval:
                    break
                case .notRegistered, .notFound:
                    try service.register()
                }
            } else {
                switch state {
                case .enabled, .requiresApproval:
                    try service.unregister()
                case .notRegistered, .notFound:
                    break
                }
            }
            return nil
        } catch {
            let message = enabled
                ? "Could not add Listen to Login Items. Open System Settings and try there."
                : "Could not remove Listen from Login Items. Open System Settings and try there."
            log("could not \(enabled ? "register" : "unregister") login item: \(error)")
            return message
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
