"""Manual backup publishing UI. All Tk calls stay on the main thread."""
from __future__ import annotations
import datetime as dt
import os
from pathlib import Path
import queue
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog,messagebox,ttk
from . import VERSION
from .backup import BackupSession,discover,profile_choices
from .exchange import BridgeError,canonical
from .publish import configuration_folder,publish
from .storage import app_folder,atomic_write,load_json


def formatted_date(value):
    if value is None:return "Not available"
    if isinstance(value,(int,float)):value=dt.datetime.fromtimestamp(value)
    if hasattr(value,"strftime"):return value.strftime("%b %d, %Y  %I:%M:%S %p")
    return "Date unavailable"


def default_backup_folder():
    candidates=[Path.home()/"Apple"/"MobileSync"/"Backup",
                Path(os.environ.get("APPDATA",Path.home()))/"Apple Computer"/"MobileSync"/"Backup"]
    return next((p for p in candidates if p.is_dir()),Path.home())


def default_icloud_folder():
    return next((p for p in [Path.home()/"iCloudDrive",Path.home()/"iCloud Drive"] if p.is_dir()),Path.home())


class BridgeWindow:
    def __init__(self,root,state=None):
        self.root=root;self.state=state or app_folder();self.preferences=load_json(self.state/"Preferences.json",{})
        self.session=None;self.backups=[];self.choices=[];self.busy=False;self.closing=False;self.messages=queue.SimpleQueue()
        self.root.title("Withings Health Bridge")
        self.root.geometry("850x930");self.root.minsize(700,730)
        try:
            assets=Path(getattr(sys,"_MEIPASS",Path(__file__).resolve().parents[1]))/"assets"
            if os.name=="nt":self.root.iconbitmap(str(assets/"AppIcon.ico"))
        except tk.TclError:pass
        style=ttk.Style(root)
        if os.name=="nt" and "vista" in style.theme_names():style.theme_use("vista")
        style.configure("Title.TLabel",font=("Segoe UI",19,"bold"))
        style.configure("Section.TLabelframe.Label",font=("Segoe UI",11,"bold"))
        self.backup_path=tk.StringVar(value=self.preferences.get("backupFolder",""))
        self.output_path=tk.StringVar(value=self.preferences.get("outputFolder",""))
        self.password=tk.StringVar();self.profile_id=tk.StringVar(value="No profile selected")
        self.status=tk.StringVar(value="Choose a completed local iPhone backup, then open it to select your profile.")
        self.last_checked=tk.StringVar(value="Not checked this session");self.last_published=tk.StringVar(value="Not available")
        self.latest=tk.StringVar(value="No measurements published yet")
        self.show_history=tk.BooleanVar(value=False)
        outer=ttk.Frame(root,padding=14);outer.pack(fill="both",expand=True)
        canvas=tk.Canvas(outer,highlightthickness=0);scroll=ttk.Scrollbar(outer,orient="vertical",command=canvas.yview)
        canvas.configure(yscrollcommand=scroll.set);scroll.pack(side="right",fill="y");canvas.pack(side="left",fill="both",expand=True)
        self.body=ttk.Frame(canvas);window=canvas.create_window((0,0),window=self.body,anchor="nw")
        self.body.bind("<Configure>",lambda _:canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.bind("<Configure>",lambda e:canvas.itemconfigure(window,width=e.width))
        def wheel(event):
            if self.root.focus_get() not in (self.backup_combo,self.profile_combo):canvas.yview_scroll(-int(event.delta/120),"units")
        self.root.bind_all("<MouseWheel>",wheel)
        ttk.Label(self.body,text="Withings Health Bridge",style="Title.TLabel").pack(anchor="w",pady=(0,4))
        self.note(self.body,"iPhone Backup → iCloud Drive → Apple Health",bottom=14)
        self.controls=[]
        backup=self.section("iPhone Backup")
        self.note(backup,"Create a completed local backup with Apple Devices or iTunes. No Withings installation is needed on this PC. iCloud Backups cannot be opened directly.")
        ttk.Label(backup,textvariable=self.backup_path,wraplength=710).pack(anchor="w",pady=4)
        self.button(backup,"Choose iPhone Backup…",self.choose_backup).pack(anchor="w",pady=4)
        ttk.Label(backup,text="Backup date").pack(anchor="w",pady=(8,2))
        self.backup_combo=ttk.Combobox(backup,state="readonly");self.backup_combo.pack(fill="x",pady=3)
        self.backup_combo.bind("<<ComboboxSelected>>",self.change_backup);self.controls.append(self.backup_combo)
        self.password_frame=ttk.Frame(backup)
        ttk.Label(self.password_frame,text="Backup password").pack(anchor="w",pady=(6,2))
        self.password_entry=ttk.Entry(self.password_frame,textvariable=self.password,show="●")
        self.password_entry.pack(fill="x",pady=3);self.controls.append(self.password_entry)
        self.note(self.password_frame,"The local backup encryption password. It is used only on this computer and is not saved.")
        self.open_button=self.button(backup,"Open Backup",self.open_backup);self.open_button.pack(anchor="w",pady=7)
        ttk.Separator(backup).pack(fill="x",pady=8)
        ttk.Label(backup,text="Your Withings Profile").pack(anchor="w")
        self.profile_combo=ttk.Combobox(backup,state="readonly",values=["-none-"]);self.profile_combo.current(0)
        self.profile_combo.pack(fill="x",pady=4);self.profile_combo.bind("<<ComboboxSelected>>",self.change_profile)
        self.controls.append(self.profile_combo)
        ttk.Label(backup,textvariable=self.profile_id).pack(anchor="w",pady=3)
        self.note(backup,"Select only your own profile. Apple Health belongs to the person using the iPhone.")
        delivery=self.section("iCloud Delivery")
        ttk.Label(delivery,textvariable=self.output_path,wraplength=710).pack(anchor="w",pady=4)
        self.button(delivery,"Choose Output Folder…",self.choose_output).pack(anchor="w",pady=4)
        self.note(delivery,"Choose a dedicated folder in iCloud Drive. Install and sign into iCloud for Windows separately; Apple handles delivery to your iPhone. The bridge does not ask for Apple Account credentials.")
        sync=self.section("Publication")
        self.publish_button=self.button(sync,"Publish Backup",self.publish_backup);self.publish_button.pack(anchor="w",pady=4)
        self.note(sync,"Manual publishing only. Make and open a new local backup for newer readings. Publishing an older backup can replace this bridge's newer Health entries; use the freshest source.")
        self.progress=ttk.Progressbar(sync,maximum=100);self.progress.pack(fill="x",pady=8)
        ttk.Label(sync,textvariable=self.status,wraplength=710,justify="left").pack(fill="x",pady=4)
        for label,value in [("Last checked",self.last_checked),("Last published (local)",self.last_published)]:
            line=ttk.Frame(sync);line.pack(fill="x",pady=3)
            ttk.Label(line,text=label).pack(side="left");ttk.Label(line,textvariable=value).pack(side="right")
        self.note(sync,"Last published confirms the local file write, not iCloud delivery or an Apple Health import.")
        recent=self.section("Recent Measurements")
        ttk.Label(recent,textvariable=self.latest,wraplength=710).pack(anchor="w",pady=4)
        ttk.Checkbutton(recent,text="Show the 50 newest published measurements",variable=self.show_history,command=self.toggle_history).pack(anchor="w",pady=4)
        self.history_frame=ttk.Frame(recent)
        self.history=ttk.Treeview(self.history_frame,columns=("metric","date"),show="headings",height=9)
        self.history.heading("metric",text="Measurement");self.history.heading("date",text="Measurement date/time")
        self.history.column("metric",width=260);self.history.column("date",width=280)
        history_scroll=ttk.Scrollbar(self.history_frame,orient="vertical",command=self.history.yview)
        self.history.configure(yscrollcommand=history_scroll.set);self.history.pack(side="left",fill="both",expand=True);history_scroll.pack(side="right",fill="y")
        privacy=self.section("Privacy")
        self.note(privacy,"Only supported measurements with verified Withings-device provenance and the profile name are published. Original backups are not modified. No developer server, trackers, advertising, Withings login or online backup-password handling.")
        self.note(self.body,f"Windows {VERSION} · Independent software; not affiliated with or endorsed by Withings.",bottom=8)
        self.root.protocol("WM_DELETE_WINDOW",self.close)
        self.root.after(100,self.receive)
        if self.backup_path.get():self.scan_backup(Path(self.backup_path.get()))
        self.update_controls()
    def section(self,title):
        frame=ttk.LabelFrame(self.body,text=title,padding=12,style="Section.TLabelframe");frame.pack(fill="x",pady=(0,12));return frame
    @staticmethod
    def note(parent,text,bottom=4):
        label=ttk.Label(parent,text=text,wraplength=710,justify="left")
        label.pack(fill="x",anchor="w",pady=(3,bottom))
        label.bind("<Configure>",lambda event:label.configure(wraplength=max(300,event.width)))
    def button(self,parent,text,action):
        button=ttk.Button(parent,text=text,command=action);self.controls.append(button);return button
    def save(self):
        try:atomic_write(self.state/"Preferences.json",canonical(self.preferences))
        except OSError:self.status.set("The selected options could not be remembered on this computer.")
    def release_backup(self):
        if self.session:self.session.close();self.session=None
        self.password.set("");self.choices=[];self.profile_combo.configure(values=["-none-"]);self.profile_combo.current(0)
        self.profile_id.set("No profile selected");self.last_published.set("Not available");self.render_history([])
    def choose_backup(self):
        folder=filedialog.askdirectory(title="Choose iPhone Backup",initialdir=self.backup_path.get() or str(default_backup_folder()))
        if not folder:return
        self.release_backup();self.backup_path.set(folder);self.preferences["backupFolder"]=folder;self.save();self.scan_backup(Path(folder))
    def scan_backup(self,folder):
        try:
            self.backups=discover(folder)
            self.backup_combo.configure(values=[formatted_date(i.date)+( " · Encrypted" if i.encrypted else " · Unencrypted")+" · "+i.folder.name for i in self.backups])
            self.backup_combo.current(0);self.change_backup()
        except (OSError,BridgeError,ValueError):
            self.backups=[];self.status.set("No completed iPhone backup could be read. Choose its complete folder or parent folder.")
        self.update_controls()
    def change_backup(self,_=None):
        self.release_backup()
        if self.backups:
            info=self.backups[self.backup_combo.current()]
            if info.encrypted:self.password_frame.pack(before=self.open_button,fill="x",pady=3)
            else:self.password_frame.pack_forget()
            self.status.set("Open the selected backup to find your Withings profiles.")
        self.update_controls()
    def open_backup(self):
        if not self.backups:return
        info=self.backups[self.backup_combo.current()];password=self.password.get();self.password.set("")
        if info.encrypted and not password:self.status.set("Enter the local backup encryption password.");return
        self.release_backup()
        self.run(lambda:BackupSession.open(info,password,self.state/"Sessions",self.report),self.opened)
    def opened(self,session):
        self.session=session;self.choices=profile_choices(session.source)
        self.profile_combo.configure(values=["-none-"]+[(name+" ("+identity+")") if name else "Profile "+identity for identity,name in self.choices])
        saved=self.preferences.get("profiles",{}).get(str(session.info.folder),"")
        ids=[identity for identity,_ in self.choices]
        self.profile_combo.current(ids.index(saved)+1 if saved in ids else 0)
        self.change_profile();self.status.set("Backup opened. Select your own profile and publish when ready.")
    def selected_profile(self):
        index=self.profile_combo.current()-1
        return self.choices[index][0] if 0<=index<len(self.choices) else ""
    def change_profile(self,_=None):
        identity=self.selected_profile();self.profile_id.set("Profile number: "+identity if identity else "No profile selected")
        if self.session:
            self.preferences.setdefault("profiles",{})[str(self.session.info.folder)]=identity;self.save()
        self.refresh_publication();self.update_controls()
    def choose_output(self):
        folder=filedialog.askdirectory(title="Choose iCloud Drive Output Folder",initialdir=self.output_path.get() or str(default_icloud_folder()))
        if folder:
            self.output_path.set(folder);self.preferences["outputFolder"]=folder;self.save();self.refresh_publication();self.update_controls()
    def refresh_publication(self):
        identity=self.selected_profile();output=Path(self.output_path.get())
        if not self.session or not identity or not self.output_path.get():return
        state=configuration_folder(self.state,self.session.info.folder,output,identity)
        self.render_history(load_json(state/"RecentPublished.json",[]))
        file=output/f"profile-{identity}.whealth"
        try:self.last_published.set(formatted_date(file.stat().st_mtime))
        except OSError:self.last_published.set("Not available")
    def publish_backup(self):
        identity=self.selected_profile()
        if not self.session or not identity:return
        session=self.session;output=Path(self.output_path.get())
        self.last_checked.set(formatted_date(time.time()))
        self.run(lambda:publish(session,identity,output,self.state,self.report),self.published)
    def published(self,result):
        self.status.set(result.message+f" Total: {result.count:,}.");self.last_checked.set(formatted_date(time.time()))
        self.refresh_publication();self.render_history(result.history)
    def report(self,message,percent):self.messages.put(("progress",(message,percent)))
    def run(self,work,complete):
        if self.busy:return
        self.busy=True;self.update_controls();self.progress.configure(mode="indeterminate");self.progress.start(12)
        def worker():
            try:self.messages.put(("done",(complete,work())))
            except Exception as error:
                if isinstance(error,BridgeError):message=str(error)
                elif isinstance(error,OSError):message="A local file could not be accessed. Check folder access, available disk space and iCloud Drive availability."
                else:message="The backup could not be processed. It may contain an unsupported database or damaged metadata."
                self.messages.put(("error",message))
        threading.Thread(target=worker,daemon=True).start()
    def receive(self):
        try:
            while True:
                kind,value=self.messages.get_nowait()
                if kind=="progress":
                    message,percent=value;self.status.set(message)
                    if percent is None:self.progress.configure(mode="indeterminate");self.progress.start(12)
                    else:self.progress.stop();self.progress.configure(mode="determinate");self.progress["value"]=percent
                else:
                    self.busy=False;self.progress.stop()
                    if kind=="done":
                        complete,result=value
                        try:complete(result)
                        except Exception:self.status.set("The operation finished, but the display could not be refreshed. Reopen the backup and try again.")
                    else:self.status.set(value)
                    self.update_controls()
                    if self.closing:self.close();return
        except queue.Empty:pass
        self.root.after(100,self.receive)
    def update_controls(self):
        for control in self.controls:
            if isinstance(control,ttk.Combobox):control.configure(state="disabled" if self.busy else "readonly")
            else:control.configure(state="disabled" if self.busy else "normal")
        self.open_button.configure(state="normal" if self.backups and not self.busy else "disabled")
        self.profile_combo.configure(state="readonly" if self.session and not self.busy else "disabled")
        self.publish_button.configure(state="normal" if self.session and self.selected_profile() and self.output_path.get() and not self.busy else "disabled")
    def render_history(self,events):
        self.history.delete(*self.history.get_children())
        for item in events[:50]:self.history.insert("","end",values=(item["metricName"],formatted_date(item["measuredAt"])))
        self.latest.set("Last published metric: "+events[0]["metricName"]+" · "+formatted_date(events[0]["measuredAt"]) if events else "No measurements published yet")
    def toggle_history(self):
        if self.show_history.get():self.history_frame.pack(fill="both",expand=True,pady=6)
        else:self.history_frame.pack_forget()
    def close(self):
        if self.busy:self.closing=True;self.status.set("Finishing the current operation before closing…");return
        self.release_backup();self.root.destroy()
