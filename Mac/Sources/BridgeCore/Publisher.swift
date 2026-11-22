import Foundation
import Darwin

struct SyncState: Codable {
    var formatVersion = 1
    var streamID: String
    var profileID: String
    var sourcePath: String
    var outputPath: String
    var sequence: Int = 0
    var lastBatchID: String?
    var hashes: [String:String] = [:]
    var sources: [SourceDescription] = []
}
struct PendingPublish: Codable {
    let state: SyncState
    let packageName: String
    let batchID: String
}
public enum Publisher {
    public static func publish(_ configuration: BridgeConfiguration, fullSnapshot: Bool = false,
                               progress: (String) -> Void = { _ in }) throws -> PublishResult {
        let fm=FileManager.default
        let source=configuration.source.standardizedFileURL.resolvingSymlinksInPath()
        let output=configuration.output.standardizedFileURL.resolvingSymlinksInPath()
        let stateFolder=configuration.state.standardizedFileURL.resolvingSymlinksInPath()
        func contains(_ parent:URL,_ child:URL)->Bool { child.path == parent.path || child.path.hasPrefix(parent.path + "/") }
        guard !contains(source,output), !contains(output,source), !contains(source,stateFolder), !contains(output,stateFolder) else {
            throw BridgeError.message("Choose separate database, output and private state folders. Do not place output inside the Withings database folder.")
        }
        guard fm.fileExists(atPath:output.path) else { throw BridgeError.message("The selected output folder is unavailable. No changes were published.") }
        try fm.createDirectory(at:stateFolder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let lockURL=stateFolder.appendingPathComponent("sync.lock")
        let descriptor=Darwin.open(lockURL.path,O_CREAT|O_RDWR,0o600)
        guard descriptor >= 0 else { throw BridgeError.message("Cannot open the private synchronization lock.") }
        defer { _ = flock(descriptor,LOCK_UN); Darwin.close(descriptor) }
        guard flock(descriptor,LOCK_EX|LOCK_NB)==0 else { throw BridgeError.message("Another synchronization is already running.") }
        let stateURL=stateFolder.appendingPathComponent("state.json")
        let pendingURL=stateFolder.appendingPathComponent("pending.json")
        let staging=stateFolder.appendingPathComponent("staging.wbridge",isDirectory:true)
        let decoder=JSONDecoder()
        var state:SyncState
        if fm.fileExists(atPath:stateURL.path) { state=try decoder.decode(SyncState.self,from:Data(contentsOf:stateURL)) }
        else { state=SyncState(streamID:UUID().uuidString,profileID:configuration.profile,sourcePath:source.path,outputPath:output.path) }
        func validateConfiguration(_ state:SyncState)throws {
            guard state.formatVersion==1,state.profileID==configuration.profile,state.sourcePath==source.path,state.outputPath==output.path else {
                throw BridgeError.message("The private state belongs to another source, output folder or profile. Choose a separate state folder.")
            }
        }
        try validateConfiguration(state)
        if fm.fileExists(atPath:pendingURL.path) {
            let pending=try decoder.decode(PendingPublish.self,from:Data(contentsOf:pendingURL))
            try validateConfiguration(pending.state)
            let alreadyCommitted = pending.state.sequence == state.sequence && state.lastBatchID == pending.batchID && state.hashes == pending.state.hashes
            guard pending.packageName == URL(fileURLWithPath:pending.packageName).lastPathComponent,
                  pending.packageName.hasSuffix(".wbridge"), pending.state.sequence == state.sequence+1 || alreadyCommitted,
                  pending.state.streamID == state.streamID || state.sequence == 0 else {
                throw BridgeError.message("Invalid pending publication state. No source or output files were changed.")
            }
            progress("Finishing the previous publication…")
            let destination=output.appendingPathComponent(pending.packageName,isDirectory:true)
            try install(staging:staging,destination:destination,batchID:pending.batchID)
            try writePrivate(try canonical(pending.state),to:stateURL)
            try fm.removeItem(at:pendingURL)
            try? fm.removeItem(at:staging)
            state=pending.state
        }
        if !fm.fileExists(atPath:pendingURL.path), fm.fileExists(atPath:staging.path) {try fm.removeItem(at:staging)}
        let started=Date()
        let extracted=try Extractor.extract(folder:source,profile:configuration.profile,progress:progress)
        let ended=Date()
        for prior in state.sources {
            guard let current=extracted.sources.first(where:{$0.database==prior.database}) else {
                throw BridgeError.message("Previously imported \(prior.database) is missing. No deletions or updates were published.")
            }
            guard current.identity == prior.identity else {
                throw BridgeError.message("The \(prior.database) database was replaced or rebuilt. Review the source and choose a new output folder to establish a fresh stream. No deletions were published.")
            }
            guard current.schemaFingerprint==prior.schemaFingerprint else {
                throw BridgeError.message("The \(prior.database) schema changed. This client needs a compatible schema adapter before syncing again. No deletions were published.")
            }
        }
        progress("Comparing measurement records…")
        var hashes:[String:String]=[:], changes:[Change]=[]
        let snapshot=fullSnapshot || state.sequence==0
        for record in extracted.records {
            let fingerprint=digest(try canonical(record)); hashes[record.id]=fingerprint
            if snapshot || state.hashes[record.id] != fingerprint { changes.append(Change(operation:"upsert",id:record.id,record:record)) }
        }
        let deleted=state.hashes.keys.filter{hashes[$0]==nil}.sorted()
        for id in deleted { changes.append(Change(operation:"delete",id:id,record:nil)) }
        guard snapshot || !changes.isEmpty || state.sources != extracted.sources else {
            return PublishResult(package:nil,upserts:0,deletions:0,total:hashes.count,message:"No measurement changes found.")
        }
        let batchID=UUID().uuidString
        let sequence=state.sequence+1
        let packageName=String(format:"batch-%012d-",sequence)+batchID+".wbridge"
        if fm.fileExists(atPath:staging.path){try fm.removeItem(at:staging)}
        try fm.createDirectory(at:staging,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let payloadURL=staging.appendingPathComponent("records.ndjson")
        try Data().write(to:payloadURL,options:.withoutOverwriting)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:payloadURL.path)
        let writer=try FileHandle(forWritingTo:payloadURL)
        do { for change in changes { try writer.write(contentsOf:try canonical(change));try writer.write(contentsOf:Data([10])) };try writer.synchronize();try writer.close() }
        catch { try? writer.close();throw error }
        let payload=try Data(contentsOf:payloadURL,options:.mappedIfSafe)
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let manifest=BatchManifest(format:"WithingsLocalBridge",version:1,streamID:state.streamID,profileID:configuration.profile,
                                   batchID:batchID,previousBatchID:state.lastBatchID,sequence:sequence,mode:snapshot ? "snapshot":"delta",
                                   createdAt:formatter.string(from:Date()),extractionStartedAt:formatter.string(from:started),extractionEndedAt:formatter.string(from:ended),
                                   payloadFile:"records.ndjson",payloadSHA256:digest(payload),payloadBytes:payload.count,upserts:changes.count-deleted.count,
                                   deletions:deleted.count,totalRecords:hashes.count,sources:extracted.sources,coverage:extracted.coverage,
                                   limitations:["Database snapshots are individually consistent; separate source databases are not one atomic transaction.",
                                                "Record identities are source-specific. The consumer must reconcile logical duplicates across stores using metric, timestamp, session/position and provenance.",
                                                "Unverified units and native enumeration codes are not interpreted or converted.",
                                                "Signal metadata is included; waveform/audio files are not included or downloaded.",
                                                "Health attributes, notes, credentials, arbitrary metadata blobs and linked remote content are not exported."])
        try writePrivate(try canonical(manifest),to:staging.appendingPathComponent("manifest.json"))
        var next=state
        next.sequence=sequence;next.lastBatchID=batchID;next.hashes=hashes;next.sources=extracted.sources
        // Journal the exact pending publication before exposing it to iCloud.
        // A crash after publication resumes the same batch, never forks sequence IDs.
        try writePrivate(try canonical(PendingPublish(state:next,packageName:packageName,batchID:batchID)),to:pendingURL)
        progress("Publishing batch \(sequence)…")
        let destination=output.appendingPathComponent(packageName,isDirectory:true)
        try install(staging:staging,destination:destination,batchID:batchID)
        try writePrivate(try canonical(next),to:stateURL)
        try fm.removeItem(at:pendingURL)
        try? fm.removeItem(at:staging)
        return PublishResult(package:destination,upserts:manifest.upserts,deletions:manifest.deletions,total:manifest.totalRecords,
                             message:"Published \(manifest.upserts) new or changed records and \(manifest.deletions) removals.")
    }
    private static func writePrivate(_ data:Data,to url:URL)throws {
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    static func validatePackage(_ folder:URL,batchID:String)throws {
        let manifest=try JSONDecoder().decode(BatchManifest.self,from:Data(contentsOf:folder.appendingPathComponent("manifest.json")))
        guard manifest.version==1,manifest.format=="WithingsLocalBridge",manifest.batchID==batchID,manifest.payloadFile=="records.ndjson" else {
            throw BridgeError.message("An existing batch has conflicting metadata. Nothing was overwritten.")
        }
        let payload=try Data(contentsOf:folder.appendingPathComponent("records.ndjson"),options:.mappedIfSafe)
        guard payload.count==manifest.payloadBytes,digest(payload)==manifest.payloadSHA256 else {
            throw BridgeError.message("The output batch is incomplete or damaged. Wait for iCloud to finish transferring it before retrying.")
        }
    }
    private static func install(staging:URL,destination:URL,batchID:String)throws {
        func copyPackage(in parent:URL)throws {
            let coordinated=parent.appendingPathComponent(destination.lastPathComponent,isDirectory:true)
            if FileManager.default.fileExists(atPath:coordinated.path) {
                try validatePackage(coordinated,batchID:batchID)
                let stagedManifest=staging.appendingPathComponent("manifest.json")
                if FileManager.default.fileExists(atPath:stagedManifest.path) {
                    guard try Data(contentsOf:stagedManifest)==Data(contentsOf:coordinated.appendingPathComponent("manifest.json")) else {
                        throw BridgeError.message("The existing batch differs from the pending publication. Nothing was overwritten.")
                    }
                }
                return
            }
            let partial=parent.appendingPathComponent("."+coordinated.lastPathComponent+".partial")
            if FileManager.default.fileExists(atPath:partial.path){try FileManager.default.removeItem(at:partial)}
            try FileManager.default.copyItem(at:staging,to:partial)
            try validatePackage(partial,batchID:batchID)
            try FileManager.default.moveItem(at:partial,to:coordinated)
        }
        let parent=destination.deletingLastPathComponent()
        let ubiquitous=(try parent.resourceValues(forKeys:[.isUbiquitousItemKey])).isUbiquitousItem == true
        if !ubiquitous {try copyPackage(in:parent);return}
        let coordinator=NSFileCoordinator(filePresenter:nil)
        var coordinationError:NSError?,publicationError:Error?
        coordinator.coordinate(writingItemAt:parent,options:.forMerging,error:&coordinationError) { coordinated in
            do {try copyPackage(in:coordinated)} catch {publicationError=error}
        }
        if let publicationError {throw publicationError}
        if let coordinationError {throw coordinationError}
    }
}
