import Foundation
import CryptoKit

enum HealthMetric:String,Codable,CaseIterable,Sendable {
    case bodyMass,bodyMassIndex,bodyFatPercentage,leanBodyMass,heartRate,oxygenSaturation,bodyTemperature
    case respiratoryRate,heartRateVariabilitySDNN,stepCount,sleepAnalysis,bloodPressure
}
struct HealthRecord:Codable,Equatable,Sendable {
    let id:String
    let profileID:String
    let metric:HealthMetric
    let start:Double
    let end:Double
    let value:Double
    let secondValue:Double?
    let brand:Int
    let deviceModel:Int
    let deviceID:String?
    let firmware:String?
}
struct HealthSnapshot:Codable,Sendable {
    let format:String
    let version:Int
    let profileID:String
    let revision:Int64
    let publishedAt:Double
    let recordsSHA256:String
    let records:[HealthRecord]
    var profileName:String?=nil
    static let formatName="WithingsHealthBridge"
    static func encoded<T:Encodable>(_ value:T)throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    // Fail closed: verified native model codes from the supplied databases.
    // Brand alone is insufficient: imported Apple Watch data can carry brand 1.
    static let devices:[Int:String] = {
        // Native DeviceModel.allCases intersected with isWithingsDevice (<1001).
        // Software/import models (1051 and above) are deliberately absent.
        let verified = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 41, 42, 43, 44, 45, 46, 47, 48, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 70, 71, 72, 73, 80, 90, 91, 92, 93, 94, 95, 96, 100, 101, 102, 103, 110, 120, 64, 49]
        let names=[16:"Body Scan",19:"Body Scan 2",45:"BPM Connect",48:"BPM Vision",63:"Sleep",71:"BeamO"]
        return Dictionary(uniqueKeysWithValues:verified.map{($0,names[$0] ?? "Withings device \($0)")})
    }()
    func validate()throws {
        guard format==Self.formatName,version==1,!profileID.isEmpty,profileID.allSatisfy(\.isNumber),
              revision>0,records.count<=1_000_000,(profileName?.count ?? 0)<=160,
              Set(records.map(\.id)).count==records.count,
              Self.hash(try Self.encoded(records))==recordsSHA256 else {throw ExchangeError.invalid}
        for r in records {
            guard r.profileID==profileID,[0,1].contains(r.brand),Self.devices[r.deviceModel] != nil,
                  r.id.count==64,r.id.allSatisfy({$0.isHexDigit}),r.start.isFinite,r.start>0,r.end.isFinite,r.end>=r.start,
                  r.end-r.start<=7*86400,r.end<=Date().timeIntervalSince1970+86400,
                  Self.valid(r.metric,r.value,r.secondValue),r.metric != .sleepAnalysis || r.end>r.start else {throw ExchangeError.invalid}
        }
    }
    static func valid(_ metric:HealthMetric,_ value:Double,_ second:Double?=nil)->Bool {
        guard value.isFinite,second?.isFinite != false else{return false}
        switch metric {
        case .bodyMass,.leanBodyMass:return (1...600).contains(value)
        case .bodyMassIndex:return (5...150).contains(value)
        case .bodyFatPercentage:return (0...1).contains(value)
        case .oxygenSaturation:return (0.5...1).contains(value)
        case .heartRate:return (20...300).contains(value)
        case .bodyTemperature:return (25...45).contains(value)
        case .respiratoryRate:return (1...100).contains(value)
        case .heartRateVariabilitySDNN:return (0.001...5).contains(value)
        case .stepCount:return (1...200000).contains(value) && value.rounded()==value
        case .sleepAnalysis:return [0,1,2,3].contains(value)
        case .bloodPressure:return (40...300).contains(value) && second.map{(20...200).contains($0) && value>$0} == true
        }
    }
}
enum ExchangeError:LocalizedError {case invalid;var errorDescription:String?{"The bridge file is incomplete, unsupported or invalid. Wait for iCloud to finish and try again."}}
