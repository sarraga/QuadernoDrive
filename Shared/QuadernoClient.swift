import CQuaderno
import Foundation

public enum QuadernoConnMode: UInt32, Sendable {
    case auto = 0
    case usb = 1
    case mdns = 2
    case direct = 3

    var cValue: quaderno_conn_mode_t {
        quaderno_conn_mode_t(rawValue: rawValue)
    }
}

public enum QuadernoErrorCode: Int32, Sendable {
    case ok = 0
    case invalidArg = -1
    case noMem = -2
    case io = -3
    case unreachable = -4
    case cert = -5
    case auth = -6
    case pairing = -7
    case wrongPin = -8
    case http = -9
    case notFound = -10
    case locked = -11
    case storageFull = -12
    case protocolError = -13
    case crypto = -14
    case notPaired = -15
    case serialMode = -16
    case deviceNotFound = -17
    case exists = -18
    case wifiOff = -19
    case bufferTooSmall = -20
}

public struct QuadernoError: Error, LocalizedError, Sendable {
    public let code: QuadernoErrorCode
    public let httpStatus: Int
    public let deviceCode: String
    public let message: String

    init(_ raw: quaderno_error_t) {
        self.code = QuadernoErrorCode(rawValue: raw.code.rawValue) ?? .protocolError
        self.httpStatus = Int(raw.http_status)
        self.deviceCode = withUnsafeBytes(of: raw.device_code) { ptr in
            String(cString: ptr.bindMemory(to: CChar.self).baseAddress!)
        }
        self.message = withUnsafeBytes(of: raw.message) { ptr in
            String(cString: ptr.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    init(code: QuadernoErrorCode, message: String) {
        self.code = code
        self.httpStatus = 0
        self.deviceCode = ""
        self.message = message
    }

    public var errorDescription: String? {
        message.isEmpty ? "QUADERNO error (\(code))" : message
    }
}

public struct QuadernoEntry: Sendable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public let type: String
    public let parentId: String
    public let extId: String
    public let title: String
    public let author: String
    public let documentType: String
    public let revision: String
    public let fileHash: String
    public let createdDate: String
    public let modifiedDate: String
    public let readingDate: String
    public let fileSize: Int64
    public let totalPages: Int
    public let currentPage: Int

    public var isFolder: Bool { type == "folder" }
    public var isDocument: Bool { type == "document" }

    public var createdAt: Date? { Self.parseISO8601(createdDate) }
    public var modifiedAt: Date? { Self.parseISO8601(modifiedDate) }

    private static func parseISO8601(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: value)
    }

    private static func copyCString(_ ptr: UnsafePointer<CChar>?) -> String {
        ptr.map { String(cString: $0) } ?? ""
    }

    init(_ c: quaderno_entry_t) {
        self.id = Self.copyCString(c.id)
        self.name = Self.copyCString(c.name)
        self.path = Self.copyCString(c.path)
        self.type = Self.copyCString(c.type)
        self.parentId = Self.copyCString(c.parent_id)
        self.extId = Self.copyCString(c.ext_id)
        self.title = Self.copyCString(c.title)
        self.author = Self.copyCString(c.author)
        self.documentType = Self.copyCString(c.document_type)
        self.revision = Self.copyCString(c.revision)
        self.fileHash = Self.copyCString(c.file_hash)
        self.createdDate = Self.copyCString(c.created_date)
        self.modifiedDate = Self.copyCString(c.modified_date)
        self.readingDate = Self.copyCString(c.reading_date)
        self.fileSize = c.file_size
        self.totalPages = Int(c.total_pages)
        self.currentPage = Int(c.current_page)
    }
}

public struct QuadernoBattery: Sendable {
    public let level: Int
    public let status: String
    public let plugged: String

