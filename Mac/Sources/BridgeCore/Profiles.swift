import Foundation

public struct ProfileChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public var label: String { name.map { "\($0) (\(id))" } ?? "Profile \(id)" }
}
public enum ProfileCatalog {
    public static func choices(in folder: URL) throws -> [ProfileChoice] {
        let ids = try Extractor.profiles(in: folder)
        var names: [String:String] = [:]
        let file = folder.appendingPathComponent("associated_device.sqlite")
        if FileManager.default.fileExists(atPath: file.path), let db = try? Database(url: file, name: "Profile names") {
            // Only display names are read for the picker and profile sidecar.
            // Emails, birthdays and account credentials are never queried.
            do {
                try db.beginSnapshot()
                try db.require("ZDEVICEUSER", ["Z_PK","ZUSERID","ZFIRSTNAME","ZFAMILYNAME"])
                let columns = try db.columns("ZDEVICEUSER")
                let filter = columns.contains("ZISREMOVED") ? "WHERE COALESCE(ZISREMOVED,0)=0" : ""
                let order = columns.contains("ZMODIFIED") ? "ZMODIFIED DESC, Z_PK DESC" : "Z_PK DESC"
                try db.rows("SELECT ZUSERID,ZFIRSTNAME,ZFAMILYNAME FROM ZDEVICEUSER \(filter) ORDER BY \(order)") { row in
                    guard let id = row.integer("ZUSERID").map(String.init), ids.contains(id), names[id] == nil else { return }
                    let parts = [row.text("ZFIRSTNAME"),row.text("ZFAMILYNAME")].compactMap { $0 }
                    let name = parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if !name.isEmpty { names[id] = String(name.prefix(160)) }
                }
            } catch { /* Missing/unsupported name metadata never selects a profile. */ }
        }
        return ids.map { ProfileChoice(id: $0, name: names[$0]) }
    }
}

public enum ProfileSelection {
    public static func canSync(source: URL?, output: URL?, selected: String, choices: [ProfileChoice], working: Bool) -> Bool {
        !working && source != nil && output != nil && !selected.isEmpty && choices.contains { $0.id == selected }
    }
}
