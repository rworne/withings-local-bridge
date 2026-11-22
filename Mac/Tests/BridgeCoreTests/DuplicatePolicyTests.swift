import XCTest
@testable import BridgeCore
final class DuplicatePolicyTests:XCTestCase {
    func sample(_ id:String,owned:Bool=true,type:String="weight",start:Double=1000,end:Double=1000,stage:Int?=nil)->BridgeDuplicateCandidate {
        BridgeDuplicateCandidate(id:id,type:type,start:start,end:end,stage:stage,owned:owned)
    }
    func testPreservesEveryForeignSample() {
        let values=[sample("ours"),sample("withings",owned:false),sample("apple",owned:false)]
        XCTAssertEqual(BridgeDuplicatePolicy.removals(values),["ours"])
        XCTAssertTrue(BridgeDuplicatePolicy.removals([sample("withings",owned:false),sample("apple",owned:false)]).isEmpty)
    }
    func testKeepsOneOwnEntryWhenOnlyOwnDuplicatesExist() {
        XCTAssertEqual(BridgeDuplicatePolicy.removals([sample("c"),sample("a"),sample("b")]),["b","c"])
        XCTAssertTrue(BridgeDuplicatePolicy.removals([sample("only")]).isEmpty)
    }
    func testRequiresSameTypeTimesAndSleepStage() {
        let own=sample("ours",type:"sleep",start:1000,end:1060,stage:2)
        for other in [sample("other",owned:false,type:"weight",end:1060,stage:2),
                      sample("other",owned:false,type:"sleep",start:1001,end:1060,stage:2),
                      sample("other",owned:false,type:"sleep",end:1061,stage:2),
                      sample("other",owned:false,type:"sleep",end:1060,stage:3)] {
            XCTAssertTrue(BridgeDuplicatePolicy.removals([own,other]).isEmpty)
        }
        XCTAssertEqual(BridgeDuplicatePolicy.removals([own,sample("foreign",owned:false,type:"sleep",start:1000.9,end:1060.8,stage:2)]),["ours"])
    }
}
