import FileProvider
import Foundation
import UniformTypeIdentifiers

private actor SessionStore {
    private var session: QuadernoSession?
    private var entryCache: [String: QuadernoEntry] = [:]

    func invalidate() {
        session = nil
    }

    func activeSession() async throws -> QuadernoSession {
        if let existing = session {
            do {
                try await existing.ping()
                return existing
            } catch {
                session = nil
            }
        }

        guard QuadernoDriveConfig.hasCredentials else {
            throw QuadernoError(code: .auth, message: "QUADERNO is not paired yet. Open QuadernoDrive to pair.")
        }

        let credsPath = QuadernoDriveConfig.credentialsDirectory.path

        if let savedAddr = QuadernoDriveConfig.lastDeviceAddress, !savedAddr.isEmpty {
            if let direct = try? QuadernoSession(
                addr: savedAddr,
                mode: .direct,
                configDir: credsPath,
                timeoutMs: 10_000
            ) {
                session = direct
                return direct
            }
        }

        let discovered = try QuadernoSession(
            addr: nil,
            mode: .mdns,
            configDir: credsPath,
            timeoutMs: 10_000
        )
        QuadernoDriveConfig.lastDeviceAddress = await discovered.address
        session = discovered
        return discovered
    }

    func cache(_ entry: QuadernoEntry) {
        entryCache[entry.id] = entry
    }

    func cacheAll(_ entries: [QuadernoEntry]) {
        for e in entries { entryCache[e.id] = e }
    }

    func cachedEntry(for id: String) -> QuadernoEntry? {
        entryCache[id]
    }

    func removeCached(id: String) {
        entryCache.removeValue(forKey: id)
    }
}

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction {
    private let domain: NSFileProviderDomain
    private let store = SessionStore()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {
        Task { await store.invalidate() }
    }

    // MARK: - Session & entry helpers

    private func activeSession() async throws -> QuadernoSession {
        try await store.activeSession()
    }

    private func cache(_ entry: QuadernoEntry) async {
        await store.cache(entry)
    }

    private func removeCached(id: String) async {
        await store.removeCached(id: id)
    }

    func listEntries(in folderId: String) async throws -> [QuadernoEntry] {
        let s = try await activeSession()
        let entries = try await s.listFolder(id: folderId, v2: true)
        await store.cacheAll(entries)
        return entries
    }

    private func fetchEntry(id: String, session s: QuadernoSession) async throws -> QuadernoEntry {
        if let cached = await store.cachedEntry(for: id) {
            if cached.isFolder {
                let fresh = try await s.getFolder(id: id, v2: true)
                await cache(fresh)
                return fresh
            } else {
                let fresh = try await s.getDocument(id: id, v2: true)
                await cache(fresh)
                return fresh
            }
        }
        if let doc = try? await s.getDocument(id: id, v2: true) {
            await cache(doc)
            return doc
        }
        let folder = try await s.getFolder(id: id, v2: true)
        await cache(folder)
        return folder
    }

    // MARK: - NSFileProviderReplicatedExtension

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        if identifier == .rootContainer {
            let root = try? makeRootPlaceholder()
            progress.completedUnitCount = 1
            completionHandler(root, nil)
            return progress
        }

        Task {
            do {
                let s = try await activeSession()
                let entry = try await fetchEntry(id: identifier.rawValue, session: s)
                progress.completedUnitCount = 1
                completionHandler(QuadernoItem(entry: entry), nil)
            } catch {
                completionHandler(nil, Self.mapError(error))
            }
        }
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let s = try await activeSession()
                let entry = try await s.getDocument(id: itemIdentifier.rawValue, v2: true)
                await cache(entry)

                let total = max(entry.fileSize, 1)
                progress.totalUnitCount = total

                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("pdf")

                do {
                    try await s.download(docId: entry.id, to: tmpURL) { bytes in
                        progress.completedUnitCount = min(bytes, total)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: tmpURL)
                    throw error
                }
                progress.completedUnitCount = total
                completionHandler(tmpURL, QuadernoItem(entry: entry), nil)
            } catch {
                completionHandler(nil, nil, Self.mapError(error))
            }
        }
        return progress
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let s = try await activeSession()
                let parentId = itemTemplate.parentItemIdentifier == .rootContainer
                    ? "root"
                    : itemTemplate.parentItemIdentifier.rawValue

                if itemTemplate.contentType == .folder {
                    let newId = try await s.createFolder(parentId: parentId, name: itemTemplate.filename)
                    let created = try await s.getFolder(id: newId, v2: true)
                    await cache(created)
                    progress.completedUnitCount = 1
                    completionHandler(QuadernoItem(entry: created), [], false, nil)
                } else {
                    guard itemTemplate.filename.lowercased().hasSuffix(".pdf"), let url else {
                        completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
                        return
                    }
                    let newId = try await s.uploadFile(parentId: parentId, fileName: itemTemplate.filename, localURL: url)
                    let created = try await s.getDocument(id: newId, v2: true)
                    await cache(created)
                    progress.completedUnitCount = 1
                    completionHandler(QuadernoItem(entry: created), [], false, nil)
                }
            } catch {
                completionHandler(nil, [], false, Self.mapError(error))
            }
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let s = try await activeSession()
                let id = item.itemIdentifier.rawValue
                let isFolder = item.contentType == .folder

                let newName: String? = changedFields.contains(.filename) ? item.filename : nil
                let newParent: String? = changedFields.contains(.parentItemIdentifier)
                    ? (item.parentItemIdentifier == .rootContainer ? "root" : item.parentItemIdentifier.rawValue)
                    : nil

                if newName != nil || newParent != nil {
                    if isFolder {
                        try await s.updateFolder(id: id, name: newName, parentId: newParent)
                    } else {
                        try await s.updateDocument(id: id, fileName: newName, parentId: newParent)
                    }
                }

                if !isFolder, changedFields.contains(.contents), let newContents {
                    let targetRev = String(data: version.contentVersion, encoding: .utf8)
                    _ = try await s.replaceFile(
                        docId: id,
                        localURL: newContents,
                        targetRevision: (targetRev?.isEmpty == false) ? targetRev : nil
                    )
                }

                let updated = isFolder
                    ? try await s.getFolder(id: id, v2: true)
                    : try await s.getDocument(id: id, v2: true)
                await cache(updated)
                progress.completedUnitCount = 1
                completionHandler(QuadernoItem(entry: updated), [], false, nil)
            } catch {
                completionHandler(nil, [], false, Self.mapError(error))
            }
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let s = try await activeSession()
                let id = identifier.rawValue
                let existing = try await fetchEntry(id: id, session: s)
                if existing.isFolder {
                    try await s.deleteFolder(id: id, force: options.contains(.recursive))
                } else {
                    try await s.deleteDocument(id: id)
                }
                await removeCached(id: id)
                progress.completedUnitCount = 1
                completionHandler(nil)
            } catch {
                completionHandler(Self.mapError(error))
            }
        }
        return progress
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        QuadernoEnumerator(containerID: containerItemIdentifier, provider: self)
    }

    // MARK: - NSFileProviderCustomAction ("Open on QUADERNO")

    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard actionIdentifier == QuadernoDriveConfig.openOnDeviceAction,
              let first = itemIdentifiers.first else {
            completionHandler(nil)
            return progress
        }
        Task {
            do {
                let s = try await activeSession()
                try await s.open(docId: first.rawValue)
                progress.completedUnitCount = 1
                completionHandler(nil)
            } catch {
                completionHandler(Self.mapError(error))
            }
        }
        return progress
    }

    // MARK: - Helpers

    private func makeRootPlaceholder() throws -> NSFileProviderItem {
        final class RootItem: NSObject, NSFileProviderItem {
            var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
            var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
            var filename: String { QuadernoDriveConfig.domainDisplayName }
            var contentType: UTType { .folder }
            var capabilities: NSFileProviderItemCapabilities {
                [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating]
            }
        }
        return RootItem()
    }

    static func mapError(_ error: Error) -> Error {
        guard let qe = error as? QuadernoError else { return error }
        switch qe.code {
        case .notFound:
            return NSFileProviderError(.noSuchItem)
        case .auth, .cert, .notPaired:
            return NSFileProviderError(.notAuthenticated)
        case .storageFull:
            return NSFileProviderError(.insufficientQuota)
        case .locked:
            return POSIXError(.EBUSY)
        case .unreachable, .serialMode, .deviceNotFound:
            return NSFileProviderError(.serverUnreachable)
        default:
            return NSFileProviderError(.cannotSynchronize)
        }
    }
}
