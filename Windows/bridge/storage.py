from __future__ import annotations
import contextlib
import json
import os
from pathlib import Path
import tempfile
import time
from .exchange import BridgeError, canonical


def private_folder(path: Path):
    path.mkdir(parents=True, exist_ok=True)
    if os.name != "nt": path.chmod(0o700)
    return path


def app_folder():
    base = Path(os.environ.get("LOCALAPPDATA", Path.home()/".local"/"share"))
    return private_folder(base/"WithingsHealthBridge"/"Windows")


def atomic_write(path: Path, data: bytes):
    descriptor, temp = tempfile.mkstemp(prefix=".bridge-",suffix=".tmp",dir=path.parent)
    try:
        with os.fdopen(descriptor,"wb") as stream:
            stream.write(data);stream.flush();os.fsync(stream.fileno())
        for attempt in range(5):
            try: os.replace(temp,path);break
            except PermissionError:
                if attempt == 4: raise
                time.sleep(.15*(attempt+1))
    finally:
        if os.path.exists(temp): os.unlink(temp)


def load_json(path, default):
    try: return json.loads(path.read_text(encoding="utf-8"))
    except (OSError,ValueError): return default


@contextlib.contextmanager
def export_lock(path: Path):
    with path.open("a+b") as stream:
        stream.seek(0)
        if stream.read(1) == b"": stream.write(b"0");stream.flush()
        stream.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(),msvcrt.LK_NBLCK,1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
        except OSError: raise BridgeError("Another publication is already running for this backup and profile.") from None
        try: yield
        finally:
            stream.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(),msvcrt.LK_UNLCK,1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(),fcntl.LOCK_UN)
