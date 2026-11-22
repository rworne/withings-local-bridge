import Foundation
import CryptoKit

public enum BridgeError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return text } }
}
public func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func stableID(_ parts: [String]) -> String {
    digest(try! JSONEncoder().encode(parts))
}
func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
public struct MeasurementValue: Codable, Equatable {
    public let metric: String
    public let value: String // Exact decimal/scientific notation, never presentation-rounded.
    public let unit: String?
    public let nativeField: String
    public let interpretation: String // mapped, native_code, unverified
    public let metadata: [String:String]
}
public struct Provenance: Codable, Equatable {
    public let database: String
    public let databaseIdentity: String
    public let entity: String
    public let sourceRecordID: String
    public let brand: Int64?
    public let deviceModel: Int64?
    public let deviceID: Int64?
    public let deviceType: Int64?
    public let bundleIdentifier: String?
    public let firmware: Int64?
    public let origin: String // brand 1 is Withings; never infer origin from absence.
}
public struct MeasurementRecord: Codable, Equatable {
    public let id: String
    public let profileID: String
    public let kind: String
    public let start: Double // UTC Unix seconds, including source fractional precision.
    public let end: Double
    public let modified: Double?
    public let timezone: String?
    public let sessionID: String?
    public let values: [MeasurementValue]
    public let metadata: [String: String]
    public let source: Provenance
}
public struct Change: Codable {
    public let operation: String
    public let id: String
    public let record: MeasurementRecord?
}
public struct SourceDescription: Codable, Equatable {
    public let database: String
    public let identity: String
    public let schemaFingerprint: String
}
public struct BatchManifest: Codable {
    public let format: String
    public let version: Int
    public let streamID: String
    public let profileID: String
    public let batchID: String
    public let previousBatchID: String?
    public let sequence: Int
    public let mode: String
    public let createdAt: String
    public let extractionStartedAt: String
    public let extractionEndedAt: String
    public let payloadFile: String
    public let payloadSHA256: String
    public let payloadBytes: Int
    public let upserts: Int
    public let deletions: Int
    public let totalRecords: Int
    public let sources: [SourceDescription]
    public let coverage: [String: Int]
    public let limitations: [String]
}
public struct Extraction {
    public let records: [MeasurementRecord]
    public let sources: [SourceDescription]
    public let coverage: [String: Int]
}
public struct PublishResult: Sendable {
    public let package: URL?
    public let upserts: Int
    public let deletions: Int
    public let total: Int
    public let message: String
}
public struct BridgeConfiguration: Sendable {
    public let source: URL
    public let output: URL
    public let state: URL
    public let profile: String
    public init(source: URL, output: URL, state: URL, profile: String) {
        self.source = source; self.output = output; self.state = state; self.profile = profile
    }
}