    init(_ c: quaderno_battery_t) {
        self.level = Int(c.level)
        self.status = withUnsafeBytes(of: c.status) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        self.plugged = withUnsafeBytes(of: c.plugged) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
}

public struct QuadernoStorage: Sendable {
    public let capacity: Int64
    public let available: Int64
}

/// Concurrency-safe actor wrapping a single `quaderno_t` session handle.
public actor QuadernoSession {
    private var handle: OpaquePointer?

    public init(
        addr: String? = nil,
        mode: QuadernoConnMode = .auto,
        configDir: String? = nil,
        serialHint: String? = nil,
        timeoutMs: Int32 = 30_000,
        authenticate: Bool = true
    ) throws {
        var err = quaderno_error_t()
        let raw: OpaquePointer? = withOptionalCStrings(addr, configDir, serialHint) { cAddr, cCfg, cSer in
            var opts = quaderno_options_t()
            quaderno_options_init(&opts)
            opts.addr = cAddr
            opts.conn_mode = mode.cValue
            opts.config_dir = cCfg
            opts.serial_hint = cSer
            opts.timeout_ms = timeoutMs
            return authenticate ? quaderno_connect(&opts, &err) : quaderno_new(&opts, &err)
        }
        guard let raw else { throw QuadernoError(err) }
        self.handle = raw
    }

    deinit {
        if let handle {
            quaderno_free(handle)
        }
    }

    public var address: String {
        guard let handle, let ptr = quaderno_addr(handle) else { return "" }
        return String(cString: ptr)
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else {
            throw QuadernoError(code: .invalidArg, message: "session closed")
        }
        return handle
    }

    private func check(_ rc: quaderno_err_t, handle: OpaquePointer) throws {
        guard rc == QUADERNO_OK else {
            if let last = quaderno_last_error(handle) {
                throw QuadernoError(last.pointee)
            }
            throw QuadernoError(
                code: QuadernoErrorCode(rawValue: rc.rawValue) ?? .protocolError,
                message: "QUADERNO operation failed"
            )
        }
    }

    public func ping() throws {
        let h = try requireHandle()
        try check(quaderno_ping(h), handle: h)
    }

    public func resolve(path: String, v2: Bool = true) throws -> QuadernoEntry {
        let h = try requireHandle()
        var raw = quaderno_entry_t()
        defer { quaderno_entry_free(&raw) }
        try check(path.withCString { quaderno_resolve(h, $0, v2 ? 1 : 0, &raw) }, handle: h)
        return QuadernoEntry(raw)
    }

    public func getDocument(id: String, v2: Bool = true) throws -> QuadernoEntry {
        let h = try requireHandle()
        var raw = quaderno_entry_t()
        defer { quaderno_entry_free(&raw) }
        try check(id.withCString { quaderno_get_document(h, $0, v2 ? 1 : 0, &raw) }, handle: h)
        return QuadernoEntry(raw)
    }

    public func getFolder(id: String, v2: Bool = true) throws -> QuadernoEntry {
        let h = try requireHandle()
        var raw = quaderno_entry_t()
        defer { quaderno_entry_free(&raw) }
        try check(id.withCString { quaderno_get_folder(h, $0, v2 ? 1 : 0, &raw) }, handle: h)
        return QuadernoEntry(raw)
    }

    public func listFolder(id: String, v2: Bool = true) throws -> [QuadernoEntry] {
        let h = try requireHandle()
        var list = quaderno_entry_list_t()
        defer { quaderno_entry_list_free(&list) }
        try check(id.withCString { quaderno_list_folder(h, $0, v2 ? 1 : 0, nil, nil, &list) }, handle: h)
        guard let items = list.items, list.count > 0 else { return [] }
        return (0 ..< list.count).map { QuadernoEntry(items[$0]) }
    }

    public func download(docId: String, to destinationURL: URL, onProgress: (@Sendable (Int64) -> Void)? = nil) throws {
        let h = try requireHandle()
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: destinationURL)
        defer { try? fh.close() }

        final class DownloadBox {
            let fh: FileHandle
            var written: Int64 = 0
            let onProgress: (@Sendable (Int64) -> Void)?
            var writeError: Error?
            init(fh: FileHandle, onProgress: (@Sendable (Int64) -> Void)?) {
                self.fh = fh
                self.onProgress = onProgress
            }
        }

        let box = DownloadBox(fh: fh, onProgress: onProgress)
        let cb: quaderno_write_cb = { data, len, ctx in
            guard let data, let ctx else { return 0 }
            let box = Unmanaged<DownloadBox>.fromOpaque(ctx).takeUnretainedValue()
            do {
                try box.fh.write(contentsOf: UnsafeRawBufferPointer(start: data, count: len))
                box.written += Int64(len)
                box.onProgress?(box.written)
                return len
            } catch {
                box.writeError = error
                return 0
            }
        }

        var total: Int64 = 0
        let rc = withExtendedLifetime(box) {
            let ud = Unmanaged.passUnretained(box).toOpaque()
            return docId.withCString { quaderno_download(h, $0, -1, -1, cb, ud, &total) }
        }
        if let writeError = box.writeError { throw writeError }
        try check(rc, handle: h)
    }

