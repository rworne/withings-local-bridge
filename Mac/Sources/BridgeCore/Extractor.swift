import Foundation

public enum Extractor {
    public static let databases = ["WTHealth", "Measure", "Tracks", "vasistas"]
    public static func profiles(in folder: URL) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return Array(Set(names.compactMap { name -> String? in
            let parts = name.split(separator: "_", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber),
                  databases.contains(where: { parts[1] == $0 + ".sqlite" }) else { return nil }
            return parts[0]
        })).sorted()
    }
    public static func extract(folder: URL, profile: String, progress: (String) -> Void = { _ in }) throws -> Extraction {
        guard !profile.isEmpty, profile.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw BridgeError.message("Choose a profile from the selected folder.") }
        var records: [MeasurementRecord] = [], sources: [SourceDescription] = [], coverage: [String:Int] = [:]
        // Both stores are necessary to avoid silently dropping scalar measurements.
        for required in ["WTHealth", "Measure"] {
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(profile + "_" + required + ".sqlite").path) else {
                throw BridgeError.message("The selected folder needs \(profile)_\(required).sqlite. No batch was published.")
            }
        }
        for name in databases {
            let file = folder.appendingPathComponent(profile + "_" + name + ".sqlite")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            progress("Reading \(name)…")
            let db = try Database(url: file, name: name)
            try db.beginSnapshot()
            let description = try db.description(); sources.append(description)
            let previous = records.count
            switch name {
            case "WTHealth": try quantities(db, profile, description, &records)
            case "Measure": try measures(db, profile, description, &records)
            case "Tracks", "vasistas":
                // Both databases can contain the same entity families. Preserve the
                // origin instead of collapsing distinct records by rounded values.
                try tracks(db, profile, description, &records)
                try intervals(db, profile, description, &records)
            case "WTVitality": try vitality(db, profile, description, &records)
            case "SignalDB": try recordings(db, profile, description, &records)
            default: break
            }
            coverage[name] = records.count - previous
            guard records.count <= 1_000_000 else { throw BridgeError.message("This profile exceeds the first client's one-million-record safety limit. No partial batch was published.") }
        }
        guard Set(records.map(\.id)).count == records.count else { throw BridgeError.message("Conflicting source identities detected. No batch was published.") }
        return Extraction(records: records.sorted { $0.id < $1.id }, sources: sources.sorted { $0.database < $1.database }, coverage: coverage)
    }
    private static func identity(_ row: [String:Cell], _ keys: [String], description: SourceDescription) throws -> String {
        for key in keys { if let text = row.text(key), !text.isEmpty, text != "0" { return key + ":" + text } }
        guard let key = row.integer("Z_PK") else { throw BridgeError.message("Missing record identity in \(description.database).") }
        return "database:\(description.identity):row:\(key)"
    }
    private static func source(_ row: [String:Cell], _ description: SourceDescription, entity: String, key: String) -> Provenance {
        let brand = row.integer("ZBRAND")
        return Provenance(database: description.database, databaseIdentity: description.identity, entity: entity,
                          sourceRecordID: key, brand: brand, deviceModel: row.integer("ZDEVICEMODEL"),
                          deviceID: row.integer("ZDEVICEID") ?? row.integer("ZDEVICEIDENTIFIER"), deviceType: row.integer("ZDEVTYPE") ?? row.integer("ZDEVICETYPE"),
                          bundleIdentifier: row.text("ZBUNDLEIDENTIFIER"), firmware: row.integer("ZFIRMWARE") ?? row.integer("ZDEVICEFIRMWARE"),
                          origin: brand == 1 ? "withings" : brand == nil ? "unknown" : "other_or_imported")
    }
    private static func make(_ row: [String:Cell], profile: String, description: SourceDescription, entity: String,
                             keys: [String], kind: String, start: Double, end: Double? = nil,
                             values: [MeasurementValue], metadata: [String:String] = [:]) throws -> MeasurementRecord {
        guard start.isFinite, start > 0, (end ?? start).isFinite, (end ?? start) >= start else {
            throw BridgeError.message("Invalid measurement time in \(description.database). No batch was published.")
        }
        let key = try identity(row, keys, description: description)
        var info = metadata
        if let localID = row.text("Z_PK") { info["nativeLocalPrimaryKey"] = localID }
        return MeasurementRecord(id: stableID([profile, description.database, entity, key]), profileID: profile, kind: kind,
                                 start: start, end: end ?? start, modified: row.unix("ZMODIFIEDDATE"), timezone: row.text("ZTIMEZONE"),
                                 sessionID: row.text("BRIDGEPARENT"), values: values.sorted {
                                     if $0.metric != $1.metric { return $0.metric < $1.metric }
                                     if $0.nativeField != $1.nativeField { return $0.nativeField < $1.nativeField }
                                     return (try? canonical($0).lexicographicallyPrecedes(canonical($1))) ?? false
                                 },
                                 metadata: info, source: source(row, description, entity: entity, key: key))
    }
    static func value(_ raw: String, metric: String, unit: String?, field: String, interpretation: String = "mapped", metadata: [String:String] = [:]) -> MeasurementValue {
        MeasurementValue(metric: metric, value: raw, unit: unit, nativeField: field, interpretation: interpretation, metadata: metadata)
    }
    private static func metadata(_ row: [String:Cell], keys: [String]) -> [String:String] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in row.text(key).map { (key,$0) } })
    }
    private static let quantityUnits: [String:String] = [
        "weight":"kg", "fatMass":"kg", "fatFreeMass":"kg", "muscleMass":"kg", "boneMass":"kg", "skeletalMuscleMass":"kg", "hydration":"kg",
        "fatMassPercentage":"%", "fatFreeMassPercentage":"%", "muscleMassPercentage":"%", "boneMassPercentage":"%", "skeletalMuscleMassPercentage":"%", "hydrationPercentage":"%",
        "fatMassSegment":"kg", "fatFreeMassSegment":"kg", "muscleMassSegment":"kg",
        "bodyTemperature":"°C", "skinTemperature":"°C", "temperature":"°C", "pulseWaveVelocity":"m/s",
        "bmi":"kg/m²", "fatMassIndex":"kg/m²", "muscleMassIndex":"kg/m²", "skeletalMuscleMassIndex":"kg/m²",
        "metabolicAge":"years", "basalMetabolicRate":"kcal/day", "sleepScore":"/100", "bodyScore":"/100", "heartScore":"/100", "activityScore":"/100", "overallScore":"/100"
    ]
    private static func quantities(_ db: Database, _ profile: String, _ description: SourceDescription, _ output: inout [MeasurementRecord]) throws {
        try db.require("ZWTOBJECT", ["Z_PK","ZTYPEIDENTIFIER","ZSTARTDATE","ZENDDATE","ZISREMOVED","ZQUANTITY","ZSOURCE","ZSEARCHABLEMETADATA"])
        try db.require("ZWTQUANTITY", ["Z_PK","ZVALUE"])
        try db.require("ZWTSOURCE", ["Z_PK","ZBRAND","ZDEVICEMODEL","ZDEVICEIDENTIFIER","ZDEVICETYPE","ZBUNDLEIDENTIFIER"])
        try db.require("ZWTSEARCHABLEMETADATA", ["Z_PK","ZPOSITION","ZTIMEZONE","ZATTRIB","ZMODIFIEDDATE"])
        let algorithm = try db.columns("ZWTQUANTITY").contains("ZALGORITHMVERSION") ? "q.ZALGORITHMVERSION" : "NULL"
        try db.rows("""
            SELECT o.*,q.ZVALUE AS BRIDGEVALUE,\(algorithm) AS BRIDGEALGORITHM,s.ZBRAND,s.ZDEVICEMODEL,s.ZDEVICEIDENTIFIER,s.ZDEVICETYPE,s.ZBUNDLEIDENTIFIER,
                   m.ZPOSITION,m.ZTIMEZONE,m.ZATTRIB,m.ZMODIFIEDDATE
            FROM ZWTOBJECT o LEFT JOIN ZWTQUANTITY q ON q.Z_PK=o.ZQUANTITY
            LEFT JOIN ZWTSOURCE s ON s.Z_PK=o.ZSOURCE
            LEFT JOIN ZWTSEARCHABLEMETADATA m ON m.Z_PK=o.ZSEARCHABLEMETADATA
            WHERE COALESCE(o.ZISREMOVED,0)=0
            """) { row in
            guard let type = row.text("ZTYPEIDENTIFIER"), let start = row.unix("ZSTARTDATE") else { return }
            // Health attributes are not automatically turned into numeric measurements.
            guard type.hasPrefix("WTQuantityType.") || type.hasPrefix("WTCorrelationType.") else { return }
            let key = String(type.split(separator: ".").last ?? "unknown")
            var values: [MeasurementValue] = []
            if let raw = row.text("BRIDGEVALUE") {
                let unit = quantityUnits[key]
                values = [value(raw, metric: "quantity." + key, unit: unit, field: type,
                                interpretation: unit == nil ? "unverified" : "mapped", metadata: metadata(row,keys:["BRIDGEALGORITHM","ZPOSITION"]))]
            }
            var info = metadata(row, keys: ["ZTYPEIDENTIFIER","ZREMOTEIDENTIFIER","ZPOSITION","ZATTRIB","ZSAMPLE"])
            if let parent = row.text("ZSAMPLE") { info["parentLocalObjectID"] = parent }
            output.append(try make(row, profile: profile, description: description, entity: "ZWTOBJECT", keys: ["ZLOCALIDENTIFIER","ZREMOTEIDENTIFIER"],
                                   kind: type.hasPrefix("WTCorrelationType.") ? "correlation" : "measurement", start: start, end: row.unix("ZENDDATE"), values: values, metadata: info))
        }
    }
    private static let measureFields: [String:(String,String?)] = [
        "ZWEIGHT":("weight","kg"),"ZFATMASS":("fatMass","kg"),"ZFATMASSPERCENTAGE":("fatMassPercentage","%"),
        "ZMUSCLEMASS":("muscleMass","kg"),"ZBONEMASS":("boneMass","kg"),"ZHYDRATATION":("hydration","kg"),
        "ZSYS":("bloodPressureSystolic","mmHg"),"ZDIA":("bloodPressureDiastolic","mmHg"),"ZHEARTRATE":("heartRate","bpm"),
        "ZSP02":("oxygenSaturation","%"),"ZTEMPERATURE":("bodyTemperature","°C"),"ZPWV":("pulseWaveVelocity","m/s"),
        "ZVASCULARAGE":("vascularAge","years"),"ZHEARTAGE":("heartAge","years"),
        "ZCARDIOEFFICIENCY":("cardioEfficiency","/100"),"ZCARDIORESPONSIVENESS":("cardioResponsiveness","/100")
    ]
    private static func measures(_ db: Database, _ profile: String, _ description: SourceDescription, _ output: inout [MeasurementRecord]) throws {
        try db.require("ZWTMEASUREGROUP", ["Z_PK","ZDATE","ZREMOVED"])
        try db.require("ZWTSPECIALIZEDGROUP", ["Z_PK","ZGROUP","Z2_GROUP"])
        try db.require("ZWTMEASURE", ["Z_PK","ZMANTISSA","ZEXPONENT"])
        let columns = try db.columns("ZWTSPECIALIZEDGROUP").subtracting(["Z_PK","Z_ENT","Z_OPT","ZGROUP","Z2_GROUP","ZMEASURETYPE","ZASSOCIATEDREACHEDCOUNTTYPE"])
        var measures: [Int64:[String:Cell]] = [:], groups: [Int64:[[String:Cell]]] = [:]
        try db.rows("SELECT * FROM ZWTMEASURE") { row in if let id=row.integer("Z_PK") { measures[id]=row } }
        try db.rows("SELECT * FROM ZWTSPECIALIZEDGROUP") { row in
            if let id = row.integer("ZGROUP") ?? row.integer("Z2_GROUP") { groups[id,default:[]].append(row) }
        }
        try db.rows("SELECT * FROM ZWTMEASUREGROUP WHERE COALESCE(ZREMOVED,0)=0") { row in
            guard let id=row.integer("Z_PK"), let start=row.unix("ZDATE") else { return }
            var values:[MeasurementValue]=[], info=metadata(row,keys:["ZCATEGORY","ZATTRIB","ZISPROCESSING","ZREMOTEIDENTIFIER"])
            for group in groups[id] ?? [] {
                for field in columns.sorted() {
                    guard let reference=group.integer(field), let measure=measures[reference], let mantissa=measure.integer("ZMANTISSA"), let exponent=measure.integer("ZEXPONENT") else { continue }
                    // Keep integer+exponent representation exact, including precision beyond CSV.
                    let raw="\(mantissa)e\(exponent)"
                    let mapped=measureFields[field]
                    values.append(value(raw,metric:mapped.map{"quantity."+$0.0} ?? "native.measure."+field,unit:mapped?.1,field:field,interpretation:mapped == nil ? "unverified" : "mapped",metadata:metadata(measure,keys:["Z_PK","ZALGOVERSION","ZAPPLIVER","ZAPPPFMID","ZPOSITION"])))
                    for key in ["ZALGOVERSION","ZAPPLIVER","ZAPPPFMID","ZPOSITION"] {
                        if let text=measure.text(key) { info["\(field).\(key)"]=text }
                    }
                }
                if let type=group.text("ZMEASURETYPE") { info["nativeMeasureType"]=type }
            }
            guard !values.isEmpty else { return }
            output.append(try make(row,profile:profile,description:description,entity:"ZWTMEASUREGROUP",keys:["ZIDENTIFIER","ZREMOTEIDENTIFIER"],kind:"measurement_group",start:start,values:values,metadata:info))
        }
    }
    private static func fields(_ row:[String:Cell], _ mapping:[String:(String,String?)], prefix:String) -> [MeasurementValue] {
        mapping.keys.sorted().compactMap { field in
            guard let raw=row.text(field), let spec=mapping[field] else{return nil}
            return value(raw,metric:prefix+spec.0,unit:spec.1,field:field,interpretation:spec.1 == nil ? "unverified":"mapped")
        }
    }
    private static let trackFields:[String:(String,String?)]=[
        "ZSTEPS":("steps","steps"),"ZSTEPS1":("stepsSecondary","steps"),"ZDISTANCE":("distance","m"),"ZDISTANCE1":("distanceSecondary","m"),
        "ZCALORIES":("calories",nil),"ZCALORIESEARNED":("activeCalories",nil),"ZCALORIESPASSIVE":("passiveCalories",nil),
        "ZLIGHTSLEEPDURATION":("lightSleep","s"),"ZDEEPSLEEPDURATION":("deepSleep","s"),"ZREMSLEEPDURATION":("remSleep","s"),
        "ZWAKEUPDURATION":("awake","s"),"ZUNSPECIFIEDSLEEPDURATION":("unspecifiedSleep","s"),"ZMANUALSLEEPDURATION":("manualSleep","s"),
        "ZDURATIONTOSLEEP":("timeToSleep","s"),"ZTIMETOGETUP":("timeToGetUp","s"),"ZWAKEUPCOUNT":("wakeups","count"),
        "ZSNORINGDURATION":("snoring","s"),"ZAPNEAHYPOPNEAINDEX":("ahi","events/h"),
        "ZBREATHINGDISORDERPROBABILITY":("breathingQuality",nil),"ZRESPIRATORYRATEAVERAGE":("respiratoryRateAverage","breaths/min"),
        "ZRESPIRATORYRATEMINIMUM":("respiratoryRateMinimum","breaths/min"),"ZRESPIRATORYRATEMAXIMUM":("respiratoryRateMaximum","breaths/min"),
        "ZHEARTRATERMSSDFIRST90MINAVG":("hrvRMSSDFirst90Minutes","ms"),"ZHEARTRATERMSSDLAST90MINAVG":("hrvRMSSDLast90Minutes","ms"),
        "ZDURATIONMODERATE":("moderateActivity","s"),"ZDURATIONINTENSE":("intenseActivity","s"),"ZDURATIONSOFT":("lightActivity","s"),"ZDURATIONINACTIVE":("inactive","s")]
    private static func tracks(_ db:Database,_ profile:String,_ description:SourceDescription,_ output:inout [MeasurementRecord]) throws {
        guard !(try db.columns("ZTRACK")).isEmpty else { return }
        try db.require("ZTRACK",["Z_PK","ZSTARTDATE","ZENDDATE","ZISREMOVED"])
        var scores:[Int64:[String:Cell]]=[:]
        if !(try db.columns("ZSLEEPSCORE")).isEmpty { try db.rows("SELECT * FROM ZSLEEPSCORE"){if let id=$0.integer("Z_PK"){scores[id]=$0}} }
        try db.rows("SELECT * FROM ZTRACK WHERE COALESCE(ZISREMOVED,0)=0") { row in
            guard let start=row.unix("ZSTARTDATE"),let end=row.unix("ZENDDATE") else{return}
            var values=fields(row,trackFields,prefix:"track.")
            if let id=row.integer("ZSLEEPSCORE"),let score=scores[id] {
                if let raw=score.text("ZOVERALLSCORE"){values.append(value(raw,metric:"sleep.score",unit:"/100",field:"ZSLEEPSCORE.ZOVERALLSCORE"))}
                if let raw=score.text("ZOVERALLSTATUS"){values.append(value(raw,metric:"sleep.status",unit:nil,field:"ZSLEEPSCORE.ZOVERALLSTATUS",interpretation:"native_code"))}
                // Foreign keys to subscore rows are metadata, never score values.
            }
            // Remote track IDs can be shared by distinct local session versions.
            // Namespace the actual Core Data row by database identity; retain both
            // remote/app IDs as metadata instead of assuming either is unique.
            output.append(try make(row,profile:profile,description:description,entity:"ZTRACK",keys:[],kind:"session",start:start,end:end,values:values,
                                   metadata:metadata(row,keys:["ZCATEGORY","ZTYPE","ZAPPTRACKID","ZTRACKID","ZCOMPLETE","ZISNIGHT","ZISPRIMARY","ZISINPROGRESS","ZSLEEPSCORE"])))
        }
    }
    private static let intervalFields:[String:(String,String?)]=[
        "ZHEARTRATE":("heartRate","bpm"),"ZHEARTRATE1":("heartRate1","bpm"),"ZHEARTRATE2":("heartRate2","bpm"),
        "ZRESPIRATORYRATE":("respiratoryRate","breaths/min"),"ZRESPIRATORYRATE1":("respiratoryRate1","breaths/min"),
        "ZHEARTRATERMSSD":("hrvRMSSD","ms"),"ZHEARTRATERMSSD1":("hrvRMSSD1","ms"),"ZHEARTRATESDNN":("hrvSDNN","ms"),"ZHEARTRATESDNN1":("hrvSDNN1","ms"),
        "ZSPO2":("oxygenSaturation","%"),"ZSLEEPLEVEL":("sleepStage",nil),"ZSTEPS":("steps","steps"),"ZMET":("met","MET"),"ZMET1":("met1","MET"),
        "ZAPNEAHYPOPNEAINDEX":("ahi",nil),"ZAPNEAHYPOPNEAINDEX1":("ahi1",nil),"ZBREATHINGDISORDERPROBABILITY":("breathingQuality",nil),
        "ZTEMPERATURE":("temperature",nil),"ZSKINTEMPERATURE":("skinTemperature",nil),"ZGLUCOSE":("glucose",nil),"ZDISTANCE":("distance",nil),
        "ZLATITUDE":("latitude","degrees"),"ZLONGITUDE":("longitude","degrees"),"ZALTITUDE":("altitude",nil),"ZSPEED":("speed",nil),
        "ZHRLEVEL":("hrLevel",nil),"ZHRSTATE":("hrState",nil),"ZQUALITYSCORE":("qualityScore",nil),"ZHEARTRATEVARIABILITYQUALITYSCORE":("hrvQuality",nil),
        "ZSNORINGDURATIONRATIO":("snoringRatio",nil),"ZMOVEMENTS":("movements",nil),"ZMOVEMENTSCORE":("movementScore",nil),"ZCHESTMOVEMENTRATE":("chestMovementRate",nil),"ZWITHINGSINDEX":("withingsIndex",nil)]
    private static func intervals(_ db:Database,_ profile:String,_ description:SourceDescription,_ output:inout [MeasurementRecord]) throws {
        guard !(try db.columns("ZVASISTAS")).isEmpty else{return}
        try db.require("ZVASISTAS",["Z_PK","ZTIMESTAMP","ZDURATION"])
        try db.rows("SELECT * FROM ZVASISTAS") { row in
            guard let start=row.unix("ZTIMESTAMP") else{return}
            let duration=row.number("ZDURATION") ?? 0
            guard duration >= 0 else{throw BridgeError.message("Invalid interval duration in \(description.database).")}
            let values=fields(row,intervalFields,prefix:"interval.")
            guard !values.isEmpty else{return}
            output.append(try make(row,profile:profile,description:description,entity:"ZVASISTAS",keys:[],kind:"interval",start:start,end:start+duration,values:values,
                                   metadata:metadata(row,keys:["ZCATEGORY","ZALGO","ZVERSION","ZAPPVERSION","ZAPPPLATFORMID","ZPRIORITY","ZSOURCE","ZACTIVITYTYPE","ZSPORTMODE","ZATTRIB"])))
        }
    }
    private static func vitality(_ db:Database,_ profile:String,_ description:SourceDescription,_ output:inout [MeasurementRecord]) throws {
        try db.require("ZVITALITYITEM",["Z_PK","ZREFERENCEDATE","ZSCORE","ZRECOVERY","ZEFFORT","ZMALUS"])
        try db.require("ZVITALITYINDICATOR",["Z_PK","ZSCORE","ZSTATUS"])
        try db.require("ZVITALITYCOMPONENT",["Z_PK","ZINDICATOR","ZMETRIC","ZSCORE","ZSTATUS"])
        var indicators:[Int64:[String:Cell]]=[:],components:[Int64:[[String:Cell]]]=[:]
        try db.rows("SELECT * FROM ZVITALITYINDICATOR"){if let id=$0.integer("Z_PK"){indicators[id]=$0}}
        try db.rows("SELECT * FROM ZVITALITYCOMPONENT"){if let id=$0.integer("ZINDICATOR"){components[id,default:[]].append($0)}}
        try db.rows("SELECT * FROM ZVITALITYITEM") { row in
            guard let date=row.unix("ZREFERENCEDATE") else{return}
            var values=fields(row,["ZSCORE":("score","/100"),"ZSTATUS":("status",nil),"ZMAXPROJECTION":("maximumProjection",nil),"ZMINPROJECTION":("minimumProjection",nil)],prefix:"vitality.")
            for (field,label) in [("ZRECOVERY","recovery"),("ZEFFORT","effort"),("ZMALUS","malus")] {
                guard let id=row.integer(field),let indicator=indicators[id] else{continue}
                values += fields(indicator,["ZSCORE":("score",nil),"ZSTATUS":("status",nil)],prefix:"vitality.\(label).")
                for component in components[id] ?? [] {
                    let metric=component.text("ZMETRIC") ?? "unknown"
                    values += fields(component,["ZSCORE":("score",nil),"ZSTATUS":("status",nil)],prefix:"vitality.\(label).component.\(metric).")
                }
            }
            output.append(try make(row,profile:profile,description:description,entity:"ZVITALITYITEM",keys:["ZITEMID"],kind:"daily_score",start:date,values:values,metadata:metadata(row,keys:["ZLIBVERSION","ZTIMESTAMP"])))
        }
    }
    private static func recordings(_ db:Database,_ profile:String,_ description:SourceDescription,_ output:inout [MeasurementRecord]) throws {
        try db.require("ZSIGNAL",["Z_PK","ZDATE","ZREMOVED","ZMETADATA","Z3_METADATA"])
        try db.require("ZSIGNALMETADATA",["Z_PK","ZFREQUENCY","ZCHANNEL","ZFORMAT"])
        var details:[Int64:[String:Cell]]=[:]
        try db.rows("SELECT * FROM ZSIGNALMETADATA"){if let id=$0.integer("Z_PK"){details[id]=$0}}
        try db.rows("SELECT * FROM ZSIGNAL WHERE COALESCE(ZREMOVED,0)=0") { row in
            guard let date=row.unix("ZDATE") else{return}
            var info=metadata(row,keys:["ZTYPE","ZPOSITION","ZISPROCESSING","ZATTRIB"])
            if let id=row.integer("ZMETADATA") ?? row.integer("Z3_METADATA"),let data=details[id] {
                for (key,value) in metadata(data,keys:["ZFREQUENCY","ZCHANNEL","ZFORMAT","ZGAIN","ZOFFSET","ZQFIX","ZRESOLUTION","ZSIZE","ZTOTALSIZE","ZWEARPOSITION"]){info[key]=value}
            }
            info["waveformAvailability"]="not_exported"
            output.append(try make(row,profile:profile,description:description,entity:"ZSIGNAL",keys:["ZIDENTIFIER","ZREMOTEIDENTIFIER"],kind:"recording_metadata",start:date,end:date+max(0,row.number("ZDURATION") ?? 0),values:[],metadata:info))
        }
    }
}
