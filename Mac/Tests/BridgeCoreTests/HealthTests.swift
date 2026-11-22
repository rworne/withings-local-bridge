import XCTest
@testable import BridgeCore
final class HealthTests:XCTestCase {
    func record(model:Int64?=19,brand:Int64?=1,database:String="WTHealth",id:String="r",start:Double=1_794_944_399,
                values:[MeasurementValue]?=nil,category:String="0",end:Double?=nil)->MeasurementRecord {
        MeasurementRecord(id:id,profileID:"17",kind:database=="vasistas" ? "interval":"measurement",start:start,end:end ?? start,modified:nil,timezone:nil,sessionID:nil,
            values:values ?? [Extractor.value("100",metric:"quantity.weight",unit:"kg",field:"weight")],metadata:["ZCATEGORY":category],
            source:Provenance(database:database,databaseIdentity:"db",entity:"test",sourceRecordID:id,brand:brand,deviceModel:model,deviceID:nil,deviceType:nil,bundleIdentifier:nil,firmware:nil,origin:"not-trusted"))
    }
    func testDeviceFilter() {
        XCTAssertEqual(HealthPublisher.project([record()]).count,1)
        for r in [record(model:1051),record(model:1058),record(model:nil),record(model:999),record(brand:22),record(brand:nil)] {XCTAssertTrue(HealthPublisher.project([r]).isEmpty)}
        XCTAssertEqual(HealthPublisher.project([record(model:63,brand:0)]).count,1)
        XCTAssertNotNil(HealthSnapshot.devices[64])
        XCTAssertNil(HealthSnapshot.devices[1051])
    }
    func testOnlySupportedMeasurementsAndPriority() {
        let unsupported=record(values:[Extractor.value("7.0",metric:"quantity.pulseWaveVelocity",unit:"m/s",field:"pwv"),Extractor.value("80",metric:"quantity.cardioEfficiency",unit:"/100",field:"score")])
        XCTAssertTrue(HealthPublisher.project([unsupported]).isEmpty)
        let first=record(database:"Measure",id:"m",values:[Extractor.value("101",metric:"quantity.weight",unit:"kg",field:"weight")])
        let output=HealthPublisher.project([first,record()]);XCTAssertEqual(output.count,1);XCTAssertEqual(output[0].value,100)
        let correction=HealthPublisher.project([record(values:[Extractor.value("102",metric:"quantity.weight",unit:"kg",field:"weight")])])
        XCTAssertEqual(output[0].id,correction[0].id)
    }
    func testSleepAndHRV() {
        let r=record(model:63,brand:0,database:"vasistas",values:[
            Extractor.value("2",metric:"interval.sleepStage",unit:nil,field:"ZSLEEPLEVEL"),
            Extractor.value("45",metric:"interval.hrvRMSSD1",unit:"ms",field:"RMSSD"),
            Extractor.value("48",metric:"interval.hrvSDNN1",unit:"ms",field:"SDNN")],category:"1",end:1_794_944_459)
        let output=HealthPublisher.project([r]);XCTAssertEqual(Set(output.map(\.metric)),[.sleepAnalysis,.heartRateVariabilitySDNN])
        XCTAssertEqual(output.first{$0.metric == .heartRateVariabilitySDNN}!.value,0.048)
    }
    func testEnvelopeIntegrityAndInvalidSamples()throws {
        let records=HealthPublisher.project([record()])
        let snapshot=HealthSnapshot(format:HealthSnapshot.formatName,version:1,profileID:"17",revision:1,publishedAt:Date().timeIntervalSince1970,recordsSHA256:HealthSnapshot.hash(try HealthSnapshot.encoded(records)),records:records)
        try snapshot.validate()
        let corrupt=HealthSnapshot(format:snapshot.format,version:1,profileID:"17",revision:1,publishedAt:0,recordsSHA256:"bad",records:records)
        XCTAssertThrowsError(try corrupt.validate())
        XCTAssertTrue(HealthPublisher.project([record(values:[Extractor.value("nan",metric:"quantity.weight",unit:"kg",field:"weight")])]).isEmpty)
        XCTAssertTrue(HealthPublisher.project([record(values:[Extractor.value("9999",metric:"quantity.heartRate",unit:"bpm",field:"hr")])]).isEmpty)
    }
    func testBloodPressurePair() {
        let r=record(values:[Extractor.value("120",metric:"quantity.bloodPressureSystolic",unit:"mmHg",field:"sys"),Extractor.value("80",metric:"quantity.bloodPressureDiastolic",unit:"mmHg",field:"dia")])
        let output=HealthPublisher.project([r]);XCTAssertEqual(output.count,1);XCTAssertEqual(output[0].metric,.bloodPressure);XCTAssertEqual(output[0].secondValue,80)
    }
}
