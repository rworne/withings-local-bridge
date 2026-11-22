import XCTest
@testable import BridgeCore
final class ImportHistoryTests:XCTestCase {
    func event(_ id:String,_ measured:Double,_ imported:Double=2000)->BridgeImportEvent {
        BridgeImportEvent(id:id,profileID:"17",metric:.bodyTemperature,measuredAt:Date(timeIntervalSince1970:measured),importedAt:Date(timeIntervalSince1970:imported))
    }
    func testKeepsNewestMeasurementsRatherThanTraversalOrder() {
        let history=BridgeImportHistory.adding((0..<100).reversed().map{event(String($0),Double($0))},to:[])
        XCTAssertEqual(history.count,50)
        XCTAssertEqual(history.first?.id,"99");XCTAssertEqual(history.last?.id,"50")
        let next=BridgeImportHistory.adding([event("old",1,9000),event("latest",500,9000)],to:history)
        XCTAssertEqual(next.count,50);XCTAssertEqual(next.first?.id,"latest")
        XCTAssertFalse(next.contains{$0.id=="old"})
    }
    func testCorrectionReplacesHistoryIdentityAndRoundTrips()throws {
        let updated=event("same",100,3000)
        let history=BridgeImportHistory.adding([updated],to:[event("same",100)])
        XCTAssertEqual(history,[updated])
        XCTAssertEqual(try JSONDecoder().decode([BridgeImportEvent].self,from:JSONEncoder().encode(history)),history)
        XCTAssertEqual(history[0].metric.displayName,"Body Temperature")
    }
    func testProfileInfoValidation()throws {
        let info=BridgeProfileInfo(format:"WithingsHealthBridgeProfile",version:1,profileID:"17",name:"Test Person")
        try info.validate()
        let restored=try JSONDecoder().decode(BridgeProfileInfo.self,from:JSONEncoder().encode(info))
        XCTAssertEqual(restored.name,"Test Person")
        XCTAssertThrowsError(try BridgeProfileInfo(format:info.format,version:1,profileID:"../17",name:nil).validate())
    }
    func testOldSnapshotWithoutNameStillLoads()throws {
        let snapshot=HealthSnapshot(format:HealthSnapshot.formatName,version:1,profileID:"17",revision:1,publishedAt:1000,recordsSHA256:HealthSnapshot.hash(try HealthSnapshot.encoded([HealthRecord]())),records:[])
        var json=try JSONSerialization.jsonObject(with:HealthSnapshot.encoded(snapshot)) as! [String:Any]
        json.removeValue(forKey:"profileName")
        let old=try JSONDecoder().decode(HealthSnapshot.self,from:JSONSerialization.data(withJSONObject:json))
        try old.validate();XCTAssertNil(old.profileName)
    }

}
