from __future__ import annotations
import argparse
from pathlib import Path
import tempfile
import tkinter as tk
from bridge.ui import BridgeWindow


def main():
    parser=argparse.ArgumentParser(description="Withings Health Bridge for Windows")
    parser.add_argument("--smoke-test",metavar="RESULT_FILE",help=argparse.SUPPRESS)
    args=parser.parse_args()
    root=tk.Tk()
    if args.smoke_test:
        # Build-run verification only: no user settings, backups, Health or cloud access.
        from Crypto.Cipher import AES
        import sqlite3
        key=b"k"*32;clear=b"t"*32
        wrapped=AES.new(key,AES.MODE_KW).seal(clear)
        assert AES.new(key,AES.MODE_KW).unseal(wrapped)==clear
        assert len(AES.new(key,AES.MODE_CBC,iv=bytes(16)).encrypt(bytes(16)))==16
        with sqlite3.connect(":memory:") as connection:
            assert connection.execute("SELECT 1").fetchone()[0]==1
        with tempfile.TemporaryDirectory() as directory:
            app=BridgeWindow(root,Path(directory));root.update_idletasks();root.update()
            assert str(app.publish_button["state"])=="disabled"
            assert str(app.profile_combo["state"])=="disabled"
            app.close()
        Path(args.smoke_test).write_text("Windows UI and bundled dependencies initialized successfully.\n",encoding="utf-8")
    else:
        BridgeWindow(root);root.mainloop()


if __name__=="__main__":main()
