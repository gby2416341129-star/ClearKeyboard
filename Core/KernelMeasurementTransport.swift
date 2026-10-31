import Foundation
#if canImport(Security)
import Security
#endif

/// A bounded local numeric-only measurement channel, separate from settings.
/// A successful write is never treated as proof of cross-process access.
final class KernelMeasurementTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var readStatus: Int32?
    private var writeStatus: Int32?
    private var selectedGroup: String?
    private let service = "com.clearkeyboard.kernel.measurement.v3"
    #if canImport(Security)
    private lazy var groups: [String] = {
        var probe: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service+".prefix", kSecAttrAccount as String:"installation",
            kSecReturnAttributes as String:true]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(probe as CFDictionary,&result)
        if status == errSecItemNotFound {
            probe[kSecValueData as String]=Data([0])
            probe[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status=SecItemAdd(probe as CFDictionary,&result)
        }
        guard status == errSecSuccess,let attrs=result as? [String:Any],
              let actual=attrs[kSecAttrAccessGroup as String] as? String,let dot=actual.firstIndex(of:".") else{return []}
        let prefix=String(actual[...dot])
        let configured=Bundle.main.object(forInfoDictionaryKey:"ClearSharedKeychainGroup") as? String
        var candidates:[String]=[]
        if var configured,!configured.isEmpty,!configured.contains("$(") {
            let parts=configured.split(separator:".")
            if parts.count>2,parts[0].count==10,parts[0].allSatisfy({$0.isUppercase || $0.isNumber}) {configured=parts.dropFirst().joined(separator:".")}
            candidates.append(configured.hasPrefix(prefix) ? configured:prefix+configured)
        }
        candidates.append(actual)
        var seen=Set<String>();return candidates.filter{seen.insert($0).inserted}
    }()
    private func query(_ account:String)->[String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
         kSecAttrAccount as String:account,kSecAttrSynchronizable as String:false]
    }
    #endif
    func read(_ account:String)->Data? {
        lock.lock();defer{lock.unlock()}
        #if canImport(Security)
        var q=query(account);q[kSecReturnData as String]=true;q[kSecReturnAttributes as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitAll
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result);readStatus=status
        guard status == errSecSuccess,let rows=result as? [[String:Any]] else{return nil}
        let row=rows.max{($0[kSecAttrModificationDate as String] as? Date ?? .distantPast)<($1[kSecAttrModificationDate as String] as? Date ?? .distantPast)}
        guard let row,let data=row[kSecValueData as String] as? Data,data.count<=262144 else{return nil}
        selectedGroup=row[kSecAttrAccessGroup as String] as? String
        return data
        #else
        return nil
        #endif
    }
    @discardableResult func write(_ data:Data,account:String)->Bool {
        guard data.count<=262144 else{return false}
        lock.lock();defer{lock.unlock()}
        #if canImport(Security)
        // Probe only installation-authorized groups; Security enforces access.
        for group in groups {
            var q=query(account);q[kSecAttrAccessGroup as String]=group
            let values:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            var add=q;values.forEach{add[$0.key]=$0.value}
            var status=SecItemAdd(add as CFDictionary,nil)
            if status == errSecDuplicateItem {status=SecItemUpdate(q as CFDictionary,values as CFDictionary)}
            writeStatus=status
            if status == errSecSuccess {selectedGroup=group;return true}
        }
        #endif
        return false
    }
    var diagnostics:[String:Any] {
        lock.lock();defer{lock.unlock()};var value:[String:Any]=["service":service,"cross_process_access":"requires matching keyboard receipt"]
        if let readStatus{value["read_status"]=readStatus};if let writeStatus{value["write_status"]=writeStatus};if let selectedGroup{value["access_group"]=selectedGroup}
        return value
    }
}
