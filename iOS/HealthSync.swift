import Foundation
import HealthKit

@MainActor final class HealthSync {
    let store=HKHealthStore()
    static let ownerKey="local.withingshealthbridge.profile"
    static let contentKey="local.withingshealthbridge.content"
    static let deviceKey="local.withingshealthbridge.deviceModel"
    struct Summary {var saved=0;var matched=0;var unchanged=0;var denied=0;var removed=0}
    static func quantity(_ metric:HealthMetric)->(HKQuantityType,HKUnit)? {
        let rate=HKUnit.count().unitDivided(by:.minute())
        switch metric {
        case .bodyMass:return (HKQuantityType(.bodyMass),.gramUnit(with:.kilo))
        case .bodyMassIndex:return (HKQuantityType(.bodyMassIndex),.count())
        case .bodyFatPercentage:return (HKQuantityType(.bodyFatPercentage),.percent())
        case .leanBodyMass:return (HKQuantityType(.leanBodyMass),.gramUnit(with:.kilo))
        case .heartRate:return (HKQuantityType(.heartRate),rate)
        case .oxygenSaturation:return (HKQuantityType(.oxygenSaturation),.percent())
        case .bodyTemperature:return (HKQuantityType(.bodyTemperature),.degreeCelsius())
        case .respiratoryRate:return (HKQuantityType(.respiratoryRate),rate)
        case .heartRateVariabilitySDNN:return (HKQuantityType(.heartRateVariabilitySDNN),.second())
        case .stepCount:return (HKQuantityType(.stepCount),.count())
        default:return nil
        }
    }
    static func types()->Set<HKSampleType> {
        var types=Set(HealthMetric.allCases.compactMap{quantity($0)?.0 as HKSampleType?})
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKQuantityType(.bloodPressureSystolic));types.insert(HKQuantityType(.bloodPressureDiastolic))
        return types
    }
    var hasWriteAccess:Bool {HKHealthStore.isHealthDataAvailable() && Self.types().contains{store.authorizationStatus(for:$0) == .sharingAuthorized}}
    func authorize()async throws {
        guard HKHealthStore.isHealthDataAvailable() else{throw SyncFailure("Apple Health is unavailable on this device.")}
        let types=Self.types()
        try await store.requestAuthorization(toShare:Set(types),read:Set(types.map{$0 as HKObjectType}))
    }
    func read(_ type:HKSampleType,start:Date,end:Date)async throws->[HKSample] {
        try await withCheckedThrowingContinuation {continuation in
            let predicate=HKQuery.predicateForSamples(withStart:start.addingTimeInterval(-1),end:end.addingTimeInterval(1),options:[])
            let query=HKSampleQuery(sampleType:type,predicate:predicate,limit:HKObjectQueryNoLimit,sortDescriptors:nil) {_,samples,error in
                if let error {continuation.resume(throwing:error)}else{continuation.resume(returning:samples ?? [])}
            }
            store.execute(query)
        }
    }
    func sync(_ snapshot:HealthSnapshot,progress:@escaping(String)->Void,didImport:@escaping([BridgeImportEvent])->Void)async throws->Summary {
        try snapshot.validate()
        var summary=Summary()
        let source=HKSource.default()
        // Read each sample type once per covered week, not once per measurement.
        let groups=Dictionary(grouping:snapshot.records){Int($0.start/(7*86400))}
        for (week,records) in groups.sorted(by:{$0.key<$1.key}) {
            try Task.checkCancellation()
            progress("Checking \(summary.saved+summary.matched+summary.unchanged+summary.denied) of \(snapshot.records.count)…")
            var requested:Set<HKSampleType>=[]
            for r in records {
                if r.metric == .sleepAnalysis {requested.insert(HKCategoryType(.sleepAnalysis))}
                else if r.metric == .bloodPressure {requested.formUnion([HKQuantityType(.bloodPressureSystolic),HKQuantityType(.bloodPressureDiastolic)])}
                else if let (type,_)=Self.quantity(r.metric) {requested.insert(type)}
            }
            var existing:[String:[HKSample]]=[:]
            let start=Date(timeIntervalSince1970:Double(week)*7*86400)
            let end=Date(timeIntervalSince1970:max(Double(week+1)*7*86400,records.map(\.end).max() ?? 0))
            for type in requested {existing[type.identifier]=try await read(type,start:start,end:end)}
            // Constant-time lookup matters for years of minute-by-minute data.
            func timeKey(_ start:Double,_ end:Double,_ stage:Int?=nil)->String {
                "\(Int64(floor(start)))|\(Int64(floor(end)))|\(stage.map(String.init) ?? "")"
            }
            var ownIndex:[String:[String:HKSample]]=[:],foreignIndex:[String:Set<String>]=[:]
            for (type,samples) in existing {
                for sample in samples {
                    if sample.sourceRevision.source == source {
                        if let id=sample.metadata?[HKMetadataKeySyncIdentifier] as? String {ownIndex[type,default:[:]][id]=sample}
                    } else {
                        let stage=(sample as? HKCategorySample)?.value
                        foreignIndex[type,default:[]].insert(timeKey(sample.startDate.timeIntervalSince1970,sample.endDate.timeIntervalSince1970,stage))
                    }
                }
            }
            var pending:[HKSample]=[]
            var pendingEvents:[BridgeImportEvent]=[]
            func flush()async throws {
                guard !pending.isEmpty else{return}
                try Task.checkCancellation()
                try await store.save(pending)
                // Report only after HealthKit confirms this batch was saved, so
                // partial/expired runs still retain their successful imports.
                didImport(pendingEvents)
                pending=[];pendingEvents=[]
            }
            var duplicateOwn:[HKObject]=[]
            for r in records {
                try Task.checkCancellation()
                let start=Date(timeIntervalSince1970:r.start),end=Date(timeIntervalSince1970:r.end)
                let before=pending.count
                let content=HealthSnapshot.hash(try HealthSnapshot.encoded(r))
                func metadata(_ id:String,_ previous:HKSample?)->[String:Any] {
                    let old=(previous?.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.int64Value ?? 0
                    return [HKMetadataKeySyncIdentifier:"WithingsHealthBridge|"+snapshot.profileID+"|"+id,
                        HKMetadataKeySyncVersion:NSNumber(value:max(snapshot.revision,old+1)),Self.ownerKey:snapshot.profileID,
                        Self.contentKey:content,Self.deviceKey:r.deviceModel]
                }
                let device=HKDevice(name:HealthSnapshot.devices[r.deviceModel],manufacturer:"Withings",model:String(r.deviceModel),
                    hardwareVersion:nil,firmwareVersion:r.firmware,softwareVersion:nil,localIdentifier:r.deviceID,udiDeviceIdentifier:nil)
                func matching(_ type:HKSampleType,_ id:String)->(HKSample?,Bool) {
                    let own=ownIndex[type.identifier]?["WithingsHealthBridge|"+snapshot.profileID+"|"+id]
                    let stages=[HKCategoryValueSleepAnalysis.awake.rawValue,HKCategoryValueSleepAnalysis.asleepCore.rawValue,HKCategoryValueSleepAnalysis.asleepDeep.rawValue,HKCategoryValueSleepAnalysis.asleepREM.rawValue]
                    let stage=r.metric == .sleepAnalysis ? stages[Int(r.value)]:nil
                    let foreign=foreignIndex[type.identifier]?.contains(timeKey(r.start,r.end,stage)) ?? false
                    return (own,foreign)
                }
                func quantity(_ type:HKQuantityType,_ unit:HKUnit,_ value:Double,_ id:String)->HKQuantitySample? {
                    guard store.authorizationStatus(for:type) == .sharingAuthorized else{summary.denied+=1;return nil}
                    let (own,foreign)=matching(type,id)
                    if foreign {if let own {duplicateOwn.append(own)};summary.matched+=1;return nil}
                    if (own?.metadata?[Self.contentKey] as? String)==content {summary.unchanged+=1;return nil}
                    return HKQuantitySample(type:type,quantity:HKQuantity(unit:unit,doubleValue:value),start:start,end:end,device:device,metadata:metadata(id,own))
                }
                if let (type,unit)=Self.quantity(r.metric) {
                    if let sample=quantity(type,unit,r.value,r.id) {pending.append(sample);summary.saved+=1}
                } else if r.metric == .sleepAnalysis {
                    let type=HKCategoryType(.sleepAnalysis)
                    guard store.authorizationStatus(for:type) == .sharingAuthorized else{summary.denied+=1;continue}
                    let (own,foreign)=matching(type,r.id)
                    if foreign {if let own {duplicateOwn.append(own)};summary.matched+=1;continue}
                    if (own?.metadata?[Self.contentKey] as? String)==content {summary.unchanged+=1;continue}
                    let values=[HKCategoryValueSleepAnalysis.awake.rawValue,HKCategoryValueSleepAnalysis.asleepCore.rawValue,HKCategoryValueSleepAnalysis.asleepDeep.rawValue,HKCategoryValueSleepAnalysis.asleepREM.rawValue]
                    pending.append(HKCategorySample(type:type,value:values[Int(r.value)],start:start,end:end,device:device,metadata:metadata(r.id,own)));summary.saved+=1
                } else if r.metric == .bloodPressure,let dia=r.secondValue {
                    let sys=quantity(HKQuantityType(.bloodPressureSystolic),.millimeterOfMercury(),r.value,r.id+"|s")
                    let diastolic=quantity(HKQuantityType(.bloodPressureDiastolic),.millimeterOfMercury(),dia,r.id+"|d")
                    if let sys,let diastolic {
                        let correlation=HKCorrelation(type:HKCorrelationType(.bloodPressure),start:start,end:end,
                            objects:Set([sys,diastolic]),metadata:metadata(r.id,nil))
                        pending.append(correlation);summary.saved+=2
                    } else {if let sys{pending.append(sys);summary.saved+=1};if let diastolic{pending.append(diastolic);summary.saved+=1}}
                }
                if pending.count>before {
                    let event=BridgeImportEvent(id:snapshot.profileID+"|"+r.id,profileID:snapshot.profileID,metric:r.metric,
                        measuredAt:Date(timeIntervalSince1970:r.start),importedAt:Date())
                    pendingEvents=BridgeImportHistory.adding([event],to:pendingEvents)
                }
                if pending.count>=200 {try await flush()}
            }
            try await flush()
            if !duplicateOwn.isEmpty {try Task.checkCancellation();try await store.delete(duplicateOwn);summary.removed+=duplicateOwn.count}
        }
        // A validated snapshot is authoritative only for this profile and app.
        // Source removals must never delete another application's samples.
        let prefix="WithingsHealthBridge|"+snapshot.profileID+"|"
        var current=Set(snapshot.records.map(\.id))
        for r in snapshot.records where r.metric == .bloodPressure {current.insert(r.id+"|s");current.insert(r.id+"|d")}
        let owned=NSCompoundPredicate(andPredicateWithSubpredicates:[HKQuery.predicateForObjects(from:source),
            HKQuery.predicateForObjects(withMetadataKey:Self.ownerKey,allowedValues:[snapshot.profileID])])
        var cleanupTypes=Array(Self.types().filter{store.authorizationStatus(for:$0) == .sharingAuthorized})
        if store.authorizationStatus(for:HKQuantityType(.bloodPressureSystolic)) == .sharingAuthorized && store.authorizationStatus(for:HKQuantityType(.bloodPressureDiastolic)) == .sharingAuthorized {
            cleanupTypes.insert(HKCorrelationType(.bloodPressure),at:0)
        }
        for type in cleanupTypes {
            try Task.checkCancellation()
            let samples:[HKSample]=try await withCheckedThrowingContinuation {continuation in
                let query=HKSampleQuery(sampleType:type,predicate:owned,limit:HKObjectQueryNoLimit,sortDescriptors:nil){_,samples,error in
                    if let error {continuation.resume(throwing:error)}else{continuation.resume(returning:samples ?? [])}
                };store.execute(query)
            }
            let obsolete=samples.filter {sample in
                guard let id=sample.metadata?[HKMetadataKeySyncIdentifier] as? String,id.hasPrefix(prefix) else{return false}
                return !current.contains(String(id.dropFirst(prefix.count)))
            }
            if !obsolete.isEmpty {try Task.checkCancellation();try await store.delete(obsolete);summary.removed+=obsolete.count}
        }
        return summary
    }
    private func ownedSamples(_ type:HKSampleType)async throws->[HKSample] {
        try await withCheckedThrowingContinuation {continuation in
            let query=HKSampleQuery(sampleType:type,predicate:HKQuery.predicateForObjects(from:HKSource.default()),limit:HKObjectQueryNoLimit,sortDescriptors:nil){_,samples,error in
                if let error{continuation.resume(throwing:error)}else{continuation.resume(returning:samples ?? [])}
            }
            store.execute(query)
        }
    }
    // Scans the Health store itself, including all profiles this app imported.
    // Does not need the original iCloud file and never deletes foreign samples.
    func removeDuplicates(progress:@escaping(String)->Void)async throws->Int {
        var removed=0
        let source=HKSource.default()
        for type in Self.types().sorted(by:{$0.identifier<$1.identifier}) {
            try Task.checkCancellation()
            progress("Checking duplicates (\(removed) removed)…")
            let own=try await ownedSamples(type)
            let weeks=Dictionary(grouping:own){Int($0.startDate.timeIntervalSince1970/(7*86400))}
            for (week,candidates) in weeks.sorted(by:{$0.key<$1.key}) {
                try Task.checkCancellation()
                let start=Date(timeIntervalSince1970:Double(week)*7*86400)
                let end=max(start.addingTimeInterval(7*86400),candidates.map(\.endDate).max() ?? start)
                let samples=try await read(type,start:start,end:end)
                let lookup=samples.map{sample in
                    BridgeDuplicateCandidate(id:sample.uuid.uuidString,type:type.identifier,start:sample.startDate.timeIntervalSince1970,
                        end:sample.endDate.timeIntervalSince1970,stage:(sample as? HKCategorySample)?.value,owned:sample.sourceRevision.source==source)
                }
                let ids=BridgeDuplicatePolicy.removals(lookup)
                let duplicates=candidates.filter{ids.contains($0.uuid.uuidString) && $0.sourceRevision.source==source}
                // Delete in bounded batches, checking cancellation between them.
                for offset in stride(from:0,to:duplicates.count,by:200) {
                    try Task.checkCancellation()
                    let batch=Array(duplicates[offset..<min(offset+200,duplicates.count)])
                    try await store.delete(batch);removed+=batch.count
                }
            }
        }
        // Drop only empty bridge-owned BP containers after component cleanup.
        for sample in try await ownedSamples(HKCorrelationType(.bloodPressure)) {
            try Task.checkCancellation()
            if let correlation=sample as? HKCorrelation,correlation.objects.isEmpty {try await store.delete(correlation)}
        }
        return removed
    }
    // Only this app's samples; never removes Withings/Apple/other-app records.
    func removeAll()async throws->Int {
        var removed=0
        for type in Self.types() {
            try Task.checkCancellation()
            let predicate=HKQuery.predicateForObjects(from:HKSource.default())
            let count:Int=try await withCheckedThrowingContinuation {continuation in
                store.deleteObjects(of:type,predicate:predicate) {_,count,error in
                    if let error{continuation.resume(throwing:error)}else{continuation.resume(returning:count)}
                }
            }
            removed+=count
        }
        // Correlations are also owned by this app.
        let type=HKCorrelationType(.bloodPressure)
        let count:Int=try await withCheckedThrowingContinuation {continuation in
            store.deleteObjects(of:type,predicate:HKQuery.predicateForObjects(from:HKSource.default())) {_,count,error in
                if let error{continuation.resume(throwing:error)}else{continuation.resume(returning:count)}
            }
        };return removed+count
    }
}
struct SyncFailure:LocalizedError {let message:String;init(_ message:String){self.message=message};var errorDescription:String?{message}}
