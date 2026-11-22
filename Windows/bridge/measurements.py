"""Health-only projection of the same native columns used by the Mac bridge."""
from __future__ import annotations
from contextlib import closing
import math
import sqlite3
from .backup import FAMILIES
from .exchange import DEVICES,BridgeError,canonical,digest,record_id,valid

EPOCH=978307200.0
QUANTITY_UNITS={"weight":"kg","bmi":"kg/m²","fatMassPercentage":"%","fatFreeMass":"kg","bodyTemperature":"°C"}
SCALARS={"weight":("bodyMass","kg",1),"bmi":("bodyMassIndex","kg/m²",1),
    "fatMassPercentage":("bodyFatPercentage","%",.01),"fatFreeMass":("leanBodyMass","kg",1),
    "heartRate":("heartRate","bpm",1),"oxygenSaturation":("oxygenSaturation","%",.01),
    "bodyTemperature":("bodyTemperature","°C",1)}
MEASURES={"ZWEIGHT":("weight","kg"),"ZFATMASS":("fatMass","kg"),
    "ZFATMASSPERCENTAGE":("fatMassPercentage","%"),"ZMUSCLEMASS":("muscleMass","kg"),
    "ZBONEMASS":("boneMass","kg"),"ZHYDRATATION":("hydration","kg"),
    "ZSYS":("bloodPressureSystolic","mmHg"),"ZDIA":("bloodPressureDiastolic","mmHg"),
    "ZHEARTRATE":("heartRate","bpm"),"ZSP02":("oxygenSaturation","%"),
    "ZTEMPERATURE":("bodyTemperature","°C"),"ZPWV":("pulseWaveVelocity","m/s"),
    "ZVASCULARAGE":("vascularAge","years"),"ZHEARTAGE":("heartAge","years"),
    "ZCARDIOEFFICIENCY":("cardioEfficiency","/100"),"ZCARDIORESPONSIVENESS":("cardioResponsiveness","/100")}


def number(value):
    if isinstance(value,(float,int)) and math.isfinite(value): return float(value)
    return None


def unix(row,key):
    value=number(row.get(key))
    return None if value is None else value+EPOCH


def rows(db,sql):
    cursor=db.execute(sql)
    keys=[c[0] for c in cursor.description]
    # Last duplicate column wins, as in the Swift SQL row decoder.
    for values in cursor: yield dict(zip(keys,values))


def columns(db,table):
    return {r[1] for r in db.execute('PRAGMA table_info("'+table+'")')}


def require(db,table,names):
    if not set(names).issubset(columns(db,table)):
        raise BridgeError(f"Unsupported database schema in {table}. No data was published.")


def source_description(db,family):
    require(db,"Z_METADATA",["Z_UUID"])
    row=db.execute("SELECT Z_UUID FROM Z_METADATA LIMIT 1").fetchone()
    if not row or not row[0]: raise BridgeError(f"Missing database identity in {family}.")
    schema="\n".join(name+":"+(ddl or "") for name,ddl in db.execute("SELECT name,sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"))
    return {"database":family,"identity":row[0],"schemaFingerprint":digest(schema.encode())}


