import Foundation
import CryptoKit
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(Security)
import Security
#endif

struct InstallationLearningTransition {
    let ready:Bool
    let previous:String?
    let current:String?
    let adoptedLegacyEpoch:Bool
}
protocol InstallationLearningMigration {
    var installationStorageReady:Bool {get}
    func migrateInstallationLearning()->InstallationLearningTransition
}

/// Private-container continuity decides whether legacy recovery is allowed.
/// Shared containers and Keychain are recovery sources, never install proof.
enum InstallationLifecycle {
    struct Group {let identifier:String;let root:URL}
    struct Snapshot:Codable {
        let owner:String
        let ownerToken:String
        let identifier:String
        let bundleAnchor:String
        let legacy:Bool
        let continuity:Bool
        let ready:Bool
        var priorIdentifiers:[String]?=nil
        var keyPrefix:String {"com.clearkeyboard.install.v1."+ownerToken+"."+identifier+"."}
    }
    private static let lock=NSRecursiveLock()
    private static var cached:Snapshot?
    private static var firstDecision:String?
    private static var proxies:[String:InstallationDefaults]=[:]
    private static var migratingDomains=Set<String>()
    private static let markerName="installation-v1.json"
    private static let pending=UUID().uuidString.lowercased()

    static func prepare(refresh:Bool=false)->Snapshot {
        lock.lock();defer{lock.unlock()}
        if !refresh,let cached,cached.ready{return cached}
        let identity=identity()
        let owner=identity.0,token=hash(owner),anchor=identity.1
        let groups=authorizedGroups()
        let marker=privateRoot().appendingPathComponent(markerName)
        do {
            let old:Snapshot?
            do {
                let decoded=try JSONDecoder().decode(Snapshot.self,from:Data(contentsOf:marker))
                guard valid(decoded,owner:owner,token:token) else{throw NSError(domain:NSCocoaErrorDomain,code:NSFileReadCorruptFileError)}
                old=decoded
            }
            catch let error as NSError where error.domain==NSCocoaErrorDomain && error.code==NSFileReadNoSuchFileError {old=nil}
            catch {throw error} // Protected/corrupt state is not a fresh-install signal.
            let evidence=try hasPrivateLegacyEvidence()
            let chosen=try lockedGroups(groups.sorted{$0.identifier<$1.identifier},index:0,owner:token) {() throws->Snapshot in
                var records:[Snapshot]=[]
                for group in groups {
                    let ledger=ownerRoot(group.root,owner:token).appendingPathComponent("rendezvous.json")
                    do {
                        let value=try JSONDecoder().decode(Snapshot.self,from:Data(contentsOf:ledger))
                        if valid(value,owner:owner,token:token),value.bundleAnchor==anchor {records.append(value)}
                    } catch let error as NSError where error.domain==NSCocoaErrorDomain && error.code==NSFileReadNoSuchFileError {}
                    catch {throw error}
                }
                if let value=readRendezvous(owner:owner,token:token,anchor:anchor){records.append(value)}
                let partner=records.sorted {
                    if $0.continuity != $1.continuity{return $0.continuity}
                    return $0.identifier<$1.identifier
                }.first
                let validOld=old.flatMap{$0.owner==owner && $0.ready ? $0:nil}
                let ownContinuity=validOld.map{$0.continuity || $0.bundleAnchor != anchor} ?? evidence
                let identifier:String
                // The first ledger for this bundle instance is the rendezvous.
                // A later trusted legacy peer imports into it; it never splits
                // already-created stores and clipboard paths into another ID.
                if let partner {identifier=partner.identifier}
                else if let validOld {identifier=validOld.identifier}
                else if evidence {identifier="legacy-"+String(token.prefix(32))}
                else {identifier=String(hash(owner+"|"+anchor).prefix(32))}
                var result=Snapshot(owner:owner,ownerToken:token,identifier:identifier,bundleAnchor:anchor,
                    legacy:(validOld?.legacy ?? false) || evidence || (partner?.legacy ?? false),continuity:ownContinuity || (partner?.continuity ?? false),ready:true)
                var prior=Set((validOld?.priorIdentifiers ?? [])+(partner?.priorIdentifiers ?? []))
                if let validOld,validOld.identifier != identifier {prior.insert(validOld.identifier)}
                prior.remove(identifier);result.priorIdentifiers=prior.isEmpty ? nil:prior.sorted()
                // Commit private proof before exposing any recovery source.
                try FileManager.default.createDirectory(at:marker.deletingLastPathComponent(),withIntermediateDirectories:true)
                try JSONEncoder().encode(result).write(to:marker,options:.atomic)
                for group in groups {
                    let ledger=ownerRoot(group.root,owner:token).appendingPathComponent("rendezvous.json")
                    try FileManager.default.createDirectory(at:ledger.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try JSONEncoder().encode(result).write(to:ledger,options:.atomic)
                }
                writeRendezvous(result)
                return result
            }
            let oldPolicy=cached.map{policy($0)}
            cached=chosen
            if firstDecision==nil {firstDecision=old != nil ? "existing":evidence ? "legacy-upgrade":"fresh"}
            if oldPolicy != policy(chosen) {
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFNotificationName(rawValue:"com.clearkeyboard.appearance.changed.v1" as CFString),nil,nil,true)
            }
            return chosen
        } catch {
            // Fail closed when protected data or a shared lock is unavailable.
            // A temporary empty namespace cannot recover or erase old data.
            let value=Snapshot(owner:owner,ownerToken:token,identifier:"pending-"+pending,bundleAnchor:anchor,
                               legacy:false,continuity:false,ready:false)
            cached=value;return value
        }
    }
    static func scopedDefaults(_ backing:UserDefaults,domain:String)->UserDefaults {
        let snapshot=ensureDefaults(backing,domain:domain)
        lock.lock();defer{lock.unlock()}
        let key=domain+"|"+snapshot.ownerToken
        if let proxy=proxies[key]{return proxy}
        let proxy=InstallationDefaults.make(backing:backing,domain:domain)
        proxies[key]=proxy;return proxy
    }
    fileprivate static func ensureDefaults(_ backing:UserDefaults,domain:String)->Snapshot {
        let snapshot=prepare()
        guard snapshot.ready else{return snapshot}
        let marker=snapshot.keyPrefix+"migration.defaults."+hash(policy(snapshot))
        if backing.bool(forKey:marker){return snapshot}
        lock.lock();defer{lock.unlock()}
        let key=domain+"|"+policy(snapshot)
        guard migratingDomains.insert(key).inserted else{return snapshot}
        defer{migratingDomains.remove(key)}
        _ = try? lockedGroups(authorizedGroups().sorted{$0.identifier<$1.identifier},index:0,owner:snapshot.ownerToken) {
            migrateRawDefaults(backing,snapshot:snapshot)
        }
        return snapshot
    }
    static func policy(_ value:Snapshot)->String {value.identifier+"|"+String(value.legacy)+"|"+(value.priorIdentifiers ?? []).joined(separator:",")}
    static func priorRoots(_ raw:URL,snapshot:Snapshot)->[URL] {
        (snapshot.priorIdentifiers ?? []).map{ownerRoot(raw,owner:snapshot.ownerToken).appendingPathComponent("data/"+$0,isDirectory:true)}
    }
    static func priorServices(_ base:String,snapshot:Snapshot)->[String] {
        (snapshot.priorIdentifiers ?? []).map{base+".install."+snapshot.ownerToken+"."+$0}
    }
    static func sharedRoot(_ raw:URL,snapshot:Snapshot?=nil)->URL {
        let value=snapshot ?? prepare()
        return ownerRoot(raw,owner:value.ownerToken).appendingPathComponent("data/"+value.identifier,isDirectory:true)
    }
    static func service(_ base:String,snapshot:Snapshot?=nil)->String {
        let value=snapshot ?? prepare()
        return base+".install."+value.ownerToken+"."+value.identifier
    }
    static func legacyMigrationAllowed()->Bool {let value=prepare();return value.ready && value.legacy}
    static var diagnostics:[String:String] {
        let value=prepare()
        lock.lock();defer{lock.unlock()}
        return ["schema":"clear-installation-lifecycle/1","decision":firstDecision ?? "deferred",
                "owner":value.owner,"installation":value.identifier,"bundle_anchor":value.bundleAnchor,
                "private_marker_ready":String(value.ready),"legacy_recovery_allowed":String(value.legacy),
                "legacy_unowned_storage":value.legacy ? "trusted one-time upgrade migration":"isolated",
                "physical_legacy_deletion":"none","cleanup_timing":"before recovery on new process startup, not at uninstall"]
    }
    static func privateDefaults()->UserDefaults {scopedDefaults(.standard,domain:"standard")}
    static func rawGroups()->[Group] {authorizedGroups()}
    static func legacyFileRoot(_ current:URL)->URL? {
        let value=prepare()
        return authorizedGroups().first{sharedRoot($0.root,snapshot:value)==current}?.root
    }
    private static func migrateRawDefaults(_ defaults:UserDefaults,snapshot:Snapshot) {
        let marker=snapshot.keyPrefix+"migration.defaults."+hash(policy(snapshot))
        guard !defaults.bool(forKey:marker) else{return}
        _ = defaults.synchronize()
        let sourcePrefixes=(snapshot.legacy ? [""]:[])+(snapshot.priorIdentifiers ?? []).map{"com.clearkeyboard.install.v1."+snapshot.ownerToken+"."+$0+"."}
        var factory=KeyboardSettings();factory.sanitize()
        for prefix in sourcePrefixes {
            for (physical,value) in defaults.dictionaryRepresentation() where physical.hasPrefix(prefix) {
                let key=String(physical.dropFirst(prefix.count))
                guard legacyKey(key),!key.hasPrefix("clear.learning."),!key.hasPrefix("clear.learned"),key != "clear.choices.v2",key != "clear.numbers.v1" else{continue}
                let target=snapshot.keyPrefix+key
                var canCopy=defaults.object(forKey:target)==nil
                if key=="clear.settings.v1",let old=defaults.data(forKey:target),var current=try? JSONDecoder().decode(KeyboardSettings.self,from:old) {
                    current.sanitize();if current==factory {canCopy=true}
                }
                if canCopy {defaults.set(value,forKey:target)}
            }
        }
        defaults.set(true,forKey:marker)
        _ = defaults.synchronize()
    }
    fileprivate static func migrateLearning(_ backing:UserDefaults,domain:String)->InstallationLearningTransition {
        // Finish generic bootstrap first, then release Lifecycle.lock before
        // taking the exact same learning lock used by clear/save.
        let snapshot=ensureDefaults(backing,domain:domain)
        let prefix=snapshot.keyPrefix
        let before=backing.string(forKey:prefix+"clear.learned.epoch")
        let unavailable=InstallationLearningTransition(ready:false,previous:before,current:before,adoptedLegacyEpoch:false)
        guard snapshot.ready else{return unavailable}
        let group=authorizedGroups().first{$0.identifier==domain}
        let url=group.map{sharedRoot($0.root,snapshot:snapshot).appendingPathComponent("Learning/learning.lock")}
        let result=LearningStore.performInstallationMigration(lockURL:url) {()->InstallationLearningTransition in
            _ = backing.synchronize()
            let epochKey=prefix+"clear.learned.epoch"
            let previous=backing.string(forKey:epochKey)
            var epoch=previous
            var combined=memory(backing,prefix:prefix)
            var changed=false
            let marker=prefix+"migration.learning."+hash(policy(snapshot))
            var sources:[(UserDefaults,String)]=[]
            if !backing.bool(forKey:marker) {
                if snapshot.legacy {
                    sources.append((backing,""))
                    if domain != "standard" {sources.append((.standard,""))}
                }
                for old in snapshot.priorIdentifiers ?? [] {
                    sources.append((backing,"com.clearkeyboard.install.v1."+snapshot.ownerToken+"."+old+"."))
                }
            }
            // Current-install private learning can join the group after Full
            // Access is granted. A different explicit epoch remains authoritative.
            if domain != "standard" {sources.append((.standard,prefix))}
            for (source,sourcePrefix) in sources {
                _ = source.synchronize()
                let sourceEpoch=source.string(forKey:sourcePrefix+"clear.learned.epoch")
                let sourceKey=sourcePrefix+"clear.learning.v3."+(sourceEpoch ?? "legacy")
                let exists=source.object(forKey:sourcePrefix+"clear.learned.epoch") != nil || source.object(forKey:sourceKey) != nil ||
                    (sourceEpoch==nil && ["clear.learned.v1","clear.choices.v2","clear.numbers.v1"].contains{source.object(forKey:sourcePrefix+$0) != nil})
                guard exists else{continue}
                // nil is the initial namespace, never a clear epoch. Only a
                // user clear rotates an existing active epoch.
                if epoch==nil {epoch=sourceEpoch}
                guard epoch==sourceEpoch else{continue}
                combined=combined.merging(memory(source,prefix:sourcePrefix));changed=true
            }
            if changed,let data=try? JSONEncoder().encode(combined) {
                backing.set(data,forKey:prefix+"clear.learning.v3."+(epoch ?? "legacy"))
                if let epoch {backing.set(epoch,forKey:epochKey)}
            }
            backing.set(true,forKey:marker);_ = backing.synchronize()
            return InstallationLearningTransition(ready:true,previous:previous,current:epoch,
                adoptedLegacyEpoch:previous==nil && epoch != nil)
        }
        return result ?? unavailable
    }
    private static func memory(_ defaults:UserDefaults,prefix:String)->LearningMemory {
        let explicitEpoch=defaults.string(forKey:prefix+"clear.learned.epoch")
        let epoch=explicitEpoch ?? "legacy"
        if let data=defaults.data(forKey:prefix+"clear.learning.v3."+epoch),let value=try? JSONDecoder().decode(LearningMemory.self,from:data){return value}
        guard explicitEpoch==nil else{return LearningMemory()}
        return LearningMemory(learned:defaults.dictionary(forKey:prefix+"clear.learned.v1") as? [String:Int] ?? [:],
            personal:defaults.data(forKey:prefix+"clear.choices.v2").flatMap{try? JSONDecoder().decode(PersonalLexicon.self,from:$0)} ?? PersonalLexicon(),
            numbers:defaults.data(forKey:prefix+"clear.numbers.v1").flatMap{try? JSONDecoder().decode(NumericLexicon.self,from:$0)} ?? NumericLexicon())
    }
    private static func legacyKey(_ key:String)->Bool {
        let exact:Set<String>=["clear.settings.v1","clear.learned.epoch","clear.learned.v1","clear.choices.v2","clear.numbers.v1","clear.toolbar.offset.v1","clear.candidate.explicitPreferences.v1","clear.clipboard.consumedSuggestions.v1"]
        return exact.contains(key) || ["clear.learning.v3.","clear.shared.migration.v1.","clear.shared.learning-migration.v2.","clear.clipboard.migration.v1.","clear.clipboard.observedChangeCount.","clear.clipboard.capturedChangeCount."].contains{key.hasPrefix($0)}
    }
    private static func hasPrivateLegacyEvidence() throws->Bool {
        let file=FileManager.default.urls(for:.libraryDirectory,in:.userDomainMask).first?
            .appendingPathComponent("Preferences/"+(Bundle.main.bundleIdentifier ?? "")+".plist")
        if let file,FileManager.default.fileExists(atPath:file.path) {_ = try Data(contentsOf:file)}
        let domain=Bundle.main.bundleIdentifier.flatMap{UserDefaults.standard.persistentDomain(forName:$0)} ?? [:]
        if domain.keys.contains(where:legacyKey){return true}
        let oldRoot=(FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Application Support")).appendingPathComponent("Clear")
        return ["clipboard.json","common-phrases.json"].contains {FileManager.default.fileExists(atPath:oldRoot.appendingPathComponent($0).path)}
    }
    private static func privateRoot()->URL {
        (FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("ClearInstallation",isDirectory:true)
    }
    private static func identity()->(String,String) {
        var url=Bundle.main.bundleURL
        if url.pathExtension=="appex" {let parent=url.deletingLastPathComponent().deletingLastPathComponent();if parent.pathExtension=="app" {url=parent}}
        url=url.resolvingSymlinksInPath()
        let owner=Bundle(url:url)?.bundleIdentifier ?? Bundle.main.bundleIdentifier ?? "com.clearkeyboard.unknown"
        let attributes=try? FileManager.default.attributesOfItem(atPath:url.path)
        let created=(attributes?[.creationDate] as? Date)?.timeIntervalSince1970.description ?? "unavailable"
        let inode=(attributes?[.systemFileNumber] as? NSNumber)?.stringValue ?? "unavailable"
        // This anchor only joins App/extension in the current bundle instance.
        // Private marker continuity, not this changing path, preserves upgrades.
        return(owner,hash(url.path+"|"+created+"|"+inode))
    }
    private static func hash(_ value:String)->String {SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined()}
    private static func valid(_ value:Snapshot,owner:String,token:String)->Bool {
        func generation(_ text:String)->Bool {
            (16...100).contains(text.utf8.count) && text.utf8.allSatisfy{(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0==45}
        }
        guard value.ready,value.owner==owner,value.ownerToken==token,generation(value.identifier) else{return false}
        guard (value.priorIdentifiers ?? []).allSatisfy(generation),value.bundleAnchor.utf8.count==64 else{return false}
        return value.bundleAnchor.allSatisfy{$0.isHexDigit && $0.isASCII}
    }
    private static func ownerRoot(_ raw:URL,owner:String)->URL {raw.appendingPathComponent("ClearKeyboard-Installations/v1/"+owner,isDirectory:true)}
    private static func lockedGroups<T>(_ groups:[Group],index:Int,owner:String,_ body:() throws->T) throws->T {
        if index>=groups.count{return try body()}
        return try installFileLock(ownerRoot(groups[index].root,owner:owner).appendingPathComponent("installation.lock")) {
            try lockedGroups(groups,index:index+1,owner:owner,body)
        }
    }
    private static func installFileLock<T>(_ url:URL,_ body:() throws->T) throws->T {
        // Intentionally independent of SharedFileLock.local: learning/clipboard
        // holders may access defaults while an installation is being refreshed.
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let descriptor=open(url.path,O_CREAT|O_RDWR,S_IRUSR|S_IWUSR)
        guard descriptor>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        defer{close(descriptor)}
        while flock(descriptor,LOCK_EX) != 0 {if errno != EINTR{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}}
        defer{_ = flock(descriptor,LOCK_UN)}
        return try body()
    }
    private static func authorizedGroups()->[Group] {
        var candidates=[Bundle.main.object(forInfoDictionaryKey:"ClearAppGroup") as? String].compactMap{$0}
        if let url=Bundle.main.url(forResource:"embedded",withExtension:"mobileprovision"),let bytes=try? Data(contentsOf:url),bytes.count<2_000_000,
           let begin=bytes.range(of:Data("<plist".utf8)),let end=bytes.range(of:Data("</plist>".utf8),in:begin.lowerBound..<bytes.endIndex),
           let plist=try? PropertyListSerialization.propertyList(from:bytes.subdata(in:begin.lowerBound..<end.upperBound),options:[],format:nil) as? [String:Any],
           let entitlements=plist["Entitlements"] as? [String:Any] {candidates += entitlements["com.apple.security.application-groups"] as? [String] ?? []}
        var seen=Set<String>()
        #if canImport(Darwin)
        return candidates.compactMap {name in
            guard !name.contains("$("),seen.insert(name).inserted,let root=FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:name) else{return nil}
            return Group(identifier:name,root:root)
        }
        #else
        return []
        #endif
    }
    #if canImport(Security)
    private static func rendezvousQuery(_ token:String,_ anchor:String)->[String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.clearkeyboard.installation.rendezvous.v1."+token,
         kSecAttrAccount as String:anchor,kSecAttrSynchronizable as String:false]
    }
    private static func readRendezvous(owner:String,token:String,anchor:String)->Snapshot? {
        var query=rendezvousQuery(token,anchor);query[kSecMatchLimit as String]=kSecMatchLimitAll
        query[kSecReturnData as String]=true;query[kSecReturnAttributes as String]=true
        var result:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,let rows=result as? [[String:Any]] else{return nil}
        return rows.compactMap {row->Snapshot? in
            guard let data=row[kSecValueData as String] as? Data,data.count<8192,
                  let value=try? JSONDecoder().decode(Snapshot.self,from:data),valid(value,owner:owner,token:token),value.bundleAnchor==anchor else{return nil}
            return value
        }.sorted {if $0.continuity != $1.continuity{return $0.continuity};return $0.identifier<$1.identifier}.first
    }
    private static func writeRendezvous(_ value:Snapshot) {
        guard let data=try? JSONEncoder().encode(value) else{return}
        var groups:[String?]=[]
        if let raw=Bundle.main.object(forInfoDictionaryKey:"ClearSharedKeychainGroup") as? String,!raw.isEmpty,!raw.contains("$(") {
            var configured=raw
            let pieces=configured.split(separator:".")
            if pieces.count>2,pieces[0].count==10,pieces[0].allSatisfy({$0.isUppercase || $0.isNumber}) {configured=pieces.dropFirst().joined(separator:".")}
            var probe:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.clearkeyboard.installation.prefix.v1."+value.ownerToken,
                kSecAttrAccount as String:"prefix",kSecReturnAttributes as String:true]
            var result:CFTypeRef?
            var status=SecItemCopyMatching(probe as CFDictionary,&result)
            if status==errSecItemNotFound {probe[kSecValueData as String]=Data([0]);probe[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;status=SecItemAdd(probe as CFDictionary,&result)}
            if status==errSecSuccess,let attrs=result as? [String:Any],let actual=attrs[kSecAttrAccessGroup as String] as? String,let dot=actual.firstIndex(of:".") {
                groups.append(String(actual[...dot])+configured)
            }
        }
        groups.append(nil)
        for group in groups {
            var query=rendezvousQuery(value.ownerToken,value.bundleAnchor)
            if let group {query[kSecAttrAccessGroup as String]=group}
            var add=query;add[kSecValueData as String]=data;add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status=SecItemAdd(add as CFDictionary,nil)
            if status==errSecDuplicateItem {SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary);return}
            if status==errSecSuccess{return}
        }
    }
    #else
    private static func readRendezvous(owner:String,token:String,anchor:String)->Snapshot? {nil}
    private static func writeRendezvous(_ value:Snapshot) {}
    #endif
}

