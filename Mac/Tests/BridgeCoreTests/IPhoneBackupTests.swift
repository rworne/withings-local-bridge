import XCTest
import CommonCrypto
import SQLite3
@testable import BridgeCore

final class IPhoneBackupTests:XCTestCase {
    func testRFC3394KnownVector() throws {
        func hex(_ s:String)->Data {Data(stride(from:0,to:s.count,by:2).map { i in let a=s.index(s.startIndex,offsetBy:i);return UInt8(s[a..<s.index(a,offsetBy:2)],radix:16)! })}
        XCTAssertEqual(try BackupCrypto.unwrap(hex("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5"),key:hex("000102030405060708090A0B0C0D0E0F")),hex("00112233445566778899AABBCCDDEEFF"))
        XCTAssertFalse(IPhoneBackupSession.allowed("../17_Measure.sqlite"))
        XCTAssertFalse(IPhoneBackupSession.allowed("tokens.sqlite"))
        XCTAssertTrue(IPhoneBackupSession.allowed("17_Measure.sqlite-wal"))
    }
    func testPrivateWALPreparationPreservesCommittedRows() throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source=root.appendingPathComponent("original"),copy=root.appendingPathComponent("private")
        try fm.createDirectory(at:source,withIntermediateDirectories:true)
        try fm.createDirectory(at:copy,withIntermediateDirectories:true)
        defer{try? fm.removeItem(at:root)}
        let file=source.appendingPathComponent("17_WTHealth.sqlite")
        var writer:OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path,&writer),SQLITE_OK)
        defer{sqlite3_close(writer)}
        XCTAssertEqual(sqlite3_exec(writer,"PRAGMA journal_mode=WAL;PRAGMA wal_autocheckpoint=0;CREATE TABLE sample(value INTEGER);INSERT INTO sample VALUES(73)",nil,nil,nil),SQLITE_OK)
        let main=try Data(contentsOf:file),wal=try Data(contentsOf:source.appendingPathComponent("17_WTHealth.sqlite-wal"))
        XCTAssertFalse(wal.isEmpty)
        try main.write(to:copy.appendingPathComponent(file.lastPathComponent))
        try wal.write(to:copy.appendingPathComponent(file.lastPathComponent+"-wal"))
        try IPhoneBackupSession.prepareDatabases(in:copy)
        let reader=try Database(url:copy.appendingPathComponent(file.lastPathComponent),name:"WTHealth")
        try reader.rows("SELECT value FROM sample"){XCTAssertEqual($0.integer("value"),73)}
        try reader.rows("PRAGMA journal_mode"){XCTAssertEqual($0.text("journal_mode"),"delete")}
        XCTAssertEqual(try Data(contentsOf:file),main)
        XCTAssertEqual(try Data(contentsOf:source.appendingPathComponent(file.lastPathComponent+"-wal")),wal)
    }
    func testEncryptedSelectiveExtractionAndWrongPassword() throws {
        let fm=FileManager.default, root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? fm.removeItem(at:root)}
        func save(_ plist:[String:Any],_ name:String)throws {try PropertyListSerialization.data(fromPropertyList:plist,format:.binary,options:0).write(to:root.appendingPathComponent(name))}
        let salt=Data(repeating:3,count:20),dpsl=Data(repeating:4,count:20),classKey=Data(repeating:5,count:32),fileKey=Data(repeating:6,count:32)
        let derived=try BackupCrypto.derive(BackupCrypto.derive(Data("test-only".utf8),salt:dpsl,rounds:2,sha256:true),salt:salt,rounds:2,sha256:false)
        func wrap(_ data:Data,_ key:Data)throws->Data {
            var output=Data(count:data.count+8),size=data.count+8
            let status=output.withUnsafeMutableBytes { out in data.withUnsafeBytes { d in key.withUnsafeBytes { k in
                CCSymmetricKeyWrap(CCWrappingAlgorithm(kCCWRAPAES),nil,0,k.baseAddress!,key.count,d.baseAddress!,data.count,out.baseAddress!,&size)
            } } }
            XCTAssertEqual(status,Int32(kCCSuccess));output.count=size;return output
        }
        func n(_ x:UInt32)->Data {Data([UInt8(x>>24),UInt8((x>>16)&255),UInt8((x>>8)&255),UInt8(x&255)])}
        func tlv(_ tag:String,_ data:Data)->Data {Data(tag.utf8)+n(UInt32(data.count))+data}
        var bag=Data()
        for (tag,value) in [("UUID",Data(repeating:0,count:16)),("DPSL",dpsl),("DPIC",n(2)),("SALT",salt),("ITER",n(2)),("UUID",Data(repeating:1,count:16)),("CLAS",n(4)),("WRAP",n(2)),("WPKY",try wrap(classKey,derived))] {
            bag.append(tlv(tag,value))
        }
        let wrapped=Data([4,0,0,0])+(try wrap(fileKey,classKey))
        try save(["IsEncrypted":true,"BackupKeyBag":bag,"ManifestKey":wrapped],"Manifest.plist")
        try save(["SnapshotState":"finished","Date":Date()],"Status.plist")
        let metadata=try NSKeyedArchiver.archivedData(withRootObject:BackupFileFixture(wrapped),requiringSecureCoding:false)
        XCTAssertEqual(try BackupCrypto.metadata(metadata),wrapped)
        var alternate=try XCTUnwrap(PropertyListSerialization.propertyList(from:metadata,format:nil) as? [String:Any])
        var objects=try XCTUnwrap(alternate["$objects"] as? [Any])
        objects[2] = ["NS.data":wrapped];alternate["$objects"]=objects
        XCTAssertEqual(try BackupCrypto.metadata(PropertyListSerialization.data(fromPropertyList:alternate,format:.binary,options:0)),wrapped)
        func encrypt(_ bytes:Data)->Data {
            let capacity=bytes.count+16; var out=Data(count:capacity),moved=0
            let status=out.withUnsafeMutableBytes { o in bytes.withUnsafeBytes { b in fileKey.withUnsafeBytes { k in
                CCCrypt(CCOperation(kCCEncrypt),CCAlgorithm(kCCAlgorithmAES),CCOptions(kCCOptionPKCS7Padding),k.baseAddress!,fileKey.count,nil,b.baseAddress!,bytes.count,o.baseAddress!,capacity,&moved)
            } } }; XCTAssertEqual(status,Int32(kCCSuccess));out.count=moved;return out
        }
        let index=root.appendingPathComponent("plain.db");var db:OpaquePointer?
        XCTAssertEqual(sqlite3_open(index.path,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"PRAGMA journal_mode=WAL",nil,nil,nil),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE Files(fileID TEXT,domain TEXT,relativePath TEXT,flags INTEGER,file BLOB)",nil,nil,nil),SQLITE_OK)
        let payload=root.appendingPathComponent("payload.db");var payloadDB:OpaquePointer?
        XCTAssertEqual(sqlite3_open(payload.path,&payloadDB),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(payloadDB,"CREATE TABLE sample(value INTEGER);INSERT INTO sample VALUES(42)",nil,nil,nil),SQLITE_OK)
        sqlite3_close(payloadDB)
        let payloadBytes=try Data(contentsOf:payload)
        let blob=metadata.map{String(format:"%02x",$0)}.joined()
        for (id,name,domain) in [(String(repeating:"a",count:40),"17_Measure.sqlite","AppDomain-com.withings.wiScaleNG"),(String(repeating:"b",count:40),"17_Measure.sqlite-wal","AppDomain-com.withings.wiScaleNG"),(String(repeating:"c",count:40),"17_WTHealth.sqlite","AppDomain-other")] {
            try fm.createDirectory(at:root.appendingPathComponent(String(id.prefix(2))),withIntermediateDirectories:true)
            try encrypt(name.hasSuffix("-wal") ? Data() : payloadBytes).write(to:root.appendingPathComponent(String(id.prefix(2))).appendingPathComponent(id))
            XCTAssertEqual(sqlite3_exec(db,"INSERT INTO Files VALUES('\(id)','\(domain)','Library/Application Support/coredata/\(name)',1,X'\(blob)')",nil,nil,nil),SQLITE_OK)
        }
        sqlite3_close(db)
        try encrypt(Data(contentsOf:index)).write(to:root.appendingPathComponent("Manifest.db"))
        let info=try XCTUnwrap(IPhoneBackupInfo.discover(in:root).first)
        XCTAssertThrowsError(try IPhoneBackupSession.open(info,password:"incorrect"))
        var session:IPhoneBackupSession?=try IPhoneBackupSession.open(info,password:"test-only")
        let source=try XCTUnwrap(session?.source)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath:source.path)),["17_Measure.sqlite"])
        let extracted=try Database(url:source.appendingPathComponent("17_Measure.sqlite"),name:"fixture")
        try extracted.rows("SELECT value FROM sample"){XCTAssertEqual($0.integer("value"),42)}
        session=nil;XCTAssertFalse(fm.fileExists(atPath:source.path))
        try save(["IsEncrypted":false],"Manifest.plist")
        try Data(contentsOf:index).write(to:root.appendingPathComponent("Manifest.db"))
        for letter in ["a","b"] {
            let id=String(repeating:letter,count:40)
            try (letter == "b" ? Data() : payloadBytes).write(to:root.appendingPathComponent(String(id.prefix(2))).appendingPathComponent(id))
        }
        let plain=try IPhoneBackupSession.open(XCTUnwrap(IPhoneBackupInfo.discover(in:root).first),password:"")
        XCTAssertEqual(try Data(contentsOf:plain.source.appendingPathComponent("17_Measure.sqlite")),payloadBytes)
        try save(["SnapshotState":"inprogress"],"Status.plist")
        XCTAssertThrowsError(try IPhoneBackupInfo.discover(in:root))
    }
}

@objc(BridgeBackupFileFixture) private final class BackupFileFixture:NSObject,NSCoding {
    let key:NSData
    init(_ data:Data){key=data as NSData}
    required init?(coder:NSCoder){fatalError("No fixture decoding")}
    func encode(with coder:NSCoder){coder.encode(key,forKey:"EncryptionKey")}
}
