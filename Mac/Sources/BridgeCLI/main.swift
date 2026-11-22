import Foundation
import BridgeCore

// A local diagnostic/automation entry point. No server connections or credentials.
func argument(_ name:String)->String? { guard let i=CommandLine.arguments.firstIndex(of:name),CommandLine.arguments.indices.contains(i+1) else{return nil};return CommandLine.arguments[i+1] }
do {
    guard let source=argument("--source") else {
        print("Usage: withings-bridge --source DATABASE_FOLDER --output OUTPUT_FOLDER --state PRIVATE_STATE_FOLDER --profile PROFILE_ID [--full]\n       withings-bridge --source DATABASE_FOLDER --list-profiles")
        exit(2)
    }
    let folder=URL(fileURLWithPath:source,isDirectory:true)
    if CommandLine.arguments.contains("--list-profiles") { for id in try Extractor.profiles(in:folder){print(id)};exit(0) }
    guard let output=argument("--output"),let state=argument("--state"),let profile=argument("--profile") else {throw BridgeError.message("Output, private state folder and profile are required.")}
    let configuration=BridgeConfiguration(source:folder,output:URL(fileURLWithPath:output,isDirectory:true),state:URL(fileURLWithPath:state,isDirectory:true),profile:profile)
    let result=try HealthPublisher.publish(configuration,fullSnapshot:CommandLine.arguments.contains("--full")){ print($0) }
    print(result.message); print("Records: \(result.total)")
    if let url=result.package{print("Batch: \(url.path)")}
} catch {fputs("\(error as NSError)\n",stderr);exit(1)}
