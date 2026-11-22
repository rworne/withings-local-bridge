import Foundation

// Source ownership is supplied by HKSource, never by editable metadata.
struct BridgeDuplicateCandidate {
    let id:String
    let type:String
    let start:Double
    let end:Double
    let stage:Int?
    let owned:Bool
}
enum BridgeDuplicatePolicy {
    static func key(type:String,start:Double,end:Double,stage:Int?=nil)->String {
        "\(type)|\(Int64(floor(start)))|\(Int64(floor(end)))|\(stage.map(String.init) ?? "")"
    }
    static func removals(_ samples:[BridgeDuplicateCandidate])->Set<String> {
        let groups=Dictionary(grouping:samples){key(type:$0.type,start:$0.start,end:$0.end,stage:$0.stage)}
        var result=Set<String>()
        for samples in groups.values {
            let owned=samples.filter(\.owned).sorted{$0.id<$1.id}
            // Preserve every foreign entry. If none exists, retain one own entry.
            let discard=samples.contains{!$0.owned} ? owned:Array(owned.dropFirst())
            result.formUnion(discard.map(\.id))
        }
        return result
    }
}
