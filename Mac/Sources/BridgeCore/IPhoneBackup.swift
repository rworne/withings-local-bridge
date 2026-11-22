import Foundation
import CommonCrypto
import SQLite3

public struct IPhoneBackupInfo: Sendable {
    public let folder: URL
    public let date: Date?
    public let encrypted: Bool
    public static func discover(in folder: URL) throws -> [Self] {
        let fm = FileManager.default
        let candidates = fm.fileExists(atPath: folder.appendingPathComponent("Manifest.plist").path)
            ? [folder] : try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter {
                fm.fileExists(atPath: $0.appendingPathComponent("Manifest.plist").path)
            }
        let found = try candidates.map { url -> Self in
            let manifest = try BackupCrypto.plist(url.appendingPathComponent("Manifest.plist"))
            let status = try? BackupCrypto.plist(url.appendingPathComponent("Status.plist"))
            guard status?["SnapshotState"] as? String == "finished" else {
                throw BridgeError.message("This backup is incomplete. Finish the iPhone backup before importing it.")
            }
            return Self(folder: url, date: status?["Date"] as? Date ?? manifest["Date"] as? Date,
                        encrypted: manifest["IsEncrypted"] as? Bool ?? false)
        }
        guard !found.isEmpty else { throw BridgeError.message("No iPhone backup was found in that folder.") }
        return found.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

/// Owns a private temporary extraction. Its lifetime covers profile selection and publication.
public final class IPhoneBackupSession: @unchecked Sendable {
    public let source: URL
    public let info: IPhoneBackupInfo
    private let temporary: URL
    deinit { try? FileManager.default.removeItem(at: temporary) }
    private init(source: URL, info: IPhoneBackupInfo, temporary: URL) {
        self.source = source; self.info = info; self.temporary = temporary
    }
    public static func open(_ info: IPhoneBackupInfo, password: String,
                            progress: (String) -> Void = { _ in }) throws -> IPhoneBackupSession {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("WithingsBackup-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: temp) } }
        let source = temp.appendingPathComponent("coredata", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let manifest = try BackupCrypto.plist(info.folder.appendingPathComponent("Manifest.plist"))
        var keys: [UInt32: Data] = [:]
        let index: URL
        if info.encrypted {
            progress("Unlocking the encrypted backup. This can take a little while…")
            guard !password.isEmpty, let bag = manifest["BackupKeyBag"] as? Data,
                  let wrapped = manifest["ManifestKey"] as? Data, wrapped.count > 4 else {
                throw BridgeError.message("Enter the password used to encrypt this iPhone backup.")
            }
            keys = try BackupCrypto.unlock(bag, password: password)
            let key = try BackupCrypto.fileKey(wrapped, keys: keys)
            index = temp.appendingPathComponent("Manifest.db")
            try BackupCrypto.decrypt(info.folder.appendingPathComponent("Manifest.db"), to: index, key: key)
        } else {
            index = temp.appendingPathComponent("Manifest.db")
            try fm.copyItem(at:info.folder.appendingPathComponent("Manifest.db"),to:index)
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:index.path)
            let wal=info.folder.appendingPathComponent("Manifest.db-wal")
            if fm.fileExists(atPath:wal.path) {
                try fm.copyItem(at:wal,to:temp.appendingPathComponent("Manifest.db-wal"))
                try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:temp.appendingPathComponent("Manifest.db-wal").path)
            }
        }
        let headerHandle = try FileHandle(forReadingFrom:index)
        let header = try headerHandle.read(upToCount:16)
        try headerHandle.close()
        guard header == Data("SQLite format 3\0".utf8) else {
            throw BridgeError.message("The unlocked backup index is not a SQLite database. Backup decryption did not produce a readable index. No data was published.")
        }
        progress("Finding Withings databases in the backup…")
        var db: OpaquePointer?
        // SQLite may need to initialize WAL shared memory or recover a journal.
        // The index is always a private copy; the original stays untouched.
        let flags = SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(index.path, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw BridgeError.message("The backup index could not be opened.")
        }
        defer { if let db { sqlite3_close(db) } }
        var stmt: OpaquePointer?
        // Exact app domain and directory: no other app's files are extracted.
        let sql = "SELECT fileID,relativePath,file FROM Files WHERE domain='AppDomain-com.withings.wiScaleNG' AND flags=1 AND relativePath LIKE 'Library/Application Support/coredata/%'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let code=sqlite3_extended_errcode(db)
            let detail=String(cString:sqlite3_errmsg(db))
            throw BridgeError.message("The \(info.encrypted ? "unlocked" : "unencrypted") backup index could not be queried (SQLite \(code): \(detail)). No data was published.")
        }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw BridgeError.message("The backup index could not be read (SQLite \(sqlite3_extended_errcode(db)): \(String(cString:sqlite3_errmsg(db)))). No data was published.")
            }
            guard let idText = sqlite3_column_text(stmt, 0), let pathText = sqlite3_column_text(stmt, 1) else { continue }
            let id = String(cString: idText), path = String(cString: pathText)
            let name = String(path.dropFirst("Library/Application Support/coredata/".count))
            guard allowed(name) else { continue }
            // Shared-memory indexes contain no measurements and must be rebuilt on this Mac.
            if name.hasSuffix("-shm") { continue }
            guard id.count == 40, id.allSatisfy({ $0.isHexDigit }), names.insert(name).inserted else {
                throw BridgeError.message("The backup contains an invalid or ambiguous database entry.")
            }
            let nested = info.folder.appendingPathComponent(String(id.prefix(2))).appendingPathComponent(id)
            let input = fm.fileExists(atPath: nested.path) ? nested : info.folder.appendingPathComponent(id)
            guard input.resolvingSymlinksInPath().path.hasPrefix(info.folder.resolvingSymlinksInPath().path + "/"),
                  try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw BridgeError.message("A required Withings database file is missing from the backup.")
            }
            progress("Extracting Withings database \(names.count)…")
            let destination = source.appendingPathComponent(name)
            if info.encrypted {
                let count = Int(sqlite3_column_bytes(stmt, 2))
                guard count > 0, count <= 102_400, let bytes = sqlite3_column_blob(stmt, 2) else {
                    throw BridgeError.message("Missing encryption metadata for a Withings database.")
                }
                let data = Data(bytes: bytes, count: count)
                // NSKeyedArchiver metadata is decoded as a property list, never unarchived as objects.
                let wrapped = try BackupCrypto.metadata(data)
                try BackupCrypto.decrypt(input, to: destination, key: BackupCrypto.fileKey(wrapped, keys: keys))
            } else { try fm.copyItem(at: input, to: destination) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        guard try !Extractor.profiles(in: source).isEmpty else {
            throw BridgeError.message("This backup contains no supported Withings databases. Withings may not have included its local data in the backup.")
        }
        sqlite3_finalize(stmt); stmt=nil
        sqlite3_close(db); db=nil
        for suffix in ["","-wal","-shm","-journal"] {
            let file=temp.appendingPathComponent("Manifest.db"+suffix)
            if fm.fileExists(atPath:file.path) {try fm.removeItem(at:file)}
        }
        progress("Preparing the extracted databases…")
        try prepareDatabases(in:source)
        // Checkpoint private copies so the normal read-only extractor needs no journal writes.
        succeeded = true
        return IPhoneBackupSession(source: source, info: info, temporary: temp)
    }
    static func prepareDatabases(in folder:URL) throws {
        let fm=FileManager.default
        for file in try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)
            .filter({$0.pathExtension == "sqlite" && allowed($0.lastPathComponent)}) {
            var db:OpaquePointer?
            guard sqlite3_open_v2(file.path,&db,SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else {
                let detail=db.map{String(cString:sqlite3_errmsg($0))} ?? "Could not open private copy"
                if let db {sqlite3_close(db)}
                throw BridgeError.message("Cannot prepare \(file.lastPathComponent): \(detail). No data was published.")
            }
            defer {if let db {sqlite3_close(db)}}
            sqlite3_busy_timeout(db,5000)
            // Changing out of WAL mode checkpoints every committed frame first. Failure
            // aborts the import rather than reading a main database without its WAL.
            guard sqlite3_exec(db,"PRAGMA journal_mode=DELETE",nil,nil,nil) == SQLITE_OK else {
                throw BridgeError.message("Cannot prepare \(file.lastPathComponent) (SQLite \(sqlite3_extended_errcode(db)): \(String(cString:sqlite3_errmsg(db)))). No data was published.")
            }
            var mode:OpaquePointer?
            let prepared=sqlite3_prepare_v2(db,"PRAGMA journal_mode",-1,&mode,nil)
            let row=prepared == SQLITE_OK ? sqlite3_step(mode) : SQLITE_ERROR
            let selectedMode=row == SQLITE_ROW ? sqlite3_column_text(mode,0).map{String(cString:$0)} : nil
            sqlite3_finalize(mode)
            guard selectedMode == "delete" else {
                throw BridgeError.message("Could not finish preparing \(file.lastPathComponent). No data was published.")
            }
            sqlite3_close(db);db=nil
            // Empty archived sidecars can survive a no-op mode change. They are
            // obsolete only after successful checkpoint and verified DELETE mode.
            for suffix in ["-wal","-shm"] {
                let sidecar=URL(fileURLWithPath:file.path+suffix)
                if fm.fileExists(atPath:sidecar.path) {try fm.removeItem(at:sidecar)}
            }
        }
    }
    static func allowed(_ name: String) -> Bool {
        if name.range(of: #"^(associated_device|[0-9]+_(WTHealth|Measure|Tracks|vasistas))\.sqlite(-wal|-shm)?$"#, options: .regularExpression) != nil { return true }
        return false
    }
}

// Finder backup cryptography: two-stage PBKDF2, RFC3394 wrapped keys and AES-CBC.
// Uses Apple's CommonCrypto; no external process, network service or runtime dependency.
enum BackupCrypto {
    static func plist(_ url: URL) throws -> [String: Any] {
        guard let result = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
            throw BridgeError.message("Invalid iPhone backup metadata.")
        }
        return result
    }
    static func number(_ data: Data, little: Bool = false) throws -> UInt32 {
        guard data.count == 4 else { throw BridgeError.message("Invalid backup key metadata.") }
        return little ? data.reversed().reduce(0) { ($0 << 8) | UInt32($1) } : data.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    static func derive(_ password: Data, salt: Data, rounds: UInt32, sha256: Bool) throws -> Data {
        guard rounds > 0, rounds <= 20_000_000, !salt.isEmpty, salt.count <= 1024 else { throw BridgeError.message("Unsupported backup password parameters.") }
        var output = Data(count: 32)
        let status = output.withUnsafeMutableBytes { out in password.withUnsafeBytes { pass in salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                                s.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                                CCPseudoRandomAlgorithm(sha256 ? kCCPRFHmacAlgSHA256 : kCCPRFHmacAlgSHA1), rounds,
                                out.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
        } } }
        guard status == kCCSuccess else { throw BridgeError.message("Could not unlock backup encryption.") }
        return output
    }
    static func unwrap(_ wrapped: Data, key: Data) throws -> Data {
        guard wrapped.count >= 24, wrapped.count % 8 == 0, [16,24,32].contains(key.count) else { throw BridgeError.message("Invalid wrapped backup key.") }
        var output = Data(count: wrapped.count - 8), size = wrapped.count - 8
        let status = output.withUnsafeMutableBytes { out in wrapped.withUnsafeBytes { w in key.withUnsafeBytes { k in
            CCSymmetricKeyUnwrap(CCWrappingAlgorithm(kCCWRAPAES), nil, 0, k.baseAddress!, key.count,
                                 w.baseAddress!, wrapped.count, out.baseAddress!, &size)
        } } }
        guard status == kCCSuccess else { throw BridgeError.message("The backup password was not accepted, or the backup key is damaged.") }
        output.count = size
        return output
    }
    static func unlock(_ bag: Data, password: String) throws -> [UInt32: Data] {
        var attrs: [String: Data] = [:], classes: [[String: Data]] = [], current: [String: Data]? = nil
        var offset = 0, seenUUID = false
        while offset < bag.count {
            guard offset + 8 <= bag.count else { throw BridgeError.message("Truncated backup keybag.") }
            let tag = String(decoding: bag[offset..<offset+4], as: UTF8.self)
            let size = Int(try number(Data(bag[offset+4..<offset+8])))
            offset += 8
            guard size <= bag.count - offset else { throw BridgeError.message("Truncated backup keybag.") }
            let value = Data(bag[offset..<offset+size]); offset += size
            if tag == "UUID" {
                if seenUUID { if let current { classes.append(current) }; current = ["UUID":value] }
                seenUUID = true
            } else if current != nil { current![tag] = value }
            else { attrs[tag] = value }
        }
        if let current { classes.append(current) }
        guard let salt = attrs["SALT"], let iterations = attrs["ITER"] else { throw BridgeError.message("Unsupported backup keybag.") }
        var pass = Data(password.utf8)
        if let dpsl = attrs["DPSL"], let dpic = attrs["DPIC"] {
            pass = try derive(pass, salt: dpsl, rounds: number(dpic), sha256: true)
        }
        let derived = try derive(pass, salt: salt, rounds: number(iterations), sha256: false)
        var keys: [UInt32: Data] = [:]
        for item in classes {
            guard let clas = item["CLAS"], let wrap = item["WRAP"], let wrapped = item["WPKY"], try number(wrap) & 2 != 0 else { continue }
            keys[try number(clas)] = try unwrap(wrapped, key: derived)
        }
        guard !keys.isEmpty else { throw BridgeError.message("No supported encryption keys in this backup.") }
        return keys
    }
    static func fileKey(_ wrapped: Data, keys: [UInt32: Data]) throws -> Data {
        guard wrapped.count > 4, let key = keys[try number(Data(wrapped.prefix(4)), little: true)] else {
            throw BridgeError.message("A backup database encryption key is unavailable.")
        }
        return try unwrap(Data(wrapped.dropFirst(4)), key: key)
    }
    static func metadata(_ data: Data) throws -> Data {
        // Read archive references as plain numbers, never instantiate archived classes.
        // Rename the XML key to prevent Foundation from converting it back to an opaque UID.
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let serialized = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let xml = Data(String(decoding: serialized, as: UTF8.self).replacingOccurrences(of:"<key>CF$UID</key>",with:"<key>BackupUID</key>").utf8)
        guard let decoded = try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let objects = decoded["$objects"] as? [Any], let top = decoded["$top"] as? [String: Any],
              let root = top["root"] as? [String: Any], let ri = root["BackupUID"] as? Int, objects.indices.contains(ri),
              let item = objects[ri] as? [String: Any], let ref = item["EncryptionKey"] as? [String: Any],
              let ki = ref["BackupUID"] as? Int, objects.indices.contains(ki),
              let bytes = (objects[ki] as? Data) ?? (objects[ki] as? [String: Any])?["NS.data"] as? Data else { throw BridgeError.message("Unsupported backup file encryption metadata.") }
        return bytes
    }
    static func decrypt(_ input: URL, to output: URL, key: Data) throws {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { k in
            CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress!, key.count, nil, &cryptor)
        }
        guard status == kCCSuccess, let cryptor else { throw BridgeError.message("Could not initialize backup decryption.") }
        defer { CCCryptorRelease(cryptor) }
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions:0o600]) else { throw BridgeError.message("Could not create private database copy.") }
        let read = try FileHandle(forReadingFrom: input), write = try FileHandle(forWritingTo: output)
        defer { try? read.close(); try? write.close() }
        while let chunk = try read.read(upToCount: 1_048_576), !chunk.isEmpty {
            let capacity = chunk.count + 16
            var buffer = Data(count: capacity), moved = 0
            let result = buffer.withUnsafeMutableBytes { out in chunk.withUnsafeBytes { bytes in
                CCCryptorUpdate(cryptor, bytes.baseAddress!, chunk.count, out.baseAddress!, capacity, &moved)
            } }
            guard result == kCCSuccess else { throw BridgeError.message("A backup database could not be decrypted.") }
            try write.write(contentsOf: buffer.prefix(moved))
        }
        var final = Data(count: 16), moved = 0
        let result = final.withUnsafeMutableBytes { CCCryptorFinal(cryptor, $0.baseAddress!, 16, &moved) }
        guard result == kCCSuccess else { throw BridgeError.message("A backup database is damaged or could not be decrypted.") }
        try write.write(contentsOf: final.prefix(moved))
    }
}
