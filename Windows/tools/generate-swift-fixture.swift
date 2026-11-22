// Run from the repository root with Swift on macOS. Synthetic data only.
import Foundation
import CryptoKit
struct Record:Encodable {
    let id:String,profileID:String,metric:String
    let start:Double,end:Double,value:Double
    let secondValue:Double?
    let brand:Int,deviceModel:Int
    let deviceID:String?,firmware:String?
}
struct Snapshot:Encodable {
    let format="WithingsHealthBridge",version=1,profileID="17"
    let revision:Int64=1
    let publishedAt:Double=1700001000
    let recordsSHA256:String,records:[Record]
    let profileName="Test Person"
}
func hash(_ bytes:Data)->String{SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
func encoded<T:Encodable>(_ value:T)throws->Data{let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(value)}
let samples:[(String,Double,Double,Double,Double?)]=[
    ("bodyMass",1700000000.125,1700000000.125,100.123456789123,nil),
    ("bodyMassIndex",1700000001,1700000001,29.5,nil),
    ("bodyFatPercentage",1700000002,1700000002,24.125*0.01,nil),
    ("heartRate",1700000003.5,1700000003.5,65,nil),
    ("heartRateVariabilitySDNN",1700000004.125,1700000064.125,45.5/1000,nil),
    ("stepCount",1700000005,1700000065,20,nil),
    ("oxygenSaturation",1700000006,1700000006,97*0.01,nil),
    ("bodyTemperature",1700000007,1700000007,36.8125,nil),
    ("sleepAnalysis",1700000008,1700000068,2,nil),
    ("bloodPressure",1700000009,1700000009,130,82)]
let records=try samples.map{metric,start,end,value,second in
    let id=hash(try JSONEncoder().encode(["17",metric,String(start),String(end),"0"]))
    return Record(id:id,profileID:"17",metric:metric,start:start,end:end,value:value,secondValue:second,brand:1,deviceModel:19,deviceID:"123",firmware:nil)
}.sorted{$0.id<$1.id}
let snapshot=Snapshot(recordsSHA256:hash(try encoded(records)),records:records)
try encoded(snapshot).write(to:URL(fileURLWithPath:"Windows/tests/fixtures/swift-exchange.json"))
