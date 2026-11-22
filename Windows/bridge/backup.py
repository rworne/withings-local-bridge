"""Read-only Finder/Apple Devices backup access; only private copies are decrypted."""
from __future__ import annotations
from dataclasses import dataclass
from contextlib import closing
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import sqlite3
import struct
import tempfile
from Crypto.Cipher import AES
from .exchange import BridgeError
from .storage import private_folder

DOMAIN = "AppDomain-com.withings.wiScaleNG"
PREFIX = "Library/Application Support/coredata/"
FAMILIES = ("WTHealth","Measure","Tracks","vasistas")
ALLOWED = re.compile(r"^(associated_device|[0-9]+_(WTHealth|Measure|Tracks|vasistas))\.sqlite(-wal|-shm)?$")


def plist(path):
    if path.stat().st_size > 16*1024*1024: raise BridgeError("The backup metadata is unexpectedly large.")
    with path.open("rb") as stream: return plistlib.load(stream)


@dataclass(frozen=True)
class BackupInfo:
    folder: Path
    date: object
    encrypted: bool


def discover(folder):
    folder=Path(folder).resolve()
    candidates = [folder] if (folder/"Manifest.plist").exists() else sorted(folder.iterdir())
    found=[]; incomplete=False
    for child in candidates:
        if not (child/"Manifest.plist").is_file(): continue
        try:
            manifest=plist(child/"Manifest.plist");status=plist(child/"Status.plist")
            if status.get("SnapshotState") != "finished": incomplete=True;continue
            if not (child/"Manifest.db").is_file(): continue
            found.append(BackupInfo(child,status.get("Date",manifest.get("Date")),bool(manifest.get("IsEncrypted"))))
        except (OSError,ValueError,plistlib.InvalidFileException): continue
    if not found:
        raise BridgeError("Finish the iPhone backup before opening it." if incomplete else "No completed modern iPhone backup was found in that folder.")
    return sorted(found,key=lambda x:x.date.isoformat() if hasattr(x.date,"isoformat") else "",reverse=True)


def unlock_keybag(bag, password):
    if not isinstance(bag,bytes) or len(bag)>1024*1024: raise BridgeError("Unsupported backup encryption metadata.")
    attrs={};classes=[];current=None;seen_uuid=False;offset=0
    while offset<len(bag):
        if offset+8>len(bag): raise BridgeError("Truncated backup encryption metadata.")
        tag=bag[offset:offset+4].decode("ascii");size=struct.unpack(">I",bag[offset+4:offset+8])[0];offset+=8
        if size>len(bag)-offset: raise BridgeError("Truncated backup encryption metadata.")
        value=bag[offset:offset+size];offset+=size
        if tag=="UUID":
            if seen_uuid:
                if current is not None: classes.append(current)
                current={"UUID":value}
            seen_uuid=True
        elif current is not None: current[tag]=value
        else: attrs[tag]=value
    if current is not None: classes.append(current)
    def number(data):
        if len(data)!=4: raise BridgeError("Unsupported backup encryption parameters.")
        return struct.unpack(">I",data)[0]
    def rounds(data):
        n=number(data)
        if not 1<=n<=20_000_000: raise BridgeError("Unsupported backup password iteration count.")
        return n
    def salt(data):
        if not 0<len(data)<=1024: raise BridgeError("Unsupported backup password salt.")
        return data
    try:
        derived=password.encode("utf-8")
        if "DPIC" in attrs:
            derived=hashlib.pbkdf2_hmac("sha256",derived,salt(attrs["DPSL"]),rounds(attrs["DPIC"]),32)
        derived=hashlib.pbkdf2_hmac("sha1",derived,salt(attrs["SALT"]),rounds(attrs["ITER"]),32)
        keys={}
        for item in classes:
            if "WPKY" in item and number(item["WRAP"])&2:
                keys[number(item["CLAS"])]=AES.new(derived,AES.MODE_KW).unseal(item["WPKY"])
        if not keys: raise ValueError()
        return keys
    except KeyError: raise BridgeError("Unsupported backup encryption metadata.") from None
    except ValueError: raise BridgeError("The backup password was not accepted, or the backup key is damaged.") from None


def file_key(wrapped,keys):
    try:
        if not isinstance(wrapped,bytes) or len(wrapped)<28: raise ValueError()
        key=keys[struct.unpack("<I",wrapped[:4])[0]]
        return AES.new(key,AES.MODE_KW).unseal(wrapped[4:])
    except (KeyError,ValueError): raise BridgeError("An encrypted backup file could not be unlocked.") from None


def metadata_key(data):
    if not isinstance(data,bytes) or len(data)>102_400: raise BridgeError("Unsupported file encryption metadata.")
    try:
        document=plistlib.loads(data);objects=document["$objects"]
        item=objects[document["$top"]["root"].data]
        key=objects[item["EncryptionKey"].data]
        return key if isinstance(key,bytes) else key["NS.data"]
    except (KeyError,IndexError,AttributeError,ValueError,plistlib.InvalidFileException):
        raise BridgeError("Unsupported file encryption metadata.") from None


def decrypt_file(source,destination,key):
    size=source.stat().st_size
    if size==0 or size%16: raise BridgeError("An encrypted backup file is truncated.")
    cipher=AES.new(key,AES.MODE_CBC,iv=bytes(16))
    with source.open("rb") as incoming,destination.open("xb") as outgoing:
        os.chmod(destination,0o600)
        pending=b""
        while chunk:=incoming.read(1024*1024):
            clear=cipher.decrypt(chunk)
            if pending: outgoing.write(pending)
            pending=clear
        padding=pending[-1]
        if not 1<=padding<=16 or pending[-padding:]!=bytes([padding])*padding:
            raise BridgeError("A backup file is damaged or could not be decrypted.")
        outgoing.write(pending[:-padding])


