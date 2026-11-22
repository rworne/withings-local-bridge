import Foundation

enum ImportHistoryStore {
    static var file:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("HealthBridge",isDirectory:true).appendingPathComponent("RecentImports.json")
    }
    static func read()throws->[BridgeImportEvent] {
        guard FileManager.default.fileExists(atPath:file.path) else{return []}
        return BridgeImportHistory.adding([],to:try JSONDecoder().decode([BridgeImportEvent].self,from:Data(contentsOf:file)))
    }
    static func save(_ events:[BridgeImportEvent])throws {
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(events).write(to:file,options:[.atomic,.completeFileProtection])
    }
    static func clear()throws {
        if FileManager.default.fileExists(atPath:file.path) {try FileManager.default.removeItem(at:file)}
    }
}
