import Foundation

struct BridgeProfileInfo:Codable,Sendable {
    let format:String
    let version:Int
    let profileID:String
    let name:String?
    static func read(from url:URL,expectedID:String)throws->BridgeProfileInfo {
        // A newly selected iCloud folder may expose only a placeholder. Request
        // the named file before inspecting it; otherwise an absent local copy can
        // fail the resource lookup before a download is ever requested.
        try? FileManager.default.startDownloadingUbiquitousItem(at:url)
        let resource=try url.resourceValues(forKeys:[.isUbiquitousItemKey,.isSymbolicLinkKey])
        guard resource.isSymbolicLink != true else{throw ExchangeError.invalid}
        if resource.isUbiquitousItem==true {try FileManager.default.startDownloadingUbiquitousItem(at:url)}
        // A downloaded copy can be readable without status == .current. Coordinate
        // the read instead of waiting indefinitely for that particular status.
        var data:Data?,readError:Error?,coordinationError:NSError?
        NSFileCoordinator().coordinate(readingItemAt:url,options:[],error:&coordinationError){path in
            do {
                let values=try path.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                guard values.isRegularFile==true,values.isSymbolicLink != true,(values.fileSize ?? Int.max)<16384 else{throw ExchangeError.invalid}
                data=try Data(contentsOf:path)
            }catch{readError=error}
        }
        if let error=coordinationError ?? readError as NSError? {throw error}
        guard let data,data.count<16384 else{throw ExchangeError.invalid}
        let info=try JSONDecoder().decode(BridgeProfileInfo.self,from:data)
        try info.validate()
        guard info.profileID==expectedID else{throw ExchangeError.invalid}
        return info
    }
    static func displayName(in folder:URL,expectedID:String,cached:String?,
                            readSnapshot:(URL)throws->HealthSnapshot)->String? {
        func usable(_ value:String?)->String? {
            guard let value,value.count<=160 else{return nil}
            let trimmed=value.split(whereSeparator:\.isWhitespace).joined(separator:" ")
            return trimmed.isEmpty ? nil:trimmed
        }
        let sidecar=folder.appendingPathComponent("profile-"+expectedID+".wprofile")
        if let info=try? read(from:sidecar,expectedID:expectedID),let name=usable(info.name){return name}
        if let name=usable(cached){return name}
        // Name discovery must not require a Health import. The snapshot reader
        // coordinates the iCloud read and validates the complete envelope.
        let file=folder.appendingPathComponent("profile-"+expectedID+".whealth")
        guard let snapshot=try? readSnapshot(file),snapshot.profileID==expectedID else{return nil}
        return usable(snapshot.profileName)
    }
    func validate()throws {
        guard format=="WithingsHealthBridgeProfile",version==1,!profileID.isEmpty,
              profileID.allSatisfy({$0.isASCII && $0.isNumber}),(name?.count ?? 0)<=160 else{throw ExchangeError.invalid}
    }
}
extension HealthMetric {
    var displayName:String {
        switch self {
        case .bodyMass:return "Weight"
        case .bodyMassIndex:return "BMI"
        case .bodyFatPercentage:return "Body Fat"
        case .leanBodyMass:return "Lean Body Mass"
        case .heartRate:return "Heart Rate"
        case .oxygenSaturation:return "Blood Oxygen"
        case .bodyTemperature:return "Body Temperature"
        case .respiratoryRate:return "Respiratory Rate"
        case .heartRateVariabilitySDNN:return "Heart Rate Variability (SDNN)"
        case .stepCount:return "Steps"
        case .sleepAnalysis:return "Sleep"
        case .bloodPressure:return "Blood Pressure"
        }
    }
}
struct BridgeImportEvent:Codable,Identifiable,Equatable,Sendable {
    let id:String
    let profileID:String
    let metric:HealthMetric
    let measuredAt:Date
    let importedAt:Date
}
enum BridgeImportHistory {
    static let limit=50
    // Latest measurement first, not database traversal or completion order.
    static func adding(_ incoming:[BridgeImportEvent],to existing:[BridgeImportEvent])->[BridgeImportEvent] {
        var unique=Dictionary(existing.map{($0.id,$0)},uniquingKeysWith:{a,_ in a})
        for event in incoming {unique[event.id]=event}
        return Array(unique.values.sorted {
            if $0.measuredAt != $1.measuredAt{return $0.measuredAt>$1.measuredAt}
            if $0.importedAt != $1.importedAt{return $0.importedAt>$1.importedAt}
            return $0.id<$1.id
        }.prefix(limit))
    }
}
