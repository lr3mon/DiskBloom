import Darwin
import Foundation

struct ScanEntry {
    enum Kind { case file, directory, other }

    let name: String
    let kind: Kind
    let size: Int64
    let modifiedAt: Date?
    var isMountPoint = false
}

/// Reads metadata without opening file contents. Unsupported volumes and attributes
/// fall back to Foundation; a failed entry never aborts the rest of a directory.
struct DirectoryReader {
    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
        .contentModificationDateKey, .isVolumeKey
    ]

    let fileManager: FileManager
    let strategy: DiskScanner.MetadataStrategy
    private let buffers = DirectoryBufferPool()

    init(fileManager: FileManager, strategy: DiskScanner.MetadataStrategy) {
        self.fileManager = fileManager
        self.strategy = strategy
    }

    func metadata(at url: URL) throws -> ScanEntry {
        let values = try url.resourceValues(forKeys: Self.resourceKeys)
        let kind: ScanEntry.Kind
        if values.isSymbolicLink == true { kind = .other }
        else if values.isDirectory == true { kind = .directory }
        else if values.isRegularFile == true { kind = .file }
        else { kind = .other }
        return ScanEntry(
            name: url.lastPathComponent,
            kind: kind,
            size: Int64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)),
            modifiedAt: values.contentModificationDate,
            isMountPoint: values.isVolume == true
        )
    }

    func enumerate(
        path: String,
        checkCancellation: () throws -> Void,
        unreadable: () -> Void,
        visit: (ScanEntry) throws -> Void
    ) throws {
        try checkCancellation()
        if strategy == .foundation {
            try enumerateFoundation(path: path, checkCancellation: checkCancellation, unreadable: unreadable, visit: visit)
            return
        }

        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { unreadable(); return }
        defer { Darwin.close(descriptor) }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR)
            | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_OBJTYPE)
            | UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_FLAGS)
        attributes.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)
        attributes.fileattr = UInt32(ATTR_FILE_ALLOCSIZE)

        // A buffer stays leased until every callback returns, including recursive
        // scans. Collapsed sibling directories reuse it instead of repeatedly
        // allocating and releasing a large VM-backed block.
        let capacity = DirectoryBufferPool.capacity
        let buffer = buffers.acquire()
        defer { buffers.release(buffer) }
        var hasReadEntries = false
        while true {
            try checkCancellation()
            let count = getattrlistbulk(descriptor, &attributes, buffer, capacity, 0)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if !hasReadEntries && (code == ENOTSUP || code == EINVAL || code == ENOSYS) {
                    try enumerateFoundation(path: path, checkCancellation: checkCancellation, unreadable: unreadable, visit: visit)
                } else {
                    unreadable()
                }
                return
            }
            if count == 0 { return }
            hasReadEntries = true

            try autoreleasepool {
                var offset = 0
                for index in 0..<count {
                    if index % 128 == 0 { try checkCancellation() }
                    guard offset <= capacity - MemoryLayout<UInt32>.size else { unreadable(); return }
                    let record = buffer.advanced(by: offset)
                    let length = Int(record.loadUnaligned(as: UInt32.self))
                    guard length >= 24, length <= capacity - offset else { unreadable(); return }
                    offset += length
                    switch Self.parse(record: UnsafeRawBufferPointer(start: record, count: length)) {
                    case .entry(let entry):
                        try visit(entry)
                    case .fallback(let name, let isMountPoint):
                        let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name)
                        var entry: ScanEntry
                        do { entry = try metadata(at: url) }
                        catch { unreadable(); continue }
                        if entry.kind == .file && name.hasPrefix("._") { continue }
                        entry.isMountPoint = entry.isMountPoint || isMountPoint
                        try visit(entry)
                    case .unreadable:
                        unreadable()
                    case .ignored:
                        break
                    }
                }
            }
        }
    }

    private func enumerateFoundation(
        path: String,
        checkCancellation: () throws -> Void,
        unreadable: () -> Void,
        visit: (ScanEntry) throws -> Void
    ) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let entries: [URL]
        do {
            // Recheck before the fallback so a replaced directory link is not followed.
            guard try metadata(at: url).kind == .directory else { return }
            entries = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(Self.resourceKeys), options: [])
        } catch { unreadable(); return }
        for entryURL in entries {
            try checkCancellation()
            try autoreleasepool {
                let entry: ScanEntry
                do { entry = try metadata(at: entryURL) }
                catch { unreadable(); return }
                try visit(entry)
            }
        }
    }

    private enum ParsedEntry {
        case entry(ScanEntry)
        case fallback(String, isMountPoint: Bool)
        case unreadable
        case ignored
    }

    private static func parse(record: UnsafeRawBufferPointer) -> ParsedEntry {
        var cursor = AttributeCursor(record: record, offset: 4)
        guard let returned: attribute_set_t = cursor.read() else { return .unreadable }
        if returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 {
            guard let error: UInt32 = cursor.read(), error == 0 else { return .unreadable }
        }
        // Fields are packed only when their returned-attribute bits are set.
        // In particular, directory records do not contain file size fields.
        guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else { return .unreadable }
        let referenceOffset = cursor.offset
        guard let reference: attrreference_t = cursor.read() else { return .unreadable }
        let nameOffset = referenceOffset + Int(reference.attr_dataoffset)
        let nameLength = Int(reference.attr_length)
        guard nameOffset >= cursor.offset, nameLength > 1,
              nameOffset <= record.count, nameLength <= record.count - nameOffset,
              record[nameOffset + nameLength - 1] == 0 else { return .unreadable }
        let nameBytes = UnsafeRawBufferPointer(rebasing: record[nameOffset..<(nameOffset + nameLength - 1)])
        guard !nameBytes.contains(0), !nameBytes.contains(0x2F),
              let name = String(validatingUTF8: nameBytes.baseAddress!.assumingMemoryBound(to: CChar.self)),
              name != ".", name != ".." else { return .unreadable }
        guard returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0,
              let type: UInt32 = cursor.read() else { return .fallback(name, isMountPoint: false) }
        // Foundation suppresses AppleDouble companion files during enumeration,
        // but directories with that prefix must still be scanned.
        if type == UInt32(VREG.rawValue) && name.hasPrefix("._") { return .ignored }
        var modifiedAt: Date?
        if returned.commonattr & UInt32(ATTR_CMN_MODTIME) != 0 {
            guard let time: timespec = cursor.read() else { return .unreadable }
            modifiedAt = Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
        }
        var flags: UInt32 = 0
        if returned.commonattr & UInt32(ATTR_CMN_FLAGS) != 0 {
            guard let value: UInt32 = cursor.read() else { return .unreadable }
            flags = value
        }
        var mountStatus: UInt32 = 0
        if returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 {
            guard let value: UInt32 = cursor.read() else { return .unreadable }
            mountStatus = value
        }
        if returned.fileattr & UInt32(ATTR_FILE_TOTALSIZE) != 0 {
            guard let _: Int64 = cursor.read() else { return .unreadable }
        }
        var allocatedSize: Int64?
        if returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE) != 0 {
            guard let value: Int64 = cursor.read() else { return .unreadable }
            allocatedSize = max(0, value)
        }
        guard cursor.offset <= nameOffset else { return .unreadable }

        if type == UInt32(VDIR.rawValue) {
            // Bulk attributes describe the underlying mount point / firmlink,
            // whereas the UI needs the directory that its path actually opens.
            let isMountPoint = mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
            if flags & UInt32(SF_FIRMLINK) != 0 || isMountPoint {
                return .fallback(name, isMountPoint: isMountPoint)
            }
            return .entry(ScanEntry(name: name, kind: .directory, size: 0, modifiedAt: modifiedAt))
        }
        if type == UInt32(VREG.rawValue) {
            guard let allocatedSize else { return .fallback(name, isMountPoint: false) }
            return .entry(ScanEntry(name: name, kind: .file, size: allocatedSize, modifiedAt: modifiedAt))
        }
        return .entry(ScanEntry(name: name, kind: .other, size: 0, modifiedAt: modifiedAt))
    }
}

/// Owned by one serial DiskScanner. Reentrant enumeration leases additional
/// buffers; no pointer is returned to the pool while a parser can still use it.
private final class DirectoryBufferPool {
    static let capacity = 256 * 1024
    private var available: [UnsafeMutableRawPointer] = []

    func acquire() -> UnsafeMutableRawPointer {
        available.popLast() ?? .allocate(byteCount: Self.capacity, alignment: 8)
    }

    func release(_ buffer: UnsafeMutableRawPointer) {
        available.append(buffer)
    }

    deinit {
        for buffer in available { buffer.deallocate() }
    }
}

private struct AttributeCursor {
    let record: UnsafeRawBufferPointer
    var offset: Int

    mutating func read<T>() -> T? {
        let size = MemoryLayout<T>.size
        guard offset <= record.count, size <= record.count - offset else { return nil }
        defer { offset += size }
        return record.loadUnaligned(fromByteOffset: offset, as: T.self)
    }
}
