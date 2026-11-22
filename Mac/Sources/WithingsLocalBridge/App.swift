import SwiftUI
import AppKit
import Combine
import BridgeCore

@MainActor final class BridgeModel:ObservableObject {
    @Published var backupMode=false
    @Published var backups:[IPhoneBackupInfo]=[]
    @Published var backupIndex=0
    @Published var backupPassword=""
    @Published var backupFolder:URL?
    private var backupSession:IPhoneBackupSession?
    @Published var withingsApplication:URL?
    @Published var source:URL?
    @Published var output:URL?
    @Published var profiles:[ProfileChoice]=[]
    @Published var profile=""
    @Published var automatic=false
    @Published var working=false
    @Published var status="Choose the Withings database folder and an output folder in iCloud Drive."
    @Published var lastSync:String=""
    @Published var lastPublished:String=""
    @Published var recentMeasurements:[PublishedMeasurement]=[]
    @Published var showRecentMeasurements=false
    private var termination:AnyCancellable?
    private var monitor:AutoPublishMonitor?
    private var signature:String?
    private let defaults=UserDefaults.standard
    init(){
        refreshWithingsInstallation()
        output=restore("output")
        if !defaults.bool(forKey:"backupMode") { source=BridgeLocations.sourceFolder(override:restore("source")) }
        // Do not trust old releases' automatically chosen profile preference.
        defaults.removeObject(forKey:"profile");defaults.removeObject(forKey:"automatic")
        if source != nil {loadProfiles(restoreSelection:true)}
        else {status="Choose the Withings database folder to continue."}
        if defaults.bool(forKey:"backupMode") { setBackupMode(true) }
        refreshHistory()
        monitor=AutoPublishMonitor{[weak self] in self?.poll()}
        termination=NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification).sink{[weak self] _ in self?.backupSession=nil}
    }
    func setBackupMode(_ enabled:Bool) {
        backupMode=enabled; defaults.set(enabled,forKey:"backupMode")
        automatic=false; profile=""; profiles=[]; signature=nil; backupPassword=""
        backupSession=nil; lastSync=""; lastPublished=""; recentMeasurements=[]
        if enabled {
            source=nil
            if let folder=restore("backup") { inspectBackup(folder) }
            else { status="Choose an iPhone backup folder, then unlock it to select your profile." }
        } else {
            source=BridgeLocations.sourceFolder(override:restore("source"))
            loadProfiles(restoreSelection:true)
        }
    }
    func chooseBackup() {
        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=false
        panel.prompt="Choose iPhone Backup"
        panel.message="Choose a backup folder or its parent folder. The original backup will not be modified."
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            defaults.set(try url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil),forKey:"backup")
            inspectBackup(url)
        } catch {status=error.localizedDescription}
    }
    func inspectBackup(_ folder:URL) {
        backupSession=nil; source=nil; profiles=[]; profile=""; backupPassword=""
        backupFolder=folder; backupIndex=0
        let access=folder.startAccessingSecurityScopedResource(); defer{if access{folder.stopAccessingSecurityScopedResource()}}
        do { backups=try IPhoneBackupInfo.discover(in:folder); status="Unlock the selected backup to find Withings profiles." }
        catch {backups=[];status=error.localizedDescription}
    }
    func selectBackup(_ index:Int) {
        backupIndex=index; backupPassword=""; backupSession=nil; source=nil; profiles=[];profile=""
        status="Unlock the selected backup to find Withings profiles."
    }
    func unlockBackup() {
        guard backups.indices.contains(backupIndex),!working else{return}
        let info=backups[backupIndex], password=backupPassword, folder=backupFolder
        backupPassword="";working=true;source=nil;profile="";profiles=[];backupSession=nil
        Task { [self] in
            let access=folder?.startAccessingSecurityScopedResource() ?? false
            defer{if access{folder?.stopAccessingSecurityScopedResource()};working=false}
            do {
                let session=try await Task.detached(priority:.utility){ [weak self] in
                    try IPhoneBackupSession.open(info,password:password){ [weak self] message in
                        Task{@MainActor [weak self] in self?.status=message}
                    }
                }.value
                backupSession=session;source=session.source
                loadProfiles()
                if let saved=defaults.string(forKey:"backupProfile-" + digest(Data(info.folder.path.utf8))),profiles.contains(where:{$0.id == saved}) {profile=saved}
                refreshHistory();refreshPublishedTime()
                status="Backup opened. Choose your profile and publish manually. Backup data can replace newer data previously published for that profile."
            } catch {status=error.localizedDescription}
        }
    }
    func refreshWithingsInstallation(){
        withingsApplication=BridgeLocations.withingsApplication(registered:NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.withings.wiScaleNG"))
    }
    func openWithings(){if let withingsApplication{NSWorkspace.shared.open(withingsApplication)}}
    private func restore(_ key:String)->URL? {
        guard let data=defaults.data(forKey:key) else{return nil}
        var stale=false
        guard let url=try? URL(resolvingBookmarkData:data,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale) else{return nil}
        if stale {
            let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
            if let refreshed=try? url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil){defaults.set(refreshed,forKey:key)}
        }
        return url
    }
    func choose(source choosingSource:Bool) {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.prompt=choosingSource ? "Choose Database Folder":"Choose Output Folder"
        panel.message=choosingSource ? "Choose Withings’ coredata folder, or a folder containing database backups with their WAL files.":"Choose a folder in iCloud Drive (or another local folder). Only verified Withings-device records supported by Apple Health are published."
        if choosingSource { panel.directoryURL=source ?? BridgeLocations.standardDatabaseFolder() }
        guard panel.runModal() == .OK,let url=panel.url else{return}
        if choosingSource {profile="";automatic=false;signature=nil;lastSync="";lastPublished="";recentMeasurements=[];ProfilePreferences.clear(defaults:defaults)}
        do {
            let key=choosingSource ? "source":"output"
            let bookmark=try url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            defaults.set(bookmark,forKey:key)
            if choosingSource {source=url;loadProfiles()} else {output=url}
            signature=nil
            refreshHistory()
        }catch{status=error.localizedDescription}
    }
    var canSync:Bool { ProfileSelection.canSync(source:source,output:output,selected:profile,choices:profiles,working:working) }
    func useStandardSource(){
        defaults.removeObject(forKey:"source");ProfilePreferences.clear(defaults:defaults)
        profile="";automatic=false;profiles=[];signature=nil;lastSync="";lastPublished="";recentMeasurements=[]
        source=BridgeLocations.sourceFolder(override:nil)
        if source != nil {loadProfiles()}else{status="The standard database folder was not found. Open Withings and sign in, or choose a database folder."}
    }
    private func loadProfiles(restoreSelection:Bool=false){
        profile="";automatic=false;signature=nil;lastSync="";lastPublished="";recentMeasurements=[]
        guard let source else{return}
        let access=source.startAccessingSecurityScopedResource();defer{if access{source.stopAccessingSecurityScopedResource()}}
        do {
            profiles=try ProfileCatalog.choices(in:source)
            if restoreSelection,let saved=ProfilePreferences.restore(source:source,choices:profiles,defaults:defaults){
                profile=saved.profileID;automatic=saved.automatic
                status="Restored your selected profile and synchronization options."
            } else {
                status=profiles.isEmpty ? "No supported Withings database profiles were found in that folder. Open Withings and sign in, or choose another folder." : "Choose a profile before enabling synchronization."
            }
        } catch {status="The database folder could not be read. Choose it using the folder button to grant access. " + error.localizedDescription;profiles=[]}
    }
    func remember(){
        signature=nil
        if backupMode {if let info=backupSession?.info {defaults.set(profile,forKey:"backupProfile-" + digest(Data(info.folder.path.utf8)))};automatic=false}
        else if let source {ProfilePreferences.save(source:source,profileID:profile,choices:profiles,automatic:automatic,defaults:defaults)}
        refreshPublishedTime()
        refreshHistory()
        if automatic {poll()}
    }
    func selectProfile(_ id:String){
        profile=profiles.contains(where:{$0.id == id}) ? id : ""
        automatic=false;signature=nil;lastSync="";lastPublished="";recentMeasurements=[]
        remember()
        status=profile.isEmpty ? "Choose a profile before enabling synchronization." : "Selected profile. Choose an output folder if needed, then sync or enable automatic publishing."
    }
    private func sourceSignature()->String? {
        guard let source else{return nil}
        let access=source.startAccessingSecurityScopedResource();defer{if access{source.stopAccessingSecurityScopedResource()}}
        var values:[String]=[]
        for database in Extractor.databases {
            for suffix in [".sqlite",".sqlite-wal"] {
                let file=source.appendingPathComponent(profile+"_"+database+suffix)
                guard let attrs=try? FileManager.default.attributesOfItem(atPath:file.path) else{values.append(file.lastPathComponent+":missing");continue}
                values.append(file.lastPathComponent+":"+String(describing:attrs[.size])+":"+String(describing:attrs[.modificationDate]))
            }
        }
        return digest(Data(values.joined(separator:"|").utf8))
    }
    private func stateFolder(source:URL,output:URL,profile:String)->URL {
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("WithingsHealthBridge",isDirectory:true)
        let key=digest(Data([backupMode ? (backupSession?.info.folder.path ?? source.path) : source.path,output.path,profile].joined(separator:"\n").utf8))
        return root.appendingPathComponent(key,isDirectory:true)
    }
    private func refreshHistory() {
        guard let source,let output,!profile.isEmpty else{recentMeasurements=[];return}
        recentMeasurements=(try? PublishedHistory.load(state:stateFolder(source:source,output:output,profile:profile))) ?? []
    }
    private func refreshPublishedTime() {
        guard let output,!profile.isEmpty else{lastPublished="";return}
        let access=output.startAccessingSecurityScopedResource();defer{if access{output.stopAccessingSecurityScopedResource()}}
        let file=output.appendingPathComponent("profile-"+profile+".whealth")
        if let attrs=try? FileManager.default.attributesOfItem(atPath:file.path),let date=attrs[.modificationDate] as? Date {
            lastPublished=date.formatted(date:.abbreviated,time:.standard)
        } else {lastPublished=""}
    }
    func poll(){
        guard !backupMode,automatic,canSync,let next=sourceSignature() else{return}
        lastSync=Date().formatted(date:.abbreviated,time:.standard)
        refreshPublishedTime()
        guard signature != next || lastPublished.isEmpty else {
            status="Checked the local databases: no file changes detected. Automatic publishing is active."
            return
        }
        sync()
    }
    func sync(full:Bool=false){
        guard canSync,let source,let output else{return}
        working=true
        lastSync=Date().formatted(date:.abbreviated,time:.standard)
        let selected=profile
        let before=sourceSignature()
        let config=BridgeConfiguration(source:source,output:output,state:stateFolder(source:source,output:output,profile:selected),profile:selected)
        Task { [self] in
            let a=source.startAccessingSecurityScopedResource(),b=output.startAccessingSecurityScopedResource()
            defer{if a{source.stopAccessingSecurityScopedResource()};if b{output.stopAccessingSecurityScopedResource()};working=false}
            do {
                let result=try await Task.detached(priority:.utility){ [weak self] in
                    try HealthPublisher.publish(config,fullSnapshot:full){ [weak self] message in
                        Task{@MainActor [weak self] in if let self, self.working {self.status=message}}
                    }
                }.value
                status=result.message+" Total: \(result.total).";lastSync=Date().formatted(date:.abbreviated,time:.standard)
                refreshPublishedTime()
                recentMeasurements=result.recentMeasurements
                signature=before // A change during extraction is checked again next poll.
            }catch{status=error.localizedDescription}
        }
    }
}