def prepare_databases(folder):
    for file in sorted(folder.glob("*.sqlite")):
        # All files here are private copies. Rebuild SHM, honor WAL, checkpoint it.
        try:
            with closing(sqlite3.connect(file)) as db:
                result=db.execute("PRAGMA journal_mode=DELETE").fetchone()
                if not result or result[0]!="delete": raise sqlite3.DatabaseError("Journal preparation failed")
            for suffix in ("-wal","-shm"):
                file.with_name(file.name+suffix).unlink(missing_ok=True)
        except sqlite3.Error:
            raise BridgeError(f"Cannot prepare {file.name}. The backup database may be incomplete or damaged. No data was published.") from None


class BackupSession:
    def __init__(self,info,temporary):
        self.info=info;self._temporary=temporary;self.source=Path(temporary.name)/"coredata"
    def close(self): self._temporary.cleanup()
    def __enter__(self): return self
    def __exit__(self,*_): self.close()

    @classmethod
    def open(cls,info,password,sessions_folder,progress=lambda *_:None):
        private_folder(sessions_folder)
        temporary=tempfile.TemporaryDirectory(prefix="backup-",dir=sessions_folder)
        result=cls(info,temporary);private_folder(result.source)
        index=Path(temporary.name)/"Manifest.db"
        try:
            manifest=plist(info.folder/"Manifest.plist");keys={}
            if info.encrypted:
                if not password: raise BridgeError("Enter the local backup encryption password.")
                progress("Unlocking the encrypted backup. This may take a little while…",None)
                keys=unlock_keybag(manifest.get("BackupKeyBag"),password)
                decrypt_file(info.folder/"Manifest.db",index,file_key(manifest.get("ManifestKey"),keys))
            else:
                shutil.copyfile(info.folder/"Manifest.db",index)
                wal=info.folder/"Manifest.db-wal"
                if wal.is_file(): shutil.copyfile(wal,index.with_name("Manifest.db-wal"))
            os.chmod(index,0o600)
            with index.open("rb") as stream:
                if stream.read(16)!=b"SQLite format 3\0": raise BridgeError("The unlocked backup index is not a SQLite database.")
            progress("Finding Withings databases…",20)
            with closing(sqlite3.connect(index)) as db:
                rows=db.execute("SELECT fileID,relativePath,file FROM Files WHERE domain=? AND flags=1 AND relativePath LIKE ?",(DOMAIN,PREFIX+"%")).fetchall()
            rows=[r for r in rows if ALLOWED.fullmatch(r[1][len(PREFIX):]) and not r[1].endswith("-shm")]
            names=set()
            for i,(identifier,path,metadata) in enumerate(rows):
                name=path[len(PREFIX):]
                if not re.fullmatch("[0-9a-fA-F]{40}",identifier) or name in names:
                    raise BridgeError("Invalid or ambiguous file in the backup index.")
                names.add(name)
                physical=info.folder/identifier[:2]/identifier
                if not physical.exists(): physical=info.folder/identifier
                if not physical.resolve().is_relative_to(info.folder.resolve()) or not physical.is_file():
                    raise BridgeError("A Withings database file is missing from the backup.")
                destination=result.source/name
                progress(f"Extracting database file {i+1} of {len(rows)}…",20+30*(i+1)/max(1,len(rows)))
                if info.encrypted: decrypt_file(physical,destination,file_key(metadata_key(metadata),keys))
                else: shutil.copyfile(physical,destination)
                os.chmod(destination,0o600)
            for suffix in ("","-wal","-shm","-journal"): index.with_name("Manifest.db"+suffix).unlink(missing_ok=True)
            if not profiles(result.source): raise BridgeError("This backup contains no supported Withings databases.")
            progress("Preparing the extracted databases…",52)
            prepare_databases(result.source)
            progress("Backup opened. Choose your profile.",55)
            return result
        except BaseException:
            result.close();raise


def profiles(folder):
    return sorted({m.group(1) for f in folder.iterdir() if (m:=re.fullmatch(r"([0-9]+)_(WTHealth|Measure|Tracks|vasistas)\.sqlite",f.name))})


def profile_choices(folder):
    ids=profiles(folder);names={};file=folder/"associated_device.sqlite"
    if file.is_file():
        try:
            with closing(sqlite3.connect(file.as_uri()+"?mode=ro",uri=True)) as db:
                columns={r[1] for r in db.execute("PRAGMA table_info(ZDEVICEUSER)")}
                if {"Z_PK","ZUSERID","ZFIRSTNAME","ZFAMILYNAME"}.issubset(columns):
                    where="WHERE COALESCE(ZISREMOVED,0)=0" if "ZISREMOVED" in columns else ""
                    order="ZMODIFIED DESC,Z_PK DESC" if "ZMODIFIED" in columns else "Z_PK DESC"
                    for user,first,last in db.execute(f"SELECT ZUSERID,ZFIRSTNAME,ZFAMILYNAME FROM ZDEVICEUSER {where} ORDER BY {order}"):
                        identity=str(user)
                        name=" ".join((str(first or "")+" "+str(last or "")).split())[:160]
                        if identity in ids and name and identity not in names: names[identity]=name
        except sqlite3.Error: pass
    return [(identity,names.get(identity)) for identity in ids]
