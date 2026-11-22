import Foundation

public enum BridgeLocations {
    public static func standardDatabaseFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Containers/com.withings.wiScaleNG/Data/Library/Application Support/coredata", isDirectory: true)
    }
    public static func sourceFolder(override: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    directoryExists: (URL) -> Bool = { url in
                                        var directory: ObjCBool = false
                                        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
                                    }) -> URL? {
        // A remembered override is never silently replaced with another source,
        // even when it is temporarily unavailable.
        if let override { return override }
        let standard = standardDatabaseFolder(home: home)
        return directoryExists(standard) ? standard : nil
    }
    public static func withingsApplication(registered: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                           applicationExists: (URL) -> Bool = { url in
                                               var directory: ObjCBool = false
                                               return FileManager.default.fileExists(atPath:url.path,isDirectory:&directory) && directory.boolValue
                                           }) -> URL? {
        let candidates = [registered, URL(fileURLWithPath:"/Applications/WiScale.app",isDirectory:true), home.appendingPathComponent("Applications/WiScale.app",isDirectory:true)].compactMap{$0}
        return candidates.first(where: applicationExists)
    }
}

public struct SavedProfileChoice: Codable, Equatable, Sendable {
    public let sourcePath: String
    public let profileID: String
    public let automatic: Bool
}
public enum ProfilePreferences {
    public static let key = "explicitProfileChoice.v1"
    public static func save(source: URL, profileID: String, choices: [ProfileChoice], automatic: Bool, defaults: UserDefaults = .standard) {
        guard choices.contains(where:{$0.id == profileID}) else {defaults.removeObject(forKey:key);return}
        let selection = SavedProfileChoice(sourcePath:source.standardizedFileURL.resolvingSymlinksInPath().path,profileID:profileID,automatic:automatic)
        if let data=try? JSONEncoder().encode(selection){defaults.set(data,forKey:key)}
    }
    public static func restore(source: URL, choices: [ProfileChoice], defaults: UserDefaults = .standard) -> SavedProfileChoice? {
        guard let data=defaults.data(forKey:key),let saved=try? JSONDecoder().decode(SavedProfileChoice.self,from:data),
              saved.sourcePath == source.standardizedFileURL.resolvingSymlinksInPath().path,
              choices.contains(where:{$0.id == saved.profileID}) else{return nil}
        return saved
    }
    public static func clear(defaults:UserDefaults = .standard){defaults.removeObject(forKey:key)}
}