@main struct WithingsLocalBridgeApp:App {
    @StateObject private var model=BridgeModel()
    var body:some Scene {
        Window("Withings Health Bridge",id:"bridge-main"){
            Form {
                Section("Data Source") {
                    Picker("Source",selection:Binding(get:{model.backupMode},set:{model.setBackupMode($0)})) {
                        Text("Withings on this Mac").tag(false)
                        Text("iPhone Backup").tag(true)
                    }.pickerStyle(.segmented)
                }
                if !model.backupMode {
                Section("Withings Application") {
                    if model.withingsApplication != nil {
                        Label("Withings is installed",systemImage:"checkmark.circle.fill")
                        Text("Open Withings (WiScale.app) and sign in so it can sync current data to this Mac.").font(.caption).foregroundStyle(.secondary)
                        Button("Open Withings"){model.openWithings()}
                    } else {
                        Label("Withings is not installed",systemImage:"exclamationmark.triangle")
                        Text("Install Withings (WiScale.app) and sign in to keep the local databases up to date. Existing database backups can still be read.").font(.callout)
                        Button("Check Again"){model.refreshWithingsInstallation()}
                    }
                }
                }
                Section("Database Source") {
                    if model.backupMode {
                        Text(model.backupFolder?.path ?? "No backup folder selected").font(.callout).textSelection(.enabled)
                        Button("Choose iPhone Backup…"){model.chooseBackup()}
                        if !model.backups.isEmpty {
                            Picker("Backup",selection:Binding(get:{model.backupIndex},set:{model.selectBackup($0)})) {
                                ForEach(model.backups.indices,id:\.self) { index in
                                    Text(model.backups[index].date?.formatted(date:.abbreviated,time:.standard) ?? "Date unavailable").tag(index)
                                }
                            }
                            if model.backups.indices.contains(model.backupIndex),model.backups[model.backupIndex].encrypted {
                                SecureField("Backup password",text:$model.backupPassword)
                                Text("Use the Finder/iTunes backup password. It is not saved or sent anywhere.").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Open Backup"){model.unlockBackup()}
                            Text("Only the required Withings databases are extracted into a temporary private folder. Publish manually after opening each backup; the Withings Mac app is not required.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                    Text(model.source?.path ?? "No folder selected").font(.callout).textSelection(.enabled)
                    HStack {
                        Button("Choose Withings Database Folder…"){model.choose(source:true)}
                        Button("Use Standard Location"){model.useStandardSource()}
                    }
                    }
                    Picker("Profile",selection:Binding(get:{model.profile},set:{model.selectProfile($0)})){
                        Text("-none-").tag("")
                        ForEach(model.profiles){Text($0.label).tag($0.id)}
                    }
                }
                Section("iCloud Delivery") {
                    Text(model.output?.path ?? "No output folder selected").font(.callout).textSelection(.enabled)
                    Button("Choose Output Folder…"){model.choose(source:false)}
                    Text("Choose an iCloud Drive folder to transfer extracted records to your iPhone. This app makes no requests to Withings servers.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Synchronization") {
                    if !model.backupMode {
                    Toggle("Automatically publish database changes",isOn:$model.automatic)
                        .disabled(!model.canSync)
                        .onChange(of:model.automatic){_ in model.remember()}
                    Text("Checks once a minute while this Mac app is running, including with its window closed. Also checks when the Mac wakes or you return to the app. Withings must update its local databases before there is anything new to publish.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack{
                        Button(model.backupMode ? "Publish Backup":"Sync Now"){model.sync()}.buttonStyle(.borderedProminent)
                    }.disabled(!model.canSync)
                    if model.working{ProgressView().frame(maxWidth:.infinity)}
                    Text(model.status).textSelection(.enabled)
                    LabeledContent("Last checked",value:model.lastSync.isEmpty ? "Not checked this session":model.lastSync)
                    LabeledContent("Last published (local)",value:model.lastPublished.isEmpty ? "Not available":model.lastPublished)
                    Text("Last checked updates even when nothing changed. Last published is when the local snapshot file was written; it does not confirm iCloud delivery.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Recent Measurements") {
                    DisclosureGroup(isExpanded:$model.showRecentMeasurements) {
                        if model.recentMeasurements.isEmpty {
                            Text("Published measurements will appear here after the next successful check.").foregroundStyle(.secondary)
                        }
                        ForEach(model.recentMeasurements) {item in
                            VStack(alignment:.leading,spacing:4) {
                                Text(item.metricName)
                                Text(item.measuredAt.formatted(date:.abbreviated,time:.standard)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        VStack(alignment:.leading,spacing:4) {
                            Text("Last Published Metric")
                            if let latest=model.recentMeasurements.first {
                                Text(latest.metricName+" · "+latest.measuredAt.formatted(date:.abbreviated,time:.standard)).font(.caption).foregroundStyle(.secondary)
                            } else {Text("No recent history").font(.caption).foregroundStyle(.secondary)}
                        }
                    }
                    Text("Up to 50 newest measurements successfully published from the databases. Dates are measurement times. Apple Health imports are shown on the iPhone.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Privacy and Coverage") {
                    Text("Reads selected databases without changing their measurement records. Publishes only supported Apple Health measurements with verified Withings hardware provenance. Unknown devices, imported data, scores, credentials, notes, audio and GPS are excluded.")
                    Text("Select this same iCloud folder in the Health Bridge iPhone app.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).padding().frame(minWidth:640,minHeight:780)
            .disabled(model.working)
        }.defaultSize(width:700,height:900)
        MenuBarExtra("Withings Health Bridge",systemImage:"heart.text.square") {
            BridgeMenu(model:model)
        }.menuBarExtraStyle(.menu)
    }
}

private struct BridgeMenu:View {
    @ObservedObject var model:BridgeModel
    @Environment(\.openWindow) private var openWindow
    var body:some View {
        Text("Withings Health Bridge")
        Text(model.working ? "Syncing…":model.backupMode ? "Manual backup publishing":model.automatic ? "Automatic publishing on":"Automatic publishing off")
        Divider()
        Button(model.working ? "Syncing…":model.backupMode ? "Publish Backup":"Sync Now") {model.sync()}
            .disabled(!model.canSync)
        Text("Last checked: \(model.lastSync.isEmpty ? "Not checked this session":model.lastSync)")
        Text("Last published (local): \(model.lastPublished.isEmpty ? "Not available":model.lastPublished)")
        Divider()
        Button("Recent Measurements…") {
            model.showRecentMeasurements=true
            openWindow(id:"bridge-main")
            NSApp.activate(ignoringOtherApps:true)
        }
        Button("Open Withings Health Bridge") {
            openWindow(id:"bridge-main")
            NSApp.activate(ignoringOtherApps:true)
        }
        Divider()
        Button("Quit Withings Health Bridge") {NSApp.terminate(nil)}
    }
}
