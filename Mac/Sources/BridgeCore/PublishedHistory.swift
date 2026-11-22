import Foundation

public struct PublishedMeasurement:Codable,Identifiable,Equatable,Sendable {
    public let id:String
    public let metricName:String
    public let measuredAt:Date
    public let publishedAt:Date
}
public enum PublishedHistory {
    private static func file(_ state:URL)->URL {state.appendingPathComponent("RecentPublished.json")}
    public static func load(state:URL)throws->[PublishedMeasurement] {
        let url=file(state)
        guard FileManager.default.fileExists(atPath:url.path) else{return []}
        return capped(try JSONDecoder().decode([PublishedMeasurement].self,from:Data(contentsOf:url)))
    }
    private static func capped(_ items:[PublishedMeasurement])->[PublishedMeasurement] {
        let unique=Dictionary(items.map{($0.id,$0)},uniquingKeysWith:{a,b in a.publishedAt>b.publishedAt ? a:b})
        return Array(unique.values.sorted {
            if $0.measuredAt != $1.measuredAt{return $0.measuredAt>$1.measuredAt}
            if $0.publishedAt != $1.publishedAt{return $0.publishedAt>$1.publishedAt}
            return $0.id<$1.id
        }.prefix(50))
    }
    private static func events(_ records:[HealthRecord],at time:Double)->[PublishedMeasurement] {
        records.map{PublishedMeasurement(id:$0.id,metricName:$0.metric.displayName,
            measuredAt:Date(timeIntervalSince1970:$0.start),publishedAt:Date(timeIntervalSince1970:time))}
    }
    static func current(snapshot:HealthSnapshot)->[PublishedMeasurement] {capped(events(snapshot.records,at:snapshot.publishedAt))}
    // Called only after a successful snapshot write, or for a validated snapshot
    // that was already published. No raw values, names or database rows are stored.
    static func record(snapshot:HealthSnapshot,previous:HealthSnapshot?,state:URL)throws->[PublishedMeasurement] {
        let fm=FileManager.default,url=file(state)
        let exists=fm.fileExists(atPath:url.path)
        let loaded=exists ? try? load(state:state):nil
        let old=loaded ?? capped(events(previous?.records ?? [],at:previous?.publishedAt ?? snapshot.publishedAt))
        let prior=Dictionary((previous?.records ?? []).map{($0.id,$0)},uniquingKeysWith:{a,_ in a})
        let changed=snapshot.records.filter{prior[$0.id] != $0}
        let history=capped(old+events(changed,at:snapshot.publishedAt))
        if loaded == nil || history != old {
            try fm.createDirectory(at:state,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try canonical(history).write(to:url,options:.atomic)
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
        return history
    }
}