class Projection:
    def __init__(self,profile):
        self.profile=profile;self.selected={};self.raw_count=0
    def add_source(self,row,family,start,end,values,position="0",kind="measurement"):
        self.raw_count+=1
        if self.raw_count>1_000_000: raise BridgeError("This profile exceeds the one-million-source-record limit. No data was published.")
        if start is None: return
        if end is None: end=start
        if not math.isfinite(start) or start<=0 or not math.isfinite(end) or end<start:
            raise BridgeError(f"Invalid measurement time in {family}. No data was published.")
        brand=row.get("ZBRAND");model=row.get("ZDEVICEMODEL")
        if not isinstance(brand,int) or not isinstance(model,int) or brand not in (0,1) or model not in DEVICES or str(row.get("ZBUNDLEIDENTIFIER") or "").lower().startswith("com.apple."):return
        priority=3 if family=="WTHealth" else 2 if family=="Measure" else 1
        def add(metric,value,second=None):
            if position!="0" or end-start>7*86400 or not valid(metric,value,second):return
            identity=record_id(self.profile,metric,start,end,position)
            record={"id":identity,"profileID":self.profile,"metric":metric,"start":start,"end":end,
                    "value":float(value),"brand":int(brand),"deviceModel":int(model)}
            if second is not None: record["secondValue"]=float(second)
            def native_int(field):
                n=row.get(field)
                return n if isinstance(n,int) else None
            device=native_int("ZDEVICEID")
            if device is None:device=native_int("ZDEVICEIDENTIFIER")
            firmware=native_int("ZFIRMWARE")
            if firmware is None:firmware=native_int("ZDEVICEFIRMWARE")
            if device is not None:record["deviceID"]=str(device)
            if firmware is not None:record["firmware"]=str(firmware)
            if identity not in self.selected or self.selected[identity][0]<priority:
                self.selected[identity]=(priority,record)
        for name,(metric,unit,factor) in SCALARS.items():
            if name in values and values[name][1]==unit:add(metric,values[name][0]*factor)
        if "bloodPressureSystolic" in values and "bloodPressureDiastolic" in values:
            add("bloodPressure",values["bloodPressureSystolic"][0],values["bloodPressureDiastolic"][0])
        if kind=="interval" and end>start:
            category=row.get("ZCATEGORY")
            def native(field):return number(row.get(field))
            if model==63 and category==1:
                for field,metric,factor in [("ZSLEEPLEVEL","sleepAnalysis",1),("ZHEARTRATE2","heartRate",1),
                    ("ZRESPIRATORYRATE1","respiratoryRate",1),("ZHEARTRATESDNN1","heartRateVariabilitySDNN",.001)]:
                    n=native(field)
                    if n is not None:
                        if field=="ZHEARTRATESDNN1":
                            quality=native("ZHEARTRATEVARIABILITYQUALITYSCORE")
                            if quality is not None and quality<=0:continue
                            # Match the Swift division exactly, including floating-point rounding.
                            add(metric,n/1000)
                        else:add(metric,n*factor)
            if model!=63 and category==0:
                for field,metric in [("ZSTEPS","stepCount"),("ZSLEEPLEVEL","sleepAnalysis")]:
                    n=native(field)
                    if n is not None:add(metric,n)
            if category==2:
                n=native("ZHEARTRATE1")
                if n is not None:add("heartRate",n)
    def finish(self):return [self.selected[key][1] for key in sorted(self.selected)]


def quantities(db,family,projection,progress):
    require(db,"ZWTOBJECT",["Z_PK","ZTYPEIDENTIFIER","ZSTARTDATE","ZENDDATE","ZISREMOVED","ZQUANTITY","ZSOURCE","ZSEARCHABLEMETADATA"])
    require(db,"ZWTQUANTITY",["Z_PK","ZVALUE"])
    require(db,"ZWTSOURCE",["Z_PK","ZBRAND","ZDEVICEMODEL","ZDEVICEIDENTIFIER","ZDEVICETYPE","ZBUNDLEIDENTIFIER"])
    require(db,"ZWTSEARCHABLEMETADATA",["Z_PK","ZPOSITION","ZTIMEZONE","ZATTRIB","ZMODIFIEDDATE"])
    query="""SELECT o.*,q.ZVALUE AS BRIDGEVALUE,s.ZBRAND,s.ZDEVICEMODEL,s.ZDEVICEIDENTIFIER,s.ZDEVICETYPE,s.ZBUNDLEIDENTIFIER,
        m.ZPOSITION,m.ZTIMEZONE,m.ZATTRIB,m.ZMODIFIEDDATE FROM ZWTOBJECT o
        LEFT JOIN ZWTQUANTITY q ON q.Z_PK=o.ZQUANTITY LEFT JOIN ZWTSOURCE s ON s.Z_PK=o.ZSOURCE
        LEFT JOIN ZWTSEARCHABLEMETADATA m ON m.Z_PK=o.ZSEARCHABLEMETADATA WHERE COALESCE(o.ZISREMOVED,0)=0"""
    for i,row in enumerate(rows(db,query)):
        if i%1000==0:progress(f"Reading body and health measurements: {i:,} records…",60)
        kind=row.get("ZTYPEIDENTIFIER") or ""
        if not kind.startswith(("WTQuantityType.","WTCorrelationType.")):continue
        key=kind.rsplit(".",1)[-1];n=number(row.get("BRIDGEVALUE"))
        projection.add_source(row,family,unix(row,"ZSTARTDATE"),unix(row,"ZENDDATE"),
            {key:(n,QUANTITY_UNITS.get(key))} if n is not None else {},str(row.get("ZPOSITION") if row.get("ZPOSITION") is not None else "0"))


