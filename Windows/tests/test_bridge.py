from __future__ import annotations
from contextlib import closing
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import struct
import subprocess
import tempfile
import unittest
from Crypto.Cipher import AES
from bridge.backup import (BackupInfo,BackupSession,DOMAIN,PREFIX,discover,profile_choices,
                           prepare_databases,unlock_keybag,file_key,metadata_key)
from bridge.exchange import BridgeError,canonical,digest,read_snapshot,record_id,validate
from bridge.measurements import extract
from bridge.publish import configuration_folder,publish,recent_events
from fixtures import create_source


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.root=Path(self.temporary.name)
        self.source=create_source(self.root/"source")
        self.info=BackupInfo(self.root/"backup",dt.datetime(2023,1,1),False);self.info.folder.mkdir()
        self.output=self.root/"output";self.output.mkdir()
        self.session=type("Session",(),{"source":self.source,"info":self.info})()
    def tearDown(self):self.temporary.cleanup()
    def test_filtering_mapping_precision_and_priority(self):
        records,_=extract(self.source,"17");self.assertEqual(len(records),14)
        self.assertEqual({r['metric'] for r in records},{'bodyMass','bodyFatPercentage','leanBodyMass','bodyMassIndex','bodyTemperature','bloodPressure','oxygenSaturation','heartRate','sleepAnalysis','respiratoryRate','heartRateVariabilitySDNN','stepCount'})
        self.assertEqual(next(r['value'] for r in records if r['metric']=='bodyMass'),100.123456789123)
        self.assertEqual(next(r['value'] for r in records if r['metric']=='heartRateVariabilitySDNN'),.0455)
        self.assertFalse(any(r['deviceModel']==1051 for r in records))
        self.assertEqual(profile_choices(self.source),[('17','Test Person')])
    def test_publish_unchanged_correction_removal_and_name(self):
        result=publish(self.session,"17",self.output,self.root/"private")
        path=self.output/"profile-17.whealth";before=path.read_bytes();mtime=path.stat().st_mtime_ns
        snapshot=read_snapshot(path);self.assertEqual(snapshot['profileName'],'Test Person')
        self.assertEqual(len(result.history),14)
        again=publish(self.session,"17",self.output,self.root/"private")
        self.assertFalse(again.changed);self.assertEqual(path.stat().st_mtime_ns,mtime)
        self.assertEqual(again.history,result.history)
        with closing(sqlite3.connect(self.source/'17_WTHealth.sqlite')) as db:
            db.execute('UPDATE ZWTQUANTITY SET ZVALUE=101.125 WHERE Z_PK=1');db.commit()
        corrected=publish(self.session,"17",self.output,self.root/"private")
        current=read_snapshot(path)
        self.assertTrue(corrected.changed);self.assertGreater(current['revision'],snapshot['revision'])
        self.assertEqual([r['id'] for r in current['records']],[r['id'] for r in snapshot['records']])
        with closing(sqlite3.connect(self.source/'17_Measure.sqlite')) as db:
            db.execute('DELETE FROM ZWTMEASUREGROUP WHERE Z_PK=2');db.commit()
        removed=publish(self.session,"17",self.output,self.root/"private")
        self.assertEqual(removed.count,12)
        self.assertTrue(json.loads((self.output/'profile-17.wprofile').read_text())['name'])
    def test_fail_closed_on_missing_or_changed_source(self):
        publish(self.session,"17",self.output,self.root/"private")
        path=self.output/'profile-17.whealth';before=path.read_bytes()
        (self.source/'17_Tracks.sqlite').unlink()
        with self.assertRaises(BridgeError):publish(self.session,"17",self.output,self.root/"private")
        self.assertEqual(path.read_bytes(),before)
        (self.source/'17_Measure.sqlite').unlink()
        with self.assertRaises(BridgeError):publish(self.session,"17",self.output,self.root/"private")
        self.assertEqual(path.read_bytes(),before)
    def test_corrupt_existing_export_is_not_overwritten(self):
        path=self.output/'profile-17.whealth';path.write_text('{"bad":true}')
        with self.assertRaises(BridgeError):publish(self.session,"17",self.output,self.root/"private")
        self.assertEqual(path.read_text(),'{"bad":true}')
    def test_history_cap_uses_measurement_dates(self):
        records=[{'id':str(i),'metric':'heartRate','start':float(i)} for i in range(100)]
        history=recent_events({'records':records,'publishedAt':1000},None,[])
        self.assertEqual(len(history),50);self.assertEqual(history[0]['id'],'99')
        self.assertNotIn('value',history[0])
    def test_private_wal_checkpoint_keeps_measurements_and_original(self):
        copy=self.root/'copy';copy.mkdir();file=self.root/'live.sqlite'
        with closing(sqlite3.connect(file)) as db:
            db.executescript('PRAGMA journal_mode=WAL;PRAGMA wal_autocheckpoint=0;CREATE TABLE sample(value INTEGER);INSERT INTO sample VALUES(73);')
            main=file.read_bytes();wal=file.with_name('live.sqlite-wal').read_bytes()
            (copy/'17_WTHealth.sqlite').write_bytes(main);(copy/'17_WTHealth.sqlite-wal').write_bytes(wal)
            prepare_databases(copy)
            with closing(sqlite3.connect((copy/'17_WTHealth.sqlite').as_uri()+'?mode=ro',uri=True)) as read:
                self.assertEqual(read.execute('SELECT value FROM sample').fetchone()[0],73)
                self.assertEqual(read.execute('PRAGMA journal_mode').fetchone()[0],'delete')
            self.assertEqual(file.read_bytes(),main);self.assertEqual(file.with_name('live.sqlite-wal').read_bytes(),wal)
    def test_swift_golden_snapshot_checksum_and_identity(self):
        file=Path(__file__).parent/'fixtures'/'swift-exchange.json'
        snapshot=read_snapshot(file)
        for row in snapshot['records']:
            self.assertEqual(record_id(row['profileID'],row['metric'],row['start'],row['end']),row['id'])
        self.assertEqual(digest(canonical(snapshot['records'])),snapshot['recordsSHA256'])
    @unittest.skipUnless(os.environ.get('SWIFT_BRIDGE_BIN'),'Set SWIFT_BRIDGE_BIN for cross-language publisher parity')
    def test_same_database_matches_swift_publisher_byte_for_byte(self):
        records,_=extract(self.source,'17')
        output=self.root/'swift';output.mkdir()
        run=subprocess.run([os.environ['SWIFT_BRIDGE_BIN'],'--source',str(self.source),'--output',str(output),'--state',str(self.root/'swift-state'),'--profile','17'],capture_output=True,text=True)
        self.assertEqual(run.returncode,0,run.stderr)
        snapshot=read_snapshot(output/'profile-17.whealth')
        self.assertEqual(snapshot['records'],records)
        self.assertEqual(snapshot['recordsSHA256'],digest(canonical(records)))


