//
//  TemporarySpace.swift
//  AgentVFSSQLite
//
//  Created by Yevhenii Kalashnikov on 15.10.2026.
//  Copyright © 2026 Yevhenii Kalashnikov. All rights reserved.
//

import Darwin
import SQLite3

/// A SQLite VFS for one connection that passes everything to the default VFS, but counts the
/// bytes the connection writes to temporary files, such as sorting runs, and fails a write that
/// would pass `limit` with `SQLITE_FULL`.
///
/// It is registered under a name of its own while the connection is open, and unregistered with `close()`.
final class TemporarySpace {
    /// Bytes the connection's temporary files may hold together.
    let limit: Int64
    /// Bytes they hold now.
    var used: Int64 = 0
    /// Set when a write was refused, so the error can say why.
    var exceeded = false
    let name: String
    let base: UnsafeMutablePointer<sqlite3_vfs>
    private let vfs: UnsafeMutablePointer<sqlite3_vfs>
    private let nameBuffer: UnsafeMutablePointer<CChar>

    /// Where a temporary file keeps its counters and the default VFS's file, after `sqlite3_file`.
    static let spaceOffset = MemoryLayout<sqlite3_file>.stride
    static let sizeOffset = spaceOffset + MemoryLayout<UnsafeMutableRawPointer>.stride
    static let baseFileOffset = sizeOffset + MemoryLayout<Int64>.stride

    /// The files SQLite makes for itself, which go away with the connection.
    static let temporaryKinds = SQLITE_OPEN_TEMP_DB | SQLITE_OPEN_TEMP_JOURNAL
        | SQLITE_OPEN_TRANSIENT_DB | SQLITE_OPEN_SUBJOURNAL

    init(limit: Int) throws {
        guard let base = sqlite3_vfs_find(nil) else {
            throw SQLiteError(message: "SQLite has no default file system")
        }
        self.limit = Int64(limit)
        self.base = base
        name = "agentvfs-\(UInt.random(in: 0...UInt.max))"
        nameBuffer = strdup(name)
        vfs = .allocate(capacity: 1)
        var copy = base.pointee
        copy.pNext = nil
        copy.zName = UnsafePointer(nameBuffer)
        copy.szOsFile = Int32(Self.baseFileOffset) + base.pointee.szOsFile
        copy.xOpen = temporarySpaceOpen
        copy.xDelete = temporarySpaceDelete
        copy.xAccess = temporarySpaceAccess
        copy.xFullPathname = temporarySpaceFullPathname
        vfs.initialize(to: copy)
        vfs.pointee.pAppData = Unmanaged.passUnretained(self).toOpaque()
        guard sqlite3_vfs_register(vfs, 0) == SQLITE_OK else {
            vfs.deallocate()
            free(nameBuffer)
            throw SQLiteError(message: "the temporary space limit cannot be set up")
        }
    }

    /// Unregisters the VFS. Call it after the connection that used it is closed.
    func close() {
        sqlite3_vfs_unregister(vfs)
        vfs.deallocate()
        free(nameBuffer)
    }

    static func of(_ vfs: UnsafeMutablePointer<sqlite3_vfs>?) -> TemporarySpace {
        guard let context = vfs?.pointee.pAppData else {
            preconditionFailure("a TemporarySpace VFS always carries its owner")
        }
        return Unmanaged<TemporarySpace>.fromOpaque(context).takeUnretainedValue()
    }
}

private func temporarySpaceDelete(
    vfs: UnsafeMutablePointer<sqlite3_vfs>?,
    name: UnsafePointer<CChar>?,
    syncDirectory: Int32
) -> Int32 {
    let base = TemporarySpace.of(vfs).base
    return base.pointee.xDelete?(base, name, syncDirectory) ?? SQLITE_MISUSE
}

private func temporarySpaceAccess(
    vfs: UnsafeMutablePointer<sqlite3_vfs>?,
    name: UnsafePointer<CChar>?,
    flags: Int32,
    result: UnsafeMutablePointer<Int32>?
) -> Int32 {
    let base = TemporarySpace.of(vfs).base
    return base.pointee.xAccess?(base, name, flags, result) ?? SQLITE_MISUSE
}

private func temporarySpaceFullPathname(
    vfs: UnsafeMutablePointer<sqlite3_vfs>?,
    name: UnsafePointer<CChar>?,
    size: Int32,
    output: UnsafeMutablePointer<CChar>?
) -> Int32 {
    let base = TemporarySpace.of(vfs).base
    return base.pointee.xFullPathname?(base, name, size, output) ?? SQLITE_MISUSE
}

/// Opens a file through the default VFS, wrapping temporary files to count their size.
private func temporarySpaceOpen(
    vfs: UnsafeMutablePointer<sqlite3_vfs>?,
    name: sqlite3_filename?,
    file: UnsafeMutablePointer<sqlite3_file>?,
    flags: Int32,
    outFlags: UnsafeMutablePointer<Int32>?
) -> Int32 {
    let space = TemporarySpace.of(vfs)
    let base = space.base
    guard let file else { return SQLITE_MISUSE }
    guard flags & TemporarySpace.temporaryKinds != 0 else {
        return base.pointee.xOpen?(base, name, file, flags, outFlags) ?? SQLITE_MISUSE
    }
    let raw = UnsafeMutableRawPointer(file)
    let baseFile = (raw + TemporarySpace.baseFileOffset).assumingMemoryBound(to: sqlite3_file.self)
    let status = base.pointee.xOpen?(base, name, baseFile, flags, outFlags) ?? SQLITE_MISUSE
    guard status == SQLITE_OK else {
        file.pointee.pMethods = nil
        return status
    }
    let owner = Unmanaged.passUnretained(space).toOpaque()
    (raw + TemporarySpace.spaceOffset).storeBytes(of: owner, as: UnsafeMutableRawPointer.self)
    (raw + TemporarySpace.sizeOffset).storeBytes(of: Int64(0), as: Int64.self)
    file.pointee.pMethods = UnsafePointer(temporaryFileMethods)
    return SQLITE_OK
}

