import XCTest
import SQLite3
@testable import BridgeCore

final class WritableDB {
    var handle:OpaquePointer?
    init(_ url:URL)throws {guard sqlite3_open(url.path,&handle)==SQLITE_OK else{throw BridgeError.message("fixture open")}}
    deinit{sqlite3_close(handle)}
    func exec(_ sql:String)throws {guard sqlite3_exec(handle,sql,nil,nil,nil)==SQLITE_OK else{throw BridgeError.message(String(cString:sqlite3_errmsg(handle)))}}
}
final class PublisherTests:XCTestCase {
    var root:URL!, source:URL!,output:URL!,state:URL!,health:WritableDB!,measure:WritableDB!
    var config:BridgeConfiguration {BridgeConfiguration(source:source,output:output,state:state,profile:"17")}
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        source=root.appendingPathComponent("source");output=root.appendingPathComponent("output");state=root.appendingPathComponent("state")
        for folder in [source!,output!]{try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
        health=try WritableDB(source.appendingPathComponent("17_WTHealth.sqlite"))
        try health.exec("""
          PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
          CREATE TABLE Z_METADATA(Z_UUID TEXT); INSERT INTO Z_METADATA VALUES('health-fixture');
          CREATE TABLE ZWTOBJECT(Z_PK INTEGER PRIMARY KEY,ZTYPEIDENTIFIER TEXT,ZSTARTDATE REAL,ZENDDATE REAL,ZISREMOVED INTEGER,ZQUANTITY INTEGER,ZSOURCE INTEGER,ZSEARCHABLEMETADATA INTEGER,ZLOCALIDENTIFIER TEXT,ZREMOTEIDENTIFIER INTEGER,ZSAMPLE INTEGER,ZMETADATA BLOB);
          CREATE TABLE ZWTQUANTITY(Z_PK INTEGER PRIMARY KEY,ZVALUE REAL);
          CREATE TABLE ZWTSOURCE(Z_PK INTEGER PRIMARY KEY,ZBRAND INTEGER,ZDEVICEMODEL INTEGER,ZDEVICEIDENTIFIER INTEGER,ZDEVICETYPE INTEGER,ZBUNDLEIDENTIFIER TEXT);
          CREATE TABLE ZWTSEARCHABLEMETADATA(Z_PK INTEGER PRIMARY KEY,ZPOSITION INTEGER,ZTIMEZONE TEXT,ZATTRIB INTEGER,ZMODIFIEDDATE REAL);
          INSERT INTO ZWTSOURCE VALUES(1,1,19,123,1,NULL);
          INSERT INTO ZWTSEARCHABLEMETADATA VALUES(1,0,'America/Los_Angeles',0,800000000);
          INSERT INTO ZWTQUANTITY VALUES(1,123.456789123456);
          INSERT INTO ZWTOBJECT VALUES(1,'WTQuantityType.weight',800000000.125,800000000.125,0,1,1,1,'stable-local-id',42,NULL,X'534543524554');
          CREATE TABLE ZACCOUNT(ZTOKEN TEXT); INSERT INTO ZACCOUNT VALUES('SECRET_ACCOUNT_TOKEN');
          """)
        measure=try WritableDB(source.appendingPathComponent("17_Measure.sqlite"))
        try measure.exec("""
          CREATE TABLE Z_METADATA(Z_UUID TEXT); INSERT INTO Z_METADATA VALUES('measure-fixture');
          CREATE TABLE ZWTMEASUREGROUP(Z_PK INTEGER PRIMARY KEY,ZDATE REAL,ZREMOVED INTEGER,ZIDENTIFIER TEXT,ZREMOTEIDENTIFIER INTEGER,ZMODIFIEDDATE REAL,ZBRAND INTEGER,ZDEVICEMODEL INTEGER,ZNOTE TEXT);
          CREATE TABLE ZWTSPECIALIZEDGROUP(Z_PK INTEGER PRIMARY KEY,ZGROUP INTEGER,Z2_GROUP INTEGER,ZWEIGHT INTEGER,ZMEASURETYPE INTEGER);
          CREATE TABLE ZWTMEASURE(Z_PK INTEGER PRIMARY KEY,ZMANTISSA INTEGER,ZEXPONENT INTEGER,ZALGOVERSION INTEGER);
          INSERT INTO ZWTMEASUREGROUP VALUES(1,800000000.125,0,'stable-group-id',51,800000000,1,19,'SECRET_NOTE');
          INSERT INTO ZWTSPECIALIZEDGROUP VALUES(1,1,NULL,1,2);
          INSERT INTO ZWTMEASURE VALUES(1,123456,-3,5);
          INSERT INTO ZWTMEASURE VALUES(2,999999,0,5);
          """)
    }
    override func tearDownWithError()throws {health=nil;measure=nil;try? FileManager.default.removeItem(at:root)}
    func snapshot(_ result:PublishResult)throws->HealthSnapshot {
        let result=try JSONDecoder().decode(HealthSnapshot.self,from:Data(contentsOf:XCTUnwrap(result.package)))
        try result.validate();return result
    }
    func testReadOnlyWALCorrectionsAndRemovals()throws {
        let original=try Data(contentsOf:source.appendingPathComponent("17_WTHealth.sqlite"))
        let first=try snapshot(HealthPublisher.publish(config))
        XCTAssertEqual(first.records.count,1)
        XCTAssertEqual(first.records[0].value,123.456789123456,accuracy:0.000000000001)
        XCTAssertFalse(String(decoding:try HealthSnapshot.encoded(first),as:UTF8.self).contains("SECRET"))
        XCTAssertEqual(try Data(contentsOf:source.appendingPathComponent("17_WTHealth.sqlite")),original)
        XCTAssertNil(try HealthPublisher.publish(config).package)
        try health.exec("UPDATE ZWTQUANTITY SET ZVALUE=124 WHERE Z_PK=1")
        let updated=try snapshot(HealthPublisher.publish(config))
        XCTAssertEqual(updated.records[0].id,first.records[0].id)
        XCTAssertEqual(updated.records[0].value,124)
        XCTAssertGreaterThan(updated.revision,first.revision)
        try health.exec("UPDATE ZWTOBJECT SET ZISREMOVED=1;DELETE FROM ZWTQUANTITY")
        XCTAssertEqual(try snapshot(HealthPublisher.publish(config)).records[0].value,123.456)
        try measure.exec("DELETE FROM ZWTMEASUREGROUP")
        XCTAssertTrue(try snapshot(HealthPublisher.publish(config)).records.isEmpty)
        let db=try Database(url:source.appendingPathComponent("17_WTHealth.sqlite"),name:"fixture")
        XCTAssertThrowsError(try db.execute("DELETE FROM ZWTOBJECT"))
    }
    func testSharedRemoteTrackIDsRetainDistinctStableLocalRows()throws {
        let tracks=try WritableDB(source.appendingPathComponent("17_Tracks.sqlite"))
        try tracks.exec("""
          CREATE TABLE Z_METADATA(Z_UUID TEXT);INSERT INTO Z_METADATA VALUES('tracks-fixture');
          CREATE TABLE ZTRACK(Z_PK INTEGER PRIMARY KEY,ZSTARTDATE REAL,ZENDDATE REAL,ZISREMOVED INTEGER,ZTRACKID INTEGER,ZAPPTRACKID TEXT,ZSTEPS INTEGER);
          INSERT INTO ZTRACK VALUES(1,800000000,800000600,0,55,'local-a',100);
          INSERT INTO ZTRACK VALUES(2,800000001,800000600,0,55,'local-b',110);
          """)
        let first=try Extractor.extract(folder:source,profile:"17").records.filter{$0.source.entity == "ZTRACK"}
        XCTAssertEqual(first.count,2);XCTAssertEqual(Set(first.map(\.id)).count,2)
        XCTAssertEqual(Set(first.compactMap{$0.metadata["ZTRACKID"]}),["55"])
        XCTAssertEqual(Set(first.compactMap{$0.metadata["ZAPPTRACKID"]}),["local-a","local-b"])
        let healthBefore=try snapshot(HealthPublisher.publish(config))
        try tracks.exec("UPDATE ZTRACK SET ZSTEPS=120,ZSTARTDATE=800000002 WHERE Z_PK=2")
        let corrected=try Extractor.extract(folder:source,profile:"17").records.filter{$0.source.entity == "ZTRACK"}
        XCTAssertEqual(Set(first.map(\.id)),Set(corrected.map(\.id)))
        XCTAssertEqual(try HealthPublisher.publish(config).total,healthBefore.records.count)
        try tracks.exec("DELETE FROM ZTRACK WHERE Z_PK=1")
        let remaining=try Extractor.extract(folder:source,profile:"17").records.filter{$0.source.entity == "ZTRACK"}
        XCTAssertEqual(remaining.count,1)
        XCTAssertEqual(remaining.first?.id,first.first{$0.metadata["nativeLocalPrimaryKey"] == "2"}?.id)
    }
    func testSchemaChangeCannotPublishPartialSnapshot()throws {
        let first=try HealthPublisher.publish(config)
        let before=try Data(contentsOf:XCTUnwrap(first.package))
        try measure.exec("ALTER TABLE ZWTMEASUREGROUP ADD COLUMN ZNEWFIELD TEXT")
        XCTAssertThrowsError(try HealthPublisher.publish(config))
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(first.package)),before)
    }
    func testPublishesProfileNameAndUpdatesItWithoutMeasurementChanges()throws {
        let names=try WritableDB(source.appendingPathComponent("associated_device.sqlite"))
        try names.exec("CREATE TABLE Z_METADATA(Z_UUID TEXT);INSERT INTO Z_METADATA VALUES('names');CREATE TABLE ZDEVICEUSER(Z_PK INTEGER PRIMARY KEY,ZUSERID INTEGER,ZFIRSTNAME TEXT,ZFAMILYNAME TEXT);INSERT INTO ZDEVICEUSER VALUES(1,17,'Test','Person')")
        _=try HealthPublisher.publish(config)
        let file=output.appendingPathComponent("profile-17.wprofile")
        let first=try JSONDecoder().decode(BridgeProfileInfo.self,from:Data(contentsOf:file))
        XCTAssertEqual(first.name,"Test Person")
        try names.exec("UPDATE ZDEVICEUSER SET ZFIRSTNAME='Updated'")
        let result=try HealthPublisher.publish(config)
        XCTAssertEqual(try snapshot(result).profileName,"Updated Person")
        XCTAssertEqual(try BridgeProfileInfo.read(from:file,expectedID:"17").name,"Updated Person")
        XCTAssertThrowsError(try BridgeProfileInfo.read(from:file,expectedID:"99"))
        XCTAssertEqual(try JSONDecoder().decode(BridgeProfileInfo.self,from:Data(contentsOf:file)).name,"Updated Person")
    }

    func testSuccessfulPublishReportsHistoryAndHistoryFailureIsNonfatal()throws {
        let first=try HealthPublisher.publish(config)
        XCTAssertEqual(first.recentMeasurements.count,1)
        XCTAssertEqual(first.recentMeasurements.first?.metricName,"Weight")
        let date=first.recentMeasurements.first?.publishedAt
        let unchanged=try HealthPublisher.publish(config)
        XCTAssertNil(unchanged.package);XCTAssertEqual(unchanged.recentMeasurements.first?.publishedAt,date)
        let log=state.appendingPathComponent("RecentPublished.json")
        try FileManager.default.removeItem(at:log)
        try FileManager.default.createDirectory(at:log,withIntermediateDirectories:true)
        try health.exec("UPDATE ZWTQUANTITY SET ZVALUE=125 WHERE Z_PK=1")
        let next=try HealthPublisher.publish(config)
        XCTAssertNotNil(next.package)
        XCTAssertTrue(next.message.contains("history could not be saved"))
        XCTAssertEqual(next.recentMeasurements.count,1)
    }

}