class EncryptedBackupTests(unittest.TestCase):
    def test_encrypted_and_unencrypted_backup_extract_only_withings_and_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);backup=root/'backup';backup.mkdir();payload=create_source(root/'payload')
            password='fixture-password';salt=b's'*20;dpsl=b'd'*20;class_key=b'k'*32;content_key=b'f'*32
            def tlv(tag,value):return tag.encode()+struct.pack('>I',len(value))+value
            derive=__import__('hashlib').pbkdf2_hmac
            key=derive('sha1',derive('sha256',password.encode(),dpsl,2,32),salt,2,32)
            wrap=lambda k,v:AES.new(k,AES.MODE_KW).seal(v)
            bag=b''.join(tlv(tag,value) for tag,value in [('UUID',bytes(16)),('DPSL',dpsl),('DPIC',struct.pack('>I',2)),('SALT',salt),('ITER',struct.pack('>I',2)),('UUID',b'1'*16),('CLAS',struct.pack('>I',4)),('WRAP',struct.pack('>I',2)),('WPKY',wrap(key,class_key))])
            wrapped=struct.pack('<I',4)+wrap(class_key,content_key)
            metadata=plistlib.dumps({'$objects':['$null',{'EncryptionKey':plistlib.UID(2)},{'NS.data':wrapped}],'$top':{'root':plistlib.UID(1)}},fmt=plistlib.FMT_BINARY)
            self.assertEqual(metadata_key(metadata),wrapped)
            def encrypt(data):
                padding=16-len(data)%16
                return AES.new(content_key,AES.MODE_CBC,iv=bytes(16)).encrypt(data+bytes([padding])*padding)
            index=root/'index.db'
            files=[]
            with closing(sqlite3.connect(index)) as db:
                db.executescript('PRAGMA journal_mode=WAL;CREATE TABLE Files(fileID TEXT,domain TEXT,relativePath TEXT,flags INTEGER,file BLOB);')
                for i,file in enumerate(payload.iterdir()):
                    identity=__import__('hashlib').sha1(str(i).encode()).hexdigest();files.append((identity,file))
                    db.execute('INSERT INTO Files VALUES(?,?,?,?,?)',(identity,DOMAIN,PREFIX+file.name,1,metadata))
                foreign='e'*40
                db.execute('INSERT INTO Files VALUES(?,?,?,?,?)',(foreign,'AppDomain-unrelated',PREFIX+'17_Measure.sqlite',1,metadata))
                db.commit()
            status={'SnapshotState':'finished','Date':dt.datetime(2023,1,1)}
            (backup/'Status.plist').write_bytes(plistlib.dumps(status))
            for encrypted in (True,False):
                (backup/'Manifest.plist').write_bytes(plistlib.dumps({'IsEncrypted':encrypted,'BackupKeyBag':bag,'ManifestKey':wrapped}))
                (backup/'Manifest.db').write_bytes(encrypt(index.read_bytes()) if encrypted else index.read_bytes())
                original=(backup/'Manifest.db').read_bytes()
                for identity,file in files:
                    folder=backup/identity[:2];folder.mkdir(exist_ok=True)
                    (folder/identity).write_bytes(encrypt(file.read_bytes()) if encrypted else file.read_bytes())
                info=discover(backup)[0]
                if encrypted:
                    with self.assertRaises(BridgeError):BackupSession.open(info,'incorrect',root/'sessions')
                session=BackupSession.open(info,password if encrypted else '',root/'sessions')
                source=session.source
                self.assertEqual(profile_choices(source),[('17','Test Person')])
                records,_=extract(source,'17');self.assertEqual(len(records),14)
                self.assertFalse((source/'unrelated.sqlite').exists())
                session.close();self.assertFalse(source.exists())
                self.assertEqual((backup/'Manifest.db').read_bytes(),original)
            status['SnapshotState']='inprogress';(backup/'Status.plist').write_bytes(plistlib.dumps(status))
            with self.assertRaises(BridgeError):discover(backup)
    def test_iteration_count_rejected_before_work(self):
        def tlv(tag,value):return tag.encode()+struct.pack('>I',len(value))+value
        bag=b''.join(tlv(tag,value) for tag,value in [('DPIC',struct.pack('>I',30_000_000)),('DPSL',b'd'*20),('SALT',b's'*20),('ITER',struct.pack('>I',1))])
        with self.assertRaisesRegex(BridgeError,'iteration'):unlock_keybag(bag,'not-a-real-password')


if __name__=='__main__':unittest.main()
