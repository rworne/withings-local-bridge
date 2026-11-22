import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit

@MainActor final class SyncModel:ObservableObject {
    @Published var folder:URL?
    @Published var profiles:[String]=[]
    @Published var profileNames:[String:String]=[:]
    @Published var recentImports:[BridgeImportEvent]=[]
    private var historyWarning:String?
    private var namesLoading=false
    var selectedImports:[BridgeImportEvent] {recentImports.filter{$0.profileID==selected}}
    func profileLabel(_ id:String)->String {profileNames[id] ?? "Profile \(id)"}
    private var namesKey:String {"profileNames."+HealthSnapshot.hash(Data((folder?.path ?? "").utf8))}
    @Published var selected="" {didSet{UserDefaults.standard.set(selected,forKey:"profile")}}
    @Published var automatic=UserDefaults.standard.bool(forKey:"automatic") {didSet{UserDefaults.standard.set(automatic,forKey:"automatic")}}
    @Published var backgroundEnabled=UserDefaults.standard.bool(forKey:"backgroundEnabled") {didSet{UserDefaults.standard.set(backgroundEnabled,forKey:"backgroundEnabled")}}
    @Published var backgroundStatus="iOS chooses when background checks run."
    @Published var busy=false
    @Published var status="Choose the iCloud Drive folder used by the Mac bridge."
    @Published var lastSync=UserDefaults.standard.string(forKey:"lastSync") ?? "Never"
    private let health=HealthSync()
    private var lastSeen:String?
    init() {
        if let data=UserDefaults.standard.data(forKey:"folderBookmark") {
            var stale=false
            folder=try? URL(resolvingBookmarkData:data,options:[.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
        }
        profileNames=UserDefaults.standard.dictionary(forKey:namesKey) as? [String:String] ?? [:]
        recentImports=(try? ImportHistoryStore.read()) ?? []
        let saved=UserDefaults.standard.string(forKey:"profile") ?? ""
        refreshProfiles()
        if !saved.isEmpty && saved.allSatisfy({$0.isASCII && $0.isNumber}){selected=saved}
    }
    func choose(_ url:URL) {
        let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
        do {UserDefaults.standard.set(try url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil),forKey:"folderBookmark");folder=url;selected="";lastSeen=nil;profileNames=UserDefaults.standard.dictionary(forKey:namesKey) as? [String:String] ?? [:];refreshProfiles()}
        catch{status=error.localizedDescription}
    }
    func refreshProfiles() {
        guard !busy,let folder else{return}
        let access=folder.startAccessingSecurityScopedResource();defer{if access{folder.stopAccessingSecurityScopedResource()}}
        do {
            profiles=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).compactMap {url in
                guard url.pathExtension=="whealth",url.lastPathComponent.hasPrefix("profile-") else{return nil}
                let id=String(url.deletingPathExtension().lastPathComponent.dropFirst(8))
                return !id.isEmpty && id.allSatisfy(\.isNumber) ? id:nil
            }.sorted()
            refreshProfileNames()
            if !selected.isEmpty && !profiles.contains(selected) {status="Waiting for the selected profile’s iCloud file to become available."}
        }catch{status="The folder is unavailable. Open Files to download it, or select it again. " + error.localizedDescription}
    }
    private func refreshProfileNames() {
        guard !namesLoading,let folder else{return}
        namesLoading=true
        let ids=profiles, cached=profileNames
        Task {
            defer{namesLoading=false}
            let info=await Task.detached(priority:.utility){
                let access=folder.startAccessingSecurityScopedResource()
                defer{if access{folder.stopAccessingSecurityScopedResource()}}
                return Dictionary(uniqueKeysWithValues:ids.compactMap {id->(String,String)? in
                    guard let name=BridgeProfileInfo.displayName(in:folder,expectedID:id,cached:cached[id],readSnapshot:{try Self.read($0)}) else{return nil}
                    return (id,name)
                })
            }.value
            guard self.folder?.path==folder.path else{return}
            for (id,name) in info {profileNames[id]=name}
            UserDefaults.standard.set(profileNames,forKey:namesKey)
        }
    }
    private func recordImports(_ events:[BridgeImportEvent]) {
        do {
            let previous=try ImportHistoryStore.read()
            recentImports=BridgeImportHistory.adding(events,to:BridgeImportHistory.adding(recentImports,to:previous))
            try ImportHistoryStore.save(recentImports)
        }catch {
            recentImports=BridgeImportHistory.adding(events,to:recentImports)
            historyWarning="Recent import history could not be saved: \(error.localizedDescription)"
        }
    }
    private func fileURL()->URL? {guard let folder,!selected.isEmpty,selected.allSatisfy({$0.isASCII && $0.isNumber}) else{return nil};return folder.appendingPathComponent("profile-"+selected+".whealth")}
    func reloadRecentImports() {
        if let saved=try? ImportHistoryStore.read() {recentImports=BridgeImportHistory.adding(recentImports,to:saved)}
    }
    func poll() {
        guard !busy else{return}
        refreshProfiles()
        guard automatic else{return}
        guard health.hasWriteAccess else{status="Tap Sync to Apple Health first to grant permission.";return}
        guard let url=fileURL() else{return}
        let access=folder!.startAccessingSecurityScopedResource();defer{if access{folder!.stopAccessingSecurityScopedResource()}}
        guard let resource=try? url.resourceValues(forKeys:[.contentModificationDateKey,.fileSizeKey]) else{return}
        let identity=selected+"|"+String(describing:resource.contentModificationDate)+"|"+String(describing:resource.fileSize)
        guard identity != lastSeen else{return}
        sync(requestPermissions:false,identity:identity)
    }
    func sync(requestPermissions:Bool=true,identity:String?=nil) {
        guard !busy else{return}
        Task {_ = await performSync(requestPermissions:requestPermissions,identity:identity)}
    }
    private func performSync(requestPermissions:Bool,identity:String?=nil)async->Bool {
        guard !busy,let folder,let url=fileURL() else{return false}
        let profile=selected;busy=true;historyWarning=nil;status="Reading iCloud file…"
        let access=folder.startAccessingSecurityScopedResource()
        defer{if access{folder.stopAccessingSecurityScopedResource()};busy=false}
        do {
            try Task.checkCancellation()
            let snapshot=try await Task.detached(priority:.utility) {try Self.read(url)}.value
            try Task.checkCancellation()
            guard snapshot.profileID==profile else{throw SyncFailure("The file belongs to a different profile.")}
            if let name=snapshot.profileName,!name.isEmpty {
                profileNames[profile]=name
                UserDefaults.standard.set(profileNames,forKey:namesKey)
            }
            let key="revision."+profile,previous=(UserDefaults.standard.object(forKey:key) as? NSNumber)?.int64Value ?? 0
            guard snapshot.revision>=previous else{throw SyncFailure("iCloud has an older file. Wait for the current Mac export to arrive.")}
            if requestPermissions {try await health.authorize()}
            let result=try await health.sync(snapshot,progress:{[weak self] message in self?.status=message},didImport:{[weak self] events in self?.recordImports(events)})
            try Task.checkCancellation()
            status="Saved \(result.saved) · Already in Health \(result.matched) · Unchanged \(result.unchanged) · Not authorized \(result.denied) · Removed \(result.removed)"
            if let historyWarning{status+="\n"+historyWarning}
            lastSync=Date().formatted(date:.abbreviated,time:.shortened)
            UserDefaults.standard.set(lastSync,forKey:"lastSync")
            UserDefaults.standard.set(NSNumber(value:snapshot.revision),forKey:key)
            lastSeen=identity
            return true
        }catch is CancellationError {status="Sync paused by iOS. It will retry on a later check.";return false}
        catch{status=error.localizedDescription;return false}
    }
    func updateBackgroundSchedule(showStatus:Bool=true) {
        guard backgroundEnabled,!selected.isEmpty,folder != nil else{BackgroundSync.cancel();return}
        do {try BackgroundSync.schedule();if showStatus{backgroundStatus="Background check requested. iOS controls its timing."}}
        catch {backgroundStatus="Background checks unavailable: \(error.localizedDescription). You can still sync while the app is open."}
    }
    func runBackgroundSync()async->Bool {
        defer{updateBackgroundSchedule(showStatus:false)}
        guard backgroundEnabled,!busy else{return false}
        guard UIApplication.shared.isProtectedDataAvailable else {
            backgroundStatus="Waiting for an unlocked iPhone so existing Health entries can be checked."
            return false
        }
        guard health.hasWriteAccess else{backgroundStatus="Open the app and grant Apple Health access first.";return false}
        refreshProfiles()
        let success=await performSync(requestPermissions:false)
        backgroundStatus=success ? "Last background sync: \(Date().formatted(date:.abbreviated,time:.shortened))":"Background sync deferred. Open the app to check its status."
        return success
    }
    nonisolated static func read(_ url:URL)throws->HealthSnapshot {
        let values=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey,.isUbiquitousItemKey])
        guard values.isSymbolicLink != true else{throw ExchangeError.invalid}
        if values.isUbiquitousItem==true {try FileManager.default.startDownloadingUbiquitousItem(at:url)}
        var data:Data?,readError:Error?,coordinationError:NSError?
        NSFileCoordinator().coordinate(readingItemAt:url,options:[],error:&coordinationError) {path in
            do {
                let local=try path.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                guard local.isRegularFile==true,local.isSymbolicLink != true,(local.fileSize ?? Int.max)<=128*1024*1024 else{throw ExchangeError.invalid}
                data=try Data(contentsOf:path,options:.mappedIfSafe)
            }catch{readError=error}
        }
        if let error=coordinationError ?? readError as NSError? {throw error}
        guard let data,data.count<=128*1024*1024 else{throw ExchangeError.invalid}
        let snapshot=try JSONDecoder().decode(HealthSnapshot.self,from:data);try snapshot.validate();return snapshot
    }
    func remove() {
        guard !busy else{return};automatic=false;backgroundEnabled=false;BackgroundSync.cancel();busy=true
        Task {defer{busy=false};do{let n=try await health.removeAll();try ImportHistoryStore.clear();recentImports=[];status="Removed \(n) bridge-owned Health entries. Automatic sync is off.";lastSeen=nil}catch{status=error.localizedDescription}}
    }
    func removeDuplicates() {
        guard !busy else{return};busy=true;status="Checking bridge entries for duplicates…"
        Task { [self] in
            defer{busy=false}
            do {let n=try await health.removeDuplicates(){[weak self] in self?.status=$0};status="Removed \(n) duplicate bridge entries. Other apps’ entries were kept.";lastSeen=nil}
            catch{status=error.localizedDescription}
        }
    }
}
@main struct WithingsHealthBridgeApp:App {
    @StateObject private var model:SyncModel
    init() {
        let model=SyncModel()
        _model=StateObject(wrappedValue:model)
        BackgroundSync.register(model:model)
    }
    @Environment(\.scenePhase) private var scenePhase
    var body:some Scene {WindowGroup {MainView(model:model).onChange(of:scenePhase){_,phase in if phase == .active{model.reloadRecentImports();model.poll();model.updateBackgroundSchedule()}else if phase == .background{model.updateBackgroundSchedule()}}}}
}
struct MainView:View {
    @ObservedObject var model:SyncModel
    @State private var choosing=false
    @State private var confirmRemoval=false
    @State private var confirmDuplicates=false
    @Environment(\.scenePhase) private var scenePhase
    private let timer=Timer.publish(every:30,on:.main,in:.common).autoconnect()
    var body:some View {
        NavigationStack {
            Form {
                Section("iCloud Folder") {
                    Button(model.folder?.lastPathComponent ?? "Choose Folder"){choosing=true}.disabled(model.busy)
                    Picker("Your Withings Profile",selection:$model.selected) {
                        Text("Choose your profile").tag("")
                        if !model.selected.isEmpty && !model.profiles.contains(model.selected) {Text(model.profileLabel(model.selected)+" (waiting for iCloud)").tag(model.selected)}
                        ForEach(model.profiles,id:\.self){id in Text(model.profileLabel(id)).tag(id)}
                    }.disabled(model.busy)
                    if !model.selected.isEmpty {
                        Text("Profile number: \(model.selected)").font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !model.selected.isEmpty && model.profileNames[model.selected]==nil {
                        Text("Waiting for the profile name from iCloud. The profile number identifies your selection.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Select only your own profile. Apple Health belongs to the person using this iPhone.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Apple Health") {
                    Button("Sync to Apple Health"){model.sync()}.disabled(model.busy || model.selected.isEmpty)
                    Toggle("Sync while app is open",isOn:$model.automatic).disabled(model.selected.isEmpty || model.busy)
                    LabeledContent("Last Sync",value:model.lastSync)
                    NavigationLink {
                        RecentImportsView(events:model.selectedImports)
                    } label: {
                        VStack(alignment:.leading,spacing:4) {
                            Text("Last Imported Metric")
                            if let latest=model.selectedImports.first {
                                Text(latest.metric.displayName).font(.subheadline)
                                Text(latest.measuredAt.formatted(date:.abbreviated,time:.standard)).font(.footnote).foregroundStyle(.secondary)
                            } else {Text("No imports recorded yet").font(.footnote).foregroundStyle(.secondary)}
                        }
                    }
                    if model.busy {ProgressView().frame(maxWidth:.infinity)}
                    Text(model.status).font(.footnote).textSelection(.enabled)
                }
                Section("Background Sync") {
                    Toggle("Sync in Background",isOn:$model.backgroundEnabled).disabled(model.busy || model.selected.isEmpty)
                    Text(model.backgroundStatus).font(.footnote).foregroundStyle(.secondary)
                    Text("Background checks are scheduled by iOS, not at a fixed interval. Checks may be delayed while the phone is locked because duplicate matching needs access to Health data.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("Only verified Withings-device measurements are exported. Grant read access to the supported Health types so existing entries can be matched. Read permission cannot be verified by the app. This app never edits or deletes entries made by other apps.")
                    Text("The Mac publishes to your chosen folder. iCloud transfer is handled by Apple. No developer server, analytics or advertising is used. Optional background checks are controlled by iOS. Open the app whenever you need an immediate sync.")
                }.font(.footnote).foregroundStyle(.secondary)
                Section {
                    Button("Remove Duplicate Bridge Entries"){confirmDuplicates=true}.disabled(model.busy)
                    Button("Remove This App’s Health Entries",role:.destructive){confirmRemoval=true}.disabled(model.busy)
                }
            }.navigationTitle("Health Bridge")
            .fileImporter(isPresented:$choosing,allowedContentTypes:[.folder]) {result in
                switch result {case .success(let url):model.choose(url);case .failure(let error):model.status=error.localizedDescription}
            }
            .confirmationDialog("Remove all Health entries written by this app?",isPresented:$confirmRemoval,titleVisibility:.visible) {
                Button("Remove Bridge Entries",role:.destructive){model.remove()}
            }
            .confirmationDialog("Remove only bridge entries that duplicate another Health entry?",isPresented:$confirmDuplicates,titleVisibility:.visible) {
                Button("Remove Duplicates",role:.destructive){model.removeDuplicates()}
            } message: {Text("Grant Health read access first. Existing entries from Apple, Withings and other apps are always kept.")}
            .onChange(of:model.backgroundEnabled){_,_ in model.updateBackgroundSchedule()}
            .onChange(of:model.selected){_,_ in model.refreshProfiles();model.updateBackgroundSchedule()}
            .onReceive(timer){_ in if scenePhase == .active{model.poll()}}
        }
    }
}

struct RecentImportsView:View {
    let events:[BridgeImportEvent]
    var body:some View {
        List {
            Section {
                if events.isEmpty {Text("New measurements saved to Apple Health will appear here.").foregroundStyle(.secondary)}
                ForEach(events) {event in
                    VStack(alignment:.leading,spacing:4) {
                        Text(event.metric.displayName)
                        Text(event.measuredAt.formatted(date:.abbreviated,time:.standard)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } header: {Text("Recent Imports")} footer: {
                Text("Up to 50 newest imported measurements, ordered by measurement time. Dates shown are when the measurements were taken. Entries already in Health are skipped and are not new imports.")
            }
        }.navigationTitle("Recent Imports")
    }
}