    public func uploadFile(parentId: String, fileName: String, localURL: URL) throws -> String {
        let h = try requireHandle()
        var outBuf = [CChar](repeating: 0, count: 128)
        let rc = parentId.withCString { cParent in
            fileName.withCString { cName in
                localURL.path.withCString { cPath in
                    quaderno_upload_file(h, cParent, cName, nil, cPath, &outBuf, outBuf.count)
                }
            }
        }
        try check(rc, handle: h)
        return String(cString: outBuf)
    }

    public func replaceFile(docId: String, localURL: URL, targetRevision: String? = nil) throws -> String {
        let h = try requireHandle()
        var res = quaderno_upload_result_t()
        let rc = docId.withCString { cDoc in
            localURL.path.withCString { cPath in
                withOptionalCString(targetRevision) { cRev in
                    quaderno_replace_file(h, cDoc, cPath, cRev, nil, &res)
                }
            }
        }
        try check(rc, handle: h)
        return withUnsafeBytes(of: res.file_revision) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    public func updateDocument(id: String, fileName: String? = nil, parentId: String? = nil) throws {
        let h = try requireHandle()
        let rc = id.withCString { cId in
            withOptionalCStrings(fileName, parentId, nil) { cName, cParent, _ in
                quaderno_update_document(h, cId, cName, cParent, nil)
            }
        }
        try check(rc, handle: h)
    }

    public func deleteDocument(id: String, targetRevision: String? = nil) throws {
        let h = try requireHandle()
        let rc = id.withCString { cId in
            withOptionalCString(targetRevision) { cRev in
                quaderno_delete_document(h, cId, cRev)
            }
        }
        try check(rc, handle: h)
    }

    public func createFolder(parentId: String, name: String) throws -> String {
        let h = try requireHandle()
        var outBuf = [CChar](repeating: 0, count: 128)
        let rc = parentId.withCString { cParent in
            name.withCString { cName in
                quaderno_create_folder(h, cParent, cName, nil, &outBuf, outBuf.count)
            }
        }
        try check(rc, handle: h)
        return String(cString: outBuf)
    }

    public func updateFolder(id: String, name: String? = nil, parentId: String? = nil) throws {
        let h = try requireHandle()
        let rc = id.withCString { cId in
            withOptionalCStrings(name, parentId, nil) { cName, cParent, _ in
                quaderno_update_folder(h, cId, cName, cParent, nil)
            }
        }
        try check(rc, handle: h)
    }

    public func deleteFolder(id: String, force: Bool = false) throws {
        let h = try requireHandle()
        try check(id.withCString { quaderno_delete_folder(h, $0, force ? 1 : 0) }, handle: h)
    }

    public func open(docId: String, page: Int = 0) throws {
        let h = try requireHandle()
        try check(docId.withCString { quaderno_open(h, $0, Int32(page)) }, handle: h)
    }

    public func battery() throws -> QuadernoBattery {
        let h = try requireHandle()
        var b = quaderno_battery_t()
        try check(quaderno_battery(h, &b), handle: h)
        return QuadernoBattery(b)
    }

    public func storage() throws -> QuadernoStorage {
        let h = try requireHandle()
        var s = quaderno_storage_t()
        try check(quaderno_storage(h, &s), handle: h)
        return QuadernoStorage(capacity: s.capacity, available: s.available)
    }

    // MARK: - Static discovery & pairing helpers

    public static func discoverAddress(
        mode: QuadernoConnMode = .auto,
        serialHint: String? = nil,
        timeoutMs: Int32 = 10_000,
        cachedWifiAddr: String? = nil,
        pinnedCertDer: Data? = nil
    ) throws -> String {
        var addrBuf = [CChar](repeating: 0, count: 256)
        var errBuf = [CChar](repeating: 0, count: 256)
        let rc: quaderno_err_t = withOptionalCStrings(serialHint, cachedWifiAddr, nil) { cSer, cCached, _ in
            if let pinnedCertDer, !pinnedCertDer.isEmpty {
                return pinnedCertDer.withUnsafeBytes { rawBuf in
                    var dopts = quaderno_discover_opts_t()
                    quaderno_discover_opts_init(&dopts)
                    dopts.mode = mode.cValue
                    dopts.serial_hint = cSer
                    dopts.cached_wifi_addr = cCached
                    dopts.pinned_cert_der = rawBuf.bindMemory(to: UInt8.self).baseAddress
                    dopts.pinned_cert_len = pinnedCertDer.count
                    dopts.timeout_ms = timeoutMs
                    return quaderno_discover_ex(&dopts, &addrBuf, addrBuf.count, &errBuf, errBuf.count)
                }
            }
            var dopts = quaderno_discover_opts_t()
            quaderno_discover_opts_init(&dopts)
            dopts.mode = mode.cValue
            dopts.serial_hint = cSer
            dopts.cached_wifi_addr = cCached
            dopts.timeout_ms = timeoutMs
            return quaderno_discover_ex(&dopts, &addrBuf, addrBuf.count, &errBuf, errBuf.count)
        }
        guard rc == QUADERNO_OK else {
            let code = QuadernoErrorCode(rawValue: rc.rawValue) ?? .unreachable
            throw QuadernoError(code: code, message: String(cString: errBuf))
        }
        return String(cString: addrBuf)
    }

    public static func pair(
        addr: String? = nil,
        mode: QuadernoConnMode = .auto,
        configDir: String? = nil,
        force: Bool = false,
        pinProvider: @escaping () -> String?
    ) throws {
        final class PinBox {
            let provider: () -> String?
            init(_ provider: @escaping () -> String?) { self.provider = provider }
        }
        let box = PinBox(pinProvider)
        let cb: quaderno_pin_cb = { pinOut, pinCap, ctx in
            guard let pinOut, let ctx else { return -1 }
            let box = Unmanaged<PinBox>.fromOpaque(ctx).takeUnretainedValue()
            guard let pin = box.provider() else { return -1 }
            let bytes = Array(pin.utf8)
            guard bytes.count < pinCap else { return -1 }
            for (i, b) in bytes.enumerated() { pinOut[i] = CChar(bitPattern: b) }
            pinOut[bytes.count] = 0
            return 0
        }

        var err = quaderno_error_t()
        let rc = withExtendedLifetime(box) {
            let ud = Unmanaged.passUnretained(box).toOpaque()
            return withOptionalCStrings(addr, configDir, nil) { cAddr, cCfg, _ in
                var opts = quaderno_options_t()
                quaderno_options_init(&opts)
                opts.addr = cAddr
                opts.conn_mode = mode.cValue
                opts.config_dir = cCfg
                return quaderno_pair(&opts, cb, ud, force ? 1 : 0, &err)
            }
        }
        guard rc == QUADERNO_OK else { throw QuadernoError(err) }
    }
}

private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    if let s {
        return s.withCString { body($0) }
    }
    return body(nil)
}

private func withOptionalCStrings<R>(
    _ s1: String?, _ s2: String?, _ s3: String?,
    _ body: (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> R
) -> R {
    withOptionalCString(s1) { c1 in
        withOptionalCString(s2) { c2 in
            withOptionalCString(s3) { c3 in
                body(c1, c2, c3)
            }
        }
    }
}
