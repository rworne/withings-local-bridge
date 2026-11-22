import XCTest
@testable import BridgeCore
final class WindowsExchangeTests:XCTestCase {
    func testWindowsGoldenExchangeIsAcceptedByTheIPhoneFormat()throws {
        var root=URL(fileURLWithPath:#filePath)
        for _ in 0..<4 {root.deleteLastPathComponent()}
        let file=root.appendingPathComponent("Windows/tests/fixtures/swift-exchange.json")
        let snapshot=try JSONDecoder().decode(HealthSnapshot.self,from:Data(contentsOf:file))
        try snapshot.validate()
        XCTAssertEqual(snapshot.records.count,10)
        for row in snapshot.records {
            XCTAssertEqual(row.id,stableID([row.profileID,row.metric.rawValue,String(row.start),String(row.end),"0"]))
        }
    }
}
