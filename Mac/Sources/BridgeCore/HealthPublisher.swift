import Foundation
import Darwin

public enum HealthPublisher {
    // Only these explicit device models, with native/Withings brand codes, are
    // eligible. Unknown brands/models and all third-party model codes fail closed.
    static func eligible(_ r:MeasurementRecord)->Bool {
        guard let model=r.source.deviceModel,HealthSnapshot.devices[Int(model)] != nil,
              let brand=r.source.brand,[0,1].contains(brand),
              !(r.source.bundleIdentifier?.lowercased().hasPrefix("com.apple.") ?? false) else{return false}
        return true
    }
    static func project(_ records:[MeasurementRecord])->[HealthRecord] {
        var selected:[String:(Int,HealthRecord)]=[:]
        for r in records where eligible(r) {
            let model=Int(r.source.deviceModel!)
            let priority=r.source.database=="WTHealth" ? 3:r.source.database=="Measure" ? 2:1
            let values=Dictionary(r.values.map{($0.metric,$0)},uniquingKeysWith:{a,_ in a})
            func number(_ key:String)->Double? {values[key].flatMap{Double($0.value)}.flatMap{$0.isFinite ? $0:nil}}
            func add(_ metric:HealthMetric,_ value:Double,_ second:Double?=nil) {
                guard HealthSnapshot.valid(metric,value,second),r.start>0,r.end>=r.start,r.end-r.start<=7*86400 else{return}
                let position=r.metadata["ZPOSITION"] ?? "0"
                guard position=="0" else{return} // Never export segmental body composition as whole-body values.
                let identity=[r.profileID,metric.rawValue,String(r.start),String(r.end),position]
                let id=stableID(identity)
                let record=HealthRecord(id:id,profileID:r.profileID,metric:metric,start:r.start,end:r.end,value:value,secondValue:second,
                    brand:Int(r.source.brand!),deviceModel:model,deviceID:r.source.deviceID.map(String.init),firmware:r.source.firmware.map(String.init))
                if selected[id].map({$0.0<priority}) ?? true {selected[id]=(priority,record)}
            }
            let map:[String:(HealthMetric,String,Double)]=[
                "weight":(.bodyMass,"kg",1),"bmi":(.bodyMassIndex,"kg/m²",1),
                "fatMassPercentage":(.bodyFatPercentage,"%",0.01),"fatFreeMass":(.leanBodyMass,"kg",1),
                "heartRate":(.heartRate,"bpm",1),"oxygenSaturation":(.oxygenSaturation,"%",0.01),
                "bodyTemperature":(.bodyTemperature,"°C",1)]
            for (name,(metric,unit,factor)) in map {
                if let v=values["quantity."+name],v.unit==unit,let n=number("quantity."+name) {add(metric,n*factor)}
            }
            if let sys=number("quantity.bloodPressureSystolic"),let dia=number("quantity.bloodPressureDiastolic") {
                add(.bloodPressure,sys,dia)
            }
            // Only verified native sleep-mat interval columns are interpreted.
            // Session averages, RMSSD and sleep totals are not fabricated as samples.
            if r.kind=="interval",model==63,r.metadata["ZCATEGORY"]=="1",r.end>r.start {
                if let n=number("interval.sleepStage") {add(.sleepAnalysis,n)}
                if let n=number("interval.heartRate2") {add(.heartRate,n)}
                if let n=number("interval.respiratoryRate1") {add(.respiratoryRate,n)}
                if let n=number("interval.hrvSDNN1"),number("interval.hrvQuality").map({$0>0}) ?? true {add(.heartRateVariabilitySDNN,n/1000)}
            }
            if r.kind=="interval",model != 63,r.metadata["ZCATEGORY"]=="0",r.end>r.start {
                if let n=number("interval.steps") {add(.stepCount,n)}
                if let n=number("interval.sleepStage") {add(.sleepAnalysis,n)}
            }
            // Verified tracker HR family. Other unknown suffixed columns stay excluded.
            if r.kind=="interval",r.metadata["ZCATEGORY"]=="2",r.end>r.start,
               let n=number("interval.heartRate1") {add(.heartRate,n)}
        }
        // Reconcile stores with absent-vs-present local device identifiers. A
        // matching metric/time/model is one logical measurement, not two devices.
        var logical:[String:(Int,HealthRecord)]=[:]
        for (priority,r) in selected.values.sorted(by:{$0.1.id<$1.1.id}) {
            let key=[r.profileID,r.metric.rawValue,String(r.start),String(r.end)].joined(separator:"|")
            if logical[key].map({$0.0<priority}) ?? true {logical[key]=(priority,r)}
        }
        return logical.values.map(\.1).sorted{$0.id<$1.id}
    }
    public static func publish(_ config:BridgeConfiguration,fullSnapshot:Bool=false,progress:(String)->Void={_ in})throws->PublishResult {
        let fm=FileManager.default,source=config.source.standardizedFileURL.resolvingSymlinksInPath(),output=config.output.standardizedFileURL.resolvingSymlinksInPath()
        guard config.state.standardizedFileURL != output,!config.state.path.hasPrefix(source.path+"/"),source != output,!output.path.hasPrefix(source.path+"/"),!source.path.hasPrefix(output.path+"/"),
              !config.state.path.hasPrefix(output.path+"/"),fm.fileExists(atPath:output.path) else {throw BridgeError.message("Choose a separate, available output folder.")}
        try fm.createDirectory(at:config.state,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=Darwin.open(config.state.appendingPathComponent("health.lock").path,O_CREAT|O_RDWR,0o600)
        guard fd>=0 else{throw BridgeError.message("Cannot open private export lock.")}
        defer{_ = flock(fd,LOCK_UN);Darwin.close(fd)}
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else{throw BridgeError.message("An export is already running.")}
        let extracted=try Extractor.extract(folder:source,profile:config.profile,progress:progress)
        progress("Selecting verified Withings devices and supported Health measurements…")
        let records=project(extracted.records),hash=HealthSnapshot.hash(try HealthSnapshot.encoded(records))
        try fm.createDirectory(at:config.state,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // Missing/replaced stores must not silently produce a reduced export.
        let stateURL=config.state.appendingPathComponent("health-sources.json")
        if let data=try? Data(contentsOf:stateURL) {
            let previous=try JSONDecoder().decode([SourceDescription].self,from:data)
            for prior in previous {
                guard extracted.sources.contains(prior) else{throw BridgeError.message("A source database is missing, replaced or changed schema. Choose a new output folder after reviewing it.")}
            }
        }
        // Tiny separate profile file lets the iPhone populate its picker without
        // downloading/decoding a multi-year measurement snapshot first.
        let profileName=try ProfileCatalog.choices(in:source).first{$0.id==config.profile}?.name
        let info=BridgeProfileInfo(format:"WithingsHealthBridgeProfile",version:1,profileID:config.profile,name:profileName)
        let infoURL=output.appendingPathComponent("profile-"+config.profile+".wprofile")
        let infoData=try HealthSnapshot.encoded(info)
        if (try? Data(contentsOf:infoURL)) != infoData {
            var coordinationError:NSError?,writeError:Error?
            NSFileCoordinator().coordinate(writingItemAt:infoURL,options:fm.fileExists(atPath:infoURL.path) ? .forReplacing:[],error:&coordinationError){url in
                do {try infoData.write(to:url,options:.atomic);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}catch{writeError=error}
            }
            if let error=coordinationError ?? writeError as NSError? {throw error}
        }
        let destination=output.appendingPathComponent("profile-"+config.profile+".whealth")
        var revision=Int64(Date().timeIntervalSince1970*1000)
        if fm.fileExists(atPath:destination.path) {
            let previous=try JSONDecoder().decode(HealthSnapshot.self,from:Data(contentsOf:destination));try previous.validate()
            guard previous.profileID==config.profile else{throw BridgeError.message("The output belongs to another profile.")}
            if previous.recordsSHA256==hash && previous.profileName==profileName {return PublishResult(package:nil,upserts:0,deletions:0,total:records.count,message:"No changes in eligible measurements.")}
            revision=max(revision,previous.revision+1)
        }
        let snapshot=HealthSnapshot(format:HealthSnapshot.formatName,version:1,profileID:config.profile,revision:revision,
            publishedAt:Date().timeIntervalSince1970,recordsSHA256:hash,records:records,profileName:profileName)
        try snapshot.validate()
        let payload=try HealthSnapshot.encoded(snapshot)
        let coordinator=NSFileCoordinator();var coordinationError:NSError?,writeError:Error?
        coordinator.coordinate(writingItemAt:destination,options:fm.fileExists(atPath:destination.path) ? .forReplacing:[],error:&coordinationError) {url in
            do {try payload.write(to:url,options:.atomic);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}catch{writeError=error}
        }
        if let error=coordinationError ?? writeError as NSError? {throw error}
        try canonical(extracted.sources).write(to:stateURL,options:.atomic)
        return PublishResult(package:destination,upserts:records.count,deletions:0,total:records.count,
            message:"Published eligible measurements. Excluded \(extracted.records.filter{!eligible($0)}.count) non-Withings or unverified source records.")
    }
}
