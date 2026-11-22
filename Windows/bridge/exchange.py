"""The existing Swift/iPhone exchange, including Swift-compatible JSON numbers."""
from __future__ import annotations
import hashlib
import json
import math
import time
from collections import Counter

DEVICES = frozenset([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
    41,42,43,44,45,46,47,48,49,51,52,53,54,55,56,57,58,59,60,61,62,63,64,
    70,71,72,73,80,90,91,92,93,94,95,96,100,101,102,103,110,120])
LABELS = {"bodyMass":"Weight", "bodyMassIndex":"BMI", "bodyFatPercentage":"Body Fat",
    "leanBodyMass":"Lean Body Mass", "heartRate":"Heart Rate", "oxygenSaturation":"Blood Oxygen",
    "bodyTemperature":"Body Temperature", "respiratoryRate":"Respiratory Rate",
    "heartRateVariabilitySDNN":"Heart Rate Variability (SDNN)", "stepCount":"Steps",
    "sleepAnalysis":"Sleep", "bloodPressure":"Blood Pressure"}

class BridgeError(Exception):
    """A safe user-facing error. Never include passwords, keys or arbitrary DB blobs."""


def swift_number(value: float, *, identity: bool = False) -> str:
    """Match Swift Double.description / JSONEncoder for the exchange's numeric ranges."""
    if not math.isfinite(value):
        raise BridgeError("A measurement contains a non-finite number.")
    text = repr(float(value))
    # Swift switches to exponent notation below 1e-4 and at 1e16.
    if 1e-4 <= abs(value) < 1e16 and "e" in text:
        from decimal import Decimal
        text = format(Decimal(text), "f")
        if identity and "." not in text:
            text += ".0"
    if not identity and text.endswith(".0"):
        text = text[:-2]
    return text


def canonical(value) -> bytes:
    def encode(item):
        if item is None: return "null"
        if isinstance(item, bool): return "true" if item else "false"
        if isinstance(item, str): return json.dumps(item, ensure_ascii=False)
        if isinstance(item, int): return str(item)
        if isinstance(item, float): return swift_number(item)
        if isinstance(item, list): return "[" + ",".join(encode(x) for x in item) + "]"
        if isinstance(item, dict):
            return "{" + ",".join(encode(k) + ":" + encode(item[k]) for k in sorted(item)) + "}"
        raise TypeError(type(item).__name__)
    return encode(value).encode("utf-8")


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def record_id(profile: str, metric: str, start: float, end: float, position="0") -> str:
    return digest(canonical([profile, metric, swift_number(start, identity=True),
                             swift_number(end, identity=True), position]))


def valid(metric, value, second=None):
    if not isinstance(value, (int,float)) or not math.isfinite(value): return False
    if second is not None and (not isinstance(second, (int,float)) or not math.isfinite(second)): return False
    ranges = {"bodyMass":(1,600), "leanBodyMass":(1,600), "bodyMassIndex":(5,150),
        "bodyFatPercentage":(0,1), "oxygenSaturation":(.5,1), "heartRate":(20,300),
        "bodyTemperature":(25,45), "respiratoryRate":(1,100), "heartRateVariabilitySDNN":(.001,5)}
    if metric in ranges: return ranges[metric][0] <= value <= ranges[metric][1]
    if metric == "stepCount": return 1 <= value <= 200000 and int(value) == value
    if metric == "sleepAnalysis": return value in (0,1,2,3)
    if metric == "bloodPressure": return 40 <= value <= 300 and second is not None and 20 <= second <= 200 and value > second
    return False


def validate(snapshot):
    try:
        records = snapshot["records"]
        profile = snapshot["profileID"]
        if (snapshot["format"] != "WithingsHealthBridge" or snapshot["version"] != 1
            or not isinstance(profile,str) or not profile.isascii() or not profile.isdigit()
            or snapshot["revision"] <= 0 or len(records) > 1_000_000
            or len(snapshot.get("profileName") or "") > 160
            or digest(canonical(records)) != snapshot["recordsSHA256"]): raise ValueError()
        ids = set()
        for r in records:
            if (r["profileID"] != profile or r["id"] in ids or len(r["id"]) != 64
                or any(c not in "0123456789abcdef" for c in r["id"])
                or r["brand"] not in (0,1) or r["deviceModel"] not in DEVICES
                or not math.isfinite(r["start"]) or not math.isfinite(r["end"])
                or r["start"] <= 0 or not 0 <= r["end"]-r["start"] <= 7*86400
                or r["end"] > time.time()+86400
                or not valid(r["metric"],r["value"],r.get("secondValue"))
                or r["metric"] == "sleepAnalysis" and r["end"] <= r["start"]): raise ValueError()
            ids.add(r["id"])
    except (KeyError,TypeError,ValueError,OverflowError):
        raise BridgeError("The existing export is incomplete, unsupported or invalid. No replacement was published.") from None


def read_snapshot(path):
    if path.is_symlink() or path.stat().st_size > 128*1024*1024:
        raise BridgeError("The existing export is too large or is not a regular local file.")
    # Preserve a JSON negative zero, if a Swift publisher emitted one.
    snapshot = json.loads(path.read_text(encoding="utf-8"), parse_int=lambda s: -0.0 if s == "-0" else int(s))
    validate(snapshot)
    return snapshot