def measures(db,family,projection,progress):
    require(db,"ZWTMEASUREGROUP",["Z_PK","ZDATE","ZREMOVED"])
    require(db,"ZWTSPECIALIZEDGROUP",["Z_PK","ZGROUP","Z2_GROUP"])
    require(db,"ZWTMEASURE",["Z_PK","ZMANTISSA","ZEXPONENT"])
    fields=sorted(columns(db,"ZWTSPECIALIZEDGROUP")-{"Z_PK","Z_ENT","Z_OPT","ZGROUP","Z2_GROUP","ZMEASURETYPE","ZASSOCIATEDREACHEDCOUNTTYPE"})
    readings={r["Z_PK"]:r for r in rows(db,"SELECT * FROM ZWTMEASURE")};groups={}
    for row in rows(db,"SELECT * FROM ZWTSPECIALIZEDGROUP"):
        key=row.get("ZGROUP")
        if key is None:key=row.get("Z2_GROUP")
        groups.setdefault(key,[]).append(row)
    for i,row in enumerate(rows(db,"SELECT * FROM ZWTMEASUREGROUP WHERE COALESCE(ZREMOVED,0)=0")):
        if i%1000==0:progress(f"Reading individual measurements: {i:,} groups…",70)
        values={}
        for group in groups.get(row["Z_PK"],[]):
            for field in fields:
                reading=readings.get(group.get(field));mapped=MEASURES.get(field)
                if reading is None or mapped is None:continue
                mantissa=reading.get("ZMANTISSA");exponent=reading.get("ZEXPONENT")
                if not isinstance(mantissa,int) or not isinstance(exponent,int):continue
                try:n=float(f"{mantissa}e{exponent}")
                except (ValueError,OverflowError):continue
                if math.isfinite(n) and mapped[0] not in values:values[mapped[0]]=(n,mapped[1])
        if values:projection.add_source(row,family,unix(row,"ZDATE"),None,values)


def intervals(db,family,projection,progress):
    if columns(db,"ZTRACK"):require(db,"ZTRACK",["Z_PK","ZSTARTDATE","ZENDDATE","ZISREMOVED"])
    if not columns(db,"ZVASISTAS"):return
    require(db,"ZVASISTAS",["Z_PK","ZTIMESTAMP","ZDURATION"])
    for i,row in enumerate(rows(db,"SELECT * FROM ZVASISTAS")):
        if i%1000==0:progress(f"Reading {family} intervals: {i:,} records…",80 if family=="Tracks" else 85)
        start=unix(row,"ZTIMESTAMP");duration=number(row.get("ZDURATION")) or 0
        if duration<0:raise BridgeError(f"Invalid interval duration in {family}.")
        if start is not None:projection.add_source(row,family,start,start+duration,{},kind="interval")


def extract(folder,profile,progress=lambda *_:None):
    if not profile.isascii() or not profile.isdigit():raise BridgeError("Choose a profile from the selected backup.")
    for family in ("WTHealth","Measure"):
        if not (folder/f"{profile}_{family}.sqlite").is_file():
            raise BridgeError(f"The backup is missing the required {family} database. No data was published.")
    projection=Projection(profile);descriptions=[]
    for family in FAMILIES:
        file=folder/f"{profile}_{family}.sqlite"
        if not file.is_file():continue
        try:
            with closing(sqlite3.connect(file.as_uri()+"?mode=ro",uri=True)) as db:
                db.execute("PRAGMA query_only=ON");db.execute("BEGIN DEFERRED TRANSACTION")
                descriptions.append(source_description(db,family))
                if family=="WTHealth":quantities(db,family,projection,progress)
                elif family=="Measure":measures(db,family,projection,progress)
                else:intervals(db,family,projection,progress)
        except sqlite3.Error:
            raise BridgeError(f"The {family} database could not be read or uses an unsupported schema. No data was published.") from None
    return projection.finish(),sorted(descriptions,key=lambda x:x["database"])
