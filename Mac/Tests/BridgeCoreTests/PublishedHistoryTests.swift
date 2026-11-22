import Foundation
import XCTest
@testable import BridgeCore
final class PublishedHistoryTests:XCTestCase {
    func record(_ i:Int,value:Double=100)->HealthRecord {
        HealthRecord(id:String(format:"%064x",i),profileID:"17",metric:.bodyMass,start:1700000000+Double(i),end:1700000000+Double(i),value:value,secondValue:nil,brand:1,deviceModel:19,deviceID:nil,firmware:nil)
    }
    func snapshot(_ records:[HealthRecord],time:Double=1701000000)throws->HealthSnapshot {
        HealthSnapshot(format:HealthSnapshot.formatName,version:1,profileID:"17",revision:Int64(time),publishedAt:time,recordsSHA256:HealthSnapshot.hash(try HealthSnapshot.encoded(records)),records:records)
    }
    func testCapPersistenceAndChangedRecordsOnly()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let old=try snapshot((1...60).map{record($0)})
        let first=try PublishedHistory.record(snapshot:old,previous:nil,state:root)
        XCTAssertEqual(first.count,50);XCTAssertEqual(first[0].id,record(60).id)
        XCTAssertEqual(try PublishedHistory.load(state:root),first)
        let path=root.appendingPathComponent("RecentPublished.json")
        let stamp=try FileManager.default.attributesOfItem(atPath:path.path)[.modificationDate] as! Date
        _=try PublishedHistory.record(snapshot:old,previous:old,state:root)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:path.path)[.modificationDate] as? Date,stamp)
        let next=try snapshot((1...61).map{record($0,value:$0==60 ? 101:100)},time:1701000100)
        let changed=try PublishedHistory.record(snapshot:next,previous:old,state:root)
        XCTAssertEqual(changed.count,50);XCTAssertEqual(changed.first?.id,record(61).id)
        XCTAssertEqual(changed.filter{$0.id==record(60).id}.count,1)
        XCTAssertEqual(changed.first{$0.id==record(60).id}?.publishedAt,Date(timeIntervalSince1970:next.publishedAt))
        XCTAssertEqual(changed.first{$0.id==record(59).id}?.publishedAt,Date(timeIntervalSince1970:old.publishedAt))
        let text=try String(contentsOf:path,encoding:.utf8)
        XCTAssertFalse(text.contains("\"value\""));XCTAssertFalse(text.contains("deviceID"));XCTAssertFalse(text.contains("profileName"))
    }
    func testBootstrapOldSnapshotAndRepairCorruptHistory()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let old=try snapshot([record(1)])
        let seed=try PublishedHistory.record(snapshot:old,previous:old,state:root)
        XCTAssertEqual(seed.count,1);XCTAssertEqual(seed.first?.publishedAt,Date(timeIntervalSince1970:old.publishedAt))
        try Data("invalid".utf8).write(to:root.appendingPathComponent("RecentPublished.json"))
        XCTAssertEqual(try PublishedHistory.record(snapshot:old,previous:old,state:root),seed)
        XCTAssertEqual(try PublishedHistory.load(state:root),seed)
    }
}