/// A wrapped temporary file: its owner, its size so far and the default VFS's file inside it.
private struct TemporaryFile {
    let raw: UnsafeMutableRawPointer

    init(_ file: UnsafeMutablePointer<sqlite3_file>?) {
        guard let file else { preconditionFailure("SQLite passes the file it opened") }
        raw = UnsafeMutableRawPointer(file)
    }

    var space: TemporarySpace {
        let context = (raw + TemporarySpace.spaceOffset).load(as: UnsafeMutableRawPointer.self)
        return Unmanaged<TemporarySpace>.fromOpaque(context).takeUnretainedValue()
    }

    var size: Int64 {
        get { (raw + TemporarySpace.sizeOffset).load(as: Int64.self) }
        nonmutating set { (raw + TemporarySpace.sizeOffset).storeBytes(of: newValue, as: Int64.self) }
    }

    var base: UnsafeMutablePointer<sqlite3_file> {
        (raw + TemporarySpace.baseFileOffset).assumingMemoryBound(to: sqlite3_file.self)
    }

    var methods: sqlite3_io_methods {
        guard let methods = base.pointee.pMethods else { preconditionFailure("an open file has methods") }
        return methods.pointee
    }

    /// Records a new size, refusing growth past the limit.
    func resize(to newSize: Int64) -> Bool {
        let space = space
        let grown = space.used - size + newSize
        guard newSize <= size || grown <= space.limit else {
            space.exceeded = true
            return false
        }
        space.used = grown
        size = newSize
        return true
    }
}

/// The methods of a wrapped temporary file: writes and truncation are counted, the rest passed on.
nonisolated(unsafe) private let temporaryFileMethods: UnsafeMutablePointer<sqlite3_io_methods> = {
    let methods = UnsafeMutablePointer<sqlite3_io_methods>.allocate(capacity: 1)
    methods.initialize(to: sqlite3_io_methods(
        iVersion: 1,
        xClose: { file in
            let temporary = TemporaryFile(file)
            _ = temporary.resize(to: 0)
            return temporary.methods.xClose?(temporary.base) ?? SQLITE_MISUSE
        },
        xRead: { file, buffer, amount, offset in
            let temporary = TemporaryFile(file)
            return temporary.methods.xRead?(temporary.base, buffer, amount, offset) ?? SQLITE_MISUSE
        },
        xWrite: { file, buffer, amount, offset in
            let temporary = TemporaryFile(file)
            let end = offset + Int64(amount)
            if end > temporary.size, !temporary.resize(to: end) { return SQLITE_FULL }
            return temporary.methods.xWrite?(temporary.base, buffer, amount, offset) ?? SQLITE_MISUSE
        },
        xTruncate: { file, size in
            let temporary = TemporaryFile(file)
            if size < temporary.size { _ = temporary.resize(to: size) }
            return temporary.methods.xTruncate?(temporary.base, size) ?? SQLITE_MISUSE
        },
        xSync: { file, flags in
            let temporary = TemporaryFile(file)
            return temporary.methods.xSync?(temporary.base, flags) ?? SQLITE_MISUSE
        },
        xFileSize: { file, size in
            let temporary = TemporaryFile(file)
            return temporary.methods.xFileSize?(temporary.base, size) ?? SQLITE_MISUSE
        },
        xLock: { file, level in
            let temporary = TemporaryFile(file)
            return temporary.methods.xLock?(temporary.base, level) ?? SQLITE_MISUSE
        },
        xUnlock: { file, level in
            let temporary = TemporaryFile(file)
            return temporary.methods.xUnlock?(temporary.base, level) ?? SQLITE_MISUSE
        },
        xCheckReservedLock: { file, result in
            let temporary = TemporaryFile(file)
            return temporary.methods.xCheckReservedLock?(temporary.base, result) ?? SQLITE_MISUSE
        },
        xFileControl: { file, operation, argument in
            let temporary = TemporaryFile(file)
            return temporary.methods.xFileControl?(temporary.base, operation, argument) ?? SQLITE_MISUSE
        },
        xSectorSize: { file in
            let temporary = TemporaryFile(file)
            return temporary.methods.xSectorSize?(temporary.base) ?? SQLITE_MISUSE
        },
        xDeviceCharacteristics: { file in
            let temporary = TemporaryFile(file)
            return temporary.methods.xDeviceCharacteristics?(temporary.base) ?? SQLITE_MISUSE
        },
        xShmMap: nil,
        xShmLock: nil,
        xShmBarrier: nil,
        xShmUnmap: nil,
        xFetch: nil,
        xUnfetch: nil
    ))
    return methods
}()
