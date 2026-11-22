from __future__ import annotations
from dataclasses import dataclass
import json
from pathlib import Path
import time
from .backup import profile_choices
from .exchange import BridgeError,LABELS,canonical,digest,read_snapshot,validate
from .measurements import extract
from .storage import atomic_write,export_lock,load_json,private_folder


def configuration_folder(root,backup,output,profile):
    identity=digest(canonical([str(backup.resolve()),str(output.resolve()),profile]))
    return private_folder(root/"Publications"/identity)


def recent_events(snapshot,previous,existing):
    old={r["id"]:r for r in (previous or {}).get("records",[])}
    events={r["id"]:r for r in existing if isinstance(r,dict) and "id" in r}
    if not existing and previous:
        for row in previous["records"]:
            events[row["id"]]={"id":row["id"],"metricName":LABELS[row["metric"]],"measuredAt":row["start"],"publishedAt":previous["publishedAt"]}
    for row in snapshot["records"]:
        if old.get(row["id"])!=row:
            events[row["id"]]={"id":row["id"],"metricName":LABELS[row["metric"]],"measuredAt":row["start"],"publishedAt":snapshot["publishedAt"]}
    return sorted(events.values(),key=lambda x:(-x.get("measuredAt",0),-x.get("publishedAt",0),x["id"]))[:50]


@dataclass
class PublishResult:
    count:int
    changed:bool
    history:list
    message:str


def publish(session,profile,output,state_root,progress=lambda *_:None):
    output=Path(output).resolve();source=session.source.resolve();backup=session.info.folder.resolve()
    if not output.is_dir():raise BridgeError("Choose an existing output folder in iCloud Drive.")
    if output==backup or output.is_relative_to(backup) or backup.is_relative_to(output) or output.is_relative_to(source) or source.is_relative_to(output):
        raise BridgeError("Choose an output folder separate from the backup and temporary databases.")
    state=configuration_folder(state_root,backup,output,profile)
    if state.is_relative_to(output) or output.is_relative_to(state):raise BridgeError("Keep private bridge settings outside the output folder.")
    with export_lock(state/"publish.lock"):
        records,descriptions=extract(source,profile,progress)
        source_file=state/"sources.json"
        if source_file.exists():
            try:previous_sources=json.loads(source_file.read_text(encoding="utf-8"))
            except (OSError,ValueError):raise BridgeError("Private source tracking is unreadable. No data was published.") from None
            if any(prior not in descriptions for prior in previous_sources):
                raise BridgeError("A database is missing, replaced or changed schema. Review the source and choose a new output folder.")
        name=dict(profile_choices(source)).get(profile)
        destination=output/f"profile-{profile}.whealth"
        previous=read_snapshot(destination) if destination.exists() else None
        if previous is not None and previous["profileID"]!=profile:raise BridgeError("The output belongs to another profile.")
        records_hash=digest(canonical(records))
        changed=previous is None or previous["recordsSHA256"]!=records_hash or previous.get("profileName")!=name
        now=time.time()
        snapshot={"format":"WithingsHealthBridge","version":1,"profileID":profile,
            "revision":max(int(now*1000),(previous or {}).get("revision",0)+1),"publishedAt":now,
            "recordsSHA256":records_hash,"records":records}
        if name is not None:snapshot["profileName"]=name
        if not changed:snapshot=previous
        validate(snapshot)
        payload=canonical(snapshot)
        if len(payload)>128*1024*1024:raise BridgeError("This export exceeds the iPhone client's file-size limit. No data was published.")
        info={"format":"WithingsHealthBridgeProfile","version":1,"profileID":profile}
        if name is not None:info["name"]=name
        sidecar=output/f"profile-{profile}.wprofile";metadata=canonical(info)
        progress("Publishing the measurement snapshot…",94)
        if not sidecar.exists() or sidecar.read_bytes()!=metadata:atomic_write(sidecar,metadata)
        if changed:atomic_write(destination,payload)
        warning=""
        try:
            atomic_write(source_file,canonical(descriptions))
            history=recent_events(snapshot,previous,load_json(state/"RecentPublished.json",[]))
            atomic_write(state/"RecentPublished.json",canonical(history))
        except OSError:
            warning=" Published successfully, but private history could not be saved."
            history=recent_events(snapshot,None,[])
        progress("Publication complete.",100)
        return PublishResult(len(records),changed,history,("Published eligible measurements." if changed else "No changes in eligible measurements.")+warning)
