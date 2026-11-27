import FileProvider
import Foundation
import UniformTypeIdentifiers

final class QuadernoItem: NSObject, NSFileProviderItem {
    let entry: QuadernoEntry

    init(entry: QuadernoEntry) {
        self.entry = entry
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        if entry.id == "root" {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(entry.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if entry.id == "root" || entry.parentId.isEmpty || entry.parentId == "root" {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(entry.parentId)
    }

    var filename: String {
        entry.name.isEmpty ? entry.id : entry.name
    }

    var contentType: UTType {
        entry.isFolder ? .folder : .pdf
    }

    var documentSize: NSNumber? {
        entry.isFolder || entry.fileSize < 0 ? nil : NSNumber(value: entry.fileSize)
    }

    var creationDate: Date? {
        entry.createdAt
    }

    var contentModificationDate: Date? {
        entry.modifiedAt ?? entry.createdAt
    }

    var capabilities: NSFileProviderItemCapabilities {
        if entry.isFolder {
            return [
                .allowsReading,
                .allowsAddingSubItems,
                .allowsContentEnumerating,
                .allowsRenaming,
                .allowsReparenting,
                .allowsDeleting,
            ]
        }
        return [
            .allowsReading,
            .allowsWriting,
            .allowsRenaming,
            .allowsReparenting,
            .allowsDeleting,
        ]
    }

    var itemVersion: NSFileProviderItemVersion {
        let contentToken = entry.revision.isEmpty ? entry.modifiedDate : entry.revision
        let metaToken = "\(entry.name)|\(entry.parentId)|\(entry.fileSize)|\(entry.modifiedDate)"
        return NSFileProviderItemVersion(
            contentVersion: Data(contentToken.utf8),
            metadataVersion: Data(metaToken.utf8)
        )
    }
}
