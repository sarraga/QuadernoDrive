import FileProvider
import Foundation

final class QuadernoEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerID: NSFileProviderItemIdentifier
    private weak var provider: FileProviderExtension?

    init(containerID: NSFileProviderItemIdentifier, provider: FileProviderExtension) {
        self.containerID = containerID
        self.provider = provider
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard let provider else {
            observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            return
        }

        Task {
            do {
                let folderId: String
                if containerID == .rootContainer || containerID == .workingSet {
                    folderId = "root"
                } else {
                    folderId = containerID.rawValue
                }

                let entries = try await provider.listEntries(in: folderId)
                let items = entries.map { QuadernoItem(entry: $0) }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.mapError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let stamp = String(Int64(Date().timeIntervalSince1970))
        completionHandler(NSFileProviderSyncAnchor(Data(stamp.utf8)))
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // Trigger a full re-enumeration on sync-anchor change; QUADERNO has no server-side change feed.
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }
}