/// Map every app-owned logical preference key to the installation namespace.
/// Forward typed APIs explicitly: Foundation need not implement them via object().
private final class InstallationDefaults:UserDefaults,InstallationLearningMigration {
    private var storage:UserDefaults?
    private var domain=""
    static func make(backing:UserDefaults,domain:String)->InstallationDefaults {
        let proxy=InstallationDefaults()
        proxy.storage=backing;proxy.domain=domain
        return proxy
    }
    private func mapped(_ key:String)->String {key.hasPrefix("clear.") ? InstallationLifecycle.prepare().keyPrefix+key:key}
    private var available:Bool {
        guard let storage else{return false}
        return InstallationLifecycle.ensureDefaults(storage,domain:domain).ready
    }
    var installationStorageReady:Bool {available}
    func migrateInstallationLearning()->InstallationLearningTransition {
        guard let storage else{return InstallationLearningTransition(ready:false,previous:nil,current:nil,adoptedLegacyEpoch:false)}
        return InstallationLifecycle.migrateLearning(storage,domain:domain)
    }
    override func object(forKey key:String)->Any? {available ? storage?.object(forKey:mapped(key)):nil}
    override func set(_ value:Any?,forKey key:String) {if available {storage?.set(value,forKey:mapped(key))}}
    override func removeObject(forKey key:String) {if available {storage?.removeObject(forKey:mapped(key))}}
    override func string(forKey key:String)->String? {available ? storage?.string(forKey:mapped(key)):nil}
    override func array(forKey key:String)->[Any]? {available ? storage?.array(forKey:mapped(key)):nil}
    override func dictionary(forKey key:String)->[String:Any]? {available ? storage?.dictionary(forKey:mapped(key)):nil}
    override func data(forKey key:String)->Data? {available ? storage?.data(forKey:mapped(key)):nil}
    override func stringArray(forKey key:String)->[String]? {available ? storage?.stringArray(forKey:mapped(key)):nil}
    override func integer(forKey key:String)->Int {available ? storage?.integer(forKey:mapped(key)) ?? 0:0}
    override func float(forKey key:String)->Float {available ? storage?.float(forKey:mapped(key)) ?? 0:0}
    override func double(forKey key:String)->Double {available ? storage?.double(forKey:mapped(key)) ?? 0:0}
    override func bool(forKey key:String)->Bool {available && (storage?.bool(forKey:mapped(key)) ?? false)}
    override func url(forKey key:String)->URL? {available ? storage?.url(forKey:mapped(key)):nil}
    override func set(_ value:Int,forKey key:String) {if available {storage?.set(value,forKey:mapped(key))}}
    override func set(_ value:Float,forKey key:String) {if available {storage?.set(value,forKey:mapped(key))}}
    override func set(_ value:Double,forKey key:String) {if available {storage?.set(value,forKey:mapped(key))}}
    override func set(_ value:Bool,forKey key:String) {if available {storage?.set(value,forKey:mapped(key))}}
    override func set(_ value:URL?,forKey key:String) {if available {storage?.set(value,forKey:mapped(key))}}
    override func register(defaults values:[String:Any]) {
        guard available else{return}
        var mappedValues:[String:Any]=[:]
        for (key,value) in values {mappedValues[mapped(key)]=value}
        storage?.register(defaults:mappedValues)
    }
    override func dictionaryRepresentation()->[String:Any] {
        guard available,let backing=storage else{return [:]}
        let prefix=InstallationLifecycle.prepare().keyPrefix
        var result:[String:Any]=[:]
        for (key,value) in backing.dictionaryRepresentation() where key.hasPrefix(prefix) {result[String(key.dropFirst(prefix.count))]=value}
        return result
    }
    override func synchronize()->Bool {storage?.synchronize() ?? false}
    override func setVolatileDomain(_ values:[String:Any],forName name:String) {
        guard storage != nil else {super.setVolatileDomain(values,forName:name);return}
        guard available,let backing=storage else{return}
        let prefix=InstallationLifecycle.prepare().keyPrefix
        var combined=backing.volatileDomain(forName:name).filter{!$0.key.hasPrefix(prefix)}
        for (key,value) in values {combined[mapped(key)]=value}
        backing.setVolatileDomain(combined,forName:name)
    }
    override func volatileDomain(forName name:String)->[String:Any] {
        guard available,let backing=storage else{return [:]}
        let prefix=InstallationLifecycle.prepare().keyPrefix
        var result:[String:Any]=[:]
        for (key,value) in backing.volatileDomain(forName:name) where key.hasPrefix(prefix) {result[String(key.dropFirst(prefix.count))]=value}
        return result
    }
    override func removeVolatileDomain(forName name:String) {
        guard available,let backing=storage else{return}
        let prefix=InstallationLifecycle.prepare().keyPrefix
        backing.setVolatileDomain(backing.volatileDomain(forName:name).filter{!$0.key.hasPrefix(prefix)},forName:name)
    }
}
