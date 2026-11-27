import FileProvider
import Foundation

/// Shared identifiers & App Group storage used by both the menu-bar host app
/// (which handles pairing + USB CDC-ECM switching) and the sandboxed FileProvider extension.
enum QuadernoDriveConfig {
    /// Update this to match your Team / App Group in Signing & Capabilities.
    static let appGroupID = "group.net.santablanca.quaderno"

    static let domainIdentifier = NSFileProviderDomainIdentifier("quaderno-default")
    static let domainDisplayName = "QUADERNO"
    static let openOnDeviceAction = NSFileProviderExtensionActionIdentifier("net.santablanca.quaderno.action.openOnDevice")

    private static let lastAddressKey = "lastDeviceAddress"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static var credentialsDirectory: URL {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let dir = groupURL.appendingPathComponent("quaderno-creds", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        // Fallback for local CLI testing outside an App Group
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quaderno", isDirectory: true)
    }

    static var hasCredentials: Bool {
        let dir = credentialsDirectory
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("deviceid.dat").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("privatekey.dat").path)
    }

    /// The host app writes the resolved USB IPv6 (`fe80::...%enX`) or Wi-Fi IP here
    /// so the sandboxed FileProvider extension can connect directly over HTTPS 8443.
    static var lastDeviceAddress: String? {
        get { sharedDefaults?.string(forKey: lastAddressKey) }
        set { sharedDefaults?.set(newValue, forKey: lastAddressKey) }
    }
}
