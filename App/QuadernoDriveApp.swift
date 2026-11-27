import AppKit
import FileProvider
import SwiftUI

@MainActor
final class QuadernoHostController: ObservableObject {
    @Published var statusText: String = "Searching for QUADERNO..."
    @Published var batteryText: String?
    @Published var storageText: String?
    @Published var isPaired: Bool = QuadernoDriveConfig.hasCredentials
    @Published var isPairing: Bool = false
    @Published var lastError: String?

    private var pollTask: Task<Void, Never>?

    init() {
        registerDomainIfNeeded()
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    func registerDomainIfNeeded() {
        let domain = NSFileProviderDomain(
            identifier: QuadernoDriveConfig.domainIdentifier,
            displayName: QuadernoDriveConfig.domainDisplayName
        )
        NSFileProviderManager.add(domain) { error in
            if let error {
                print("FileProvider domain add error: \(error)")
            }
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await pollDeviceOnce()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func pollDeviceOnce() async {
        // Run USB discovery (IOKit + CDC-ECM switch) off the main actor; fallback to mDNS.
        let certURL = QuadernoDriveConfig.credentialsDirectory.appendingPathComponent("devicecert.bin")
        let pinnedCert = try? Data(contentsOf: certURL)
        let discovered: String? = await Task.detached(priority: .utility) {
            if let usb = try? QuadernoSession.discoverAddress(mode: .usb, timeoutMs: 4_000) {
                return usb
            }
            return try? QuadernoSession.discoverAddress(
                mode: .mdns,
                timeoutMs: 2_500,
                pinnedCertDer: pinnedCert
            )
        }.value

        guard let addr = discovered else {
            statusText = isPaired ? "Disconnected (USB / Wi-Fi)" : "Not paired"
            batteryText = nil
            storageText = nil
            return
        }

        let previous = QuadernoDriveConfig.lastDeviceAddress
        QuadernoDriveConfig.lastDeviceAddress = addr

        guard QuadernoDriveConfig.hasCredentials else {
            isPaired = false
            statusText = "Found at \(addr) — pair to mount"
            return
        }
        isPaired = true

        if previous != addr {
            signalFinderRefresh()
        }

        let credsPath = QuadernoDriveConfig.credentialsDirectory.path
        let info: (QuadernoBattery, QuadernoStorage)? = await Task.detached(priority: .utility) {
            guard let s = try? QuadernoSession(addr: addr, mode: .direct, configDir: credsPath, timeoutMs: 8_000) else {
                return nil
            }
            guard let bat = try? await s.battery(), let stor = try? await s.storage() else {
                return nil
            }
            return (bat, stor)
        }.value

        if let (bat, stor) = info {
            statusText = "Connected (\(addr))"
            batteryText = "Battery: \(bat.level)% (\(bat.status))"
            let availGB = Double(stor.available) / 1_000_000_000.0
            let capGB = Double(stor.capacity) / 1_000_000_000.0
            storageText = String(format: "Storage: %.1f / %.1f GB free", availGB, capGB)
            lastError = nil
        } else {
            statusText = "Reachable at \(addr)"
        }
    }

    func signalFinderRefresh() {
        let domain = NSFileProviderDomain(
            identifier: QuadernoDriveConfig.domainIdentifier,
            displayName: QuadernoDriveConfig.domainDisplayName
        )
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { error in
            if let error {
                print("signalEnumerator error: \(error)")
            }
        }
    }

    func openInFinder() {
        let domain = NSFileProviderDomain(
            identifier: QuadernoDriveConfig.domainIdentifier,
            displayName: QuadernoDriveConfig.domainDisplayName
        )
        guard let mgr = NSFileProviderManager(for: domain) else { return }
        Task {
            if let url = try? await mgr.getUserVisibleURL(for: .rootContainer) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func startPairing() {
        guard !isPairing else { return }
        isPairing = true
        lastError = nil
        let credsPath = QuadernoDriveConfig.credentialsDirectory.path
        let lastAddr = QuadernoDriveConfig.lastDeviceAddress

        Task {
            do {
                try await Task.detached {
                    try QuadernoSession.pair(
                        addr: lastAddr,
                        mode: .auto,
                        configDir: credsPath,
                        force: true
                    ) {
                        var enteredPin: String?
                        let sem = DispatchSemaphore(value: 0)
                        DispatchQueue.main.async {
                            let alert = NSAlert()
                            alert.messageText = "Pair with QUADERNO"
                            alert.informativeText = "Enter the 8-digit PIN shown on your QUADERNO screen:"
                            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                            field.placeholderString = "12345678"
                            alert.accessoryView = field
                            alert.addButton(withTitle: "Pair")
                            alert.addButton(withTitle: "Cancel")
                            NSApp.activate(ignoringOtherApps: true)
                            if alert.runModal() == .alertFirstButtonReturn {
                                enteredPin = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            sem.signal()
                        }
                        sem.wait()
                        return enteredPin
                    }
                }.value

                isPairing = false
                isPaired = true
                lastError = nil
                registerDomainIfNeeded()
                signalFinderRefresh()
            } catch {
                isPairing = false
                lastError = error.localizedDescription
            }
        }
    }
}

@main
struct QuadernoDriveApp: App {
    @StateObject private var controller = QuadernoHostController()

    var body: some Scene {
        MenuBarExtra("QUADERNO", systemImage: "doc.text.fill") {
            Text(controller.statusText)
            if let bat = controller.batteryText {
                Text(bat)
            }
            if let stor = controller.storageText {
                Text(stor)
            }
            if let err = controller.lastError {
                Text("Error: \(err)")
                    .foregroundColor(.red)
            }

            Divider()

            Button("Open QUADERNO in Finder") {
                controller.openInFinder()
            }
            .disabled(!controller.isPaired)

            Button("Refresh Finder Drive") {
                controller.signalFinderRefresh()
                Task { await controller.pollDeviceOnce() }
            }

            Button(controller.isPaired ? "Re-pair QUADERNO..." : "Pair QUADERNO...") {
                controller.startPairing()
            }
            .disabled(controller.isPairing)

            Divider()

            Button("Quit QuadernoDrive") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
