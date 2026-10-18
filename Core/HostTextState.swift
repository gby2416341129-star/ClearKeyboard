import Foundation

public struct HostTextSnapshot: Equatable {
    public var before: String
    public var after: String
    public var selected: String
    public var document: String
    public var available: Bool
    public init(before: String = "", after: String = "", selected: String = "", document: String = "disconnected", available: Bool = true) {
        self.before = before; self.after = after; self.selected = selected; self.document = document; self.available = available
    }
}

/// The keyboard's edit ledger. Proxy reads occur at host notifications and commit
/// validation, not on every getter used by a key or a candidate render.
public struct HostTextState {
    public enum Reconciliation: Equatable { case ownEdit, externalEdit, unavailable }
    public private(set) var snapshot: HostTextSnapshot
    private var acknowledged: HostTextSnapshot
    private var pending: [(HostTextSnapshot, Double)] = []
    private var marked = ""
    public init(_ snapshot: HostTextSnapshot = HostTextSnapshot()) { self.snapshot = snapshot; acknowledged = snapshot }
    public func hasPendingEdits(now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        pending.contains { now - $0.1 <= 1 }
    }
    public var hasMarkedText: Bool { !marked.isEmpty }
    private func isMarkedBoundary(_ actual: HostTextSnapshot) -> Bool {
        guard !marked.isEmpty, snapshot.before.hasSuffix(marked), actual.selected.isEmpty else { return false }
        var boundary = snapshot; boundary.before.removeLast(marked.count)
        return Self.equivalent(boundary, actual)
    }
    private static func equivalent(_ expected: HostTextSnapshot, _ actual: HostTextSnapshot) -> Bool {
        guard expected.document == actual.document, expected.selected == actual.selected else { return false }
        // Hosts may return a bounded context window. Short prefixes must still
        // compare exactly, so moving a caret back to an earlier letter is detected.
        func bounded(_ a: String, _ b: String, suffix: Bool) -> Bool {
            if a == b { return true }
            guard min(a.count, b.count) >= 32 else { return false }
            return suffix ? (a.hasSuffix(b) || b.hasSuffix(a)) : (a.hasPrefix(b) || b.hasPrefix(a))
        }
        return bounded(expected.before, actual.before, suffix: true) && bounded(expected.after, actual.after, suffix: false)
    }
    private mutating func remember(now: Double) {
        snapshot.before = String(snapshot.before.suffix(4_096)); snapshot.after = String(snapshot.after.prefix(4_096))
        pending.removeAll { now - $0.1 > 1 }
        pending.append((snapshot, now)); if pending.count > 64 { pending.removeFirst(pending.count - 64) }
    }
    public mutating func insert(_ text: String, now: Double = ProcessInfo.processInfo.systemUptime) {
        snapshot.before += text; snapshot.selected = ""; marked = ""; remember(now: now)
    }
    public mutating func setMarked(_ text: String, now: Double = ProcessInfo.processInfo.systemUptime) {
        if !marked.isEmpty, snapshot.before.hasSuffix(marked) { snapshot.before.removeLast(marked.count) }
        snapshot.before += text; snapshot.selected = ""; marked = text; remember(now: now)
    }
    public mutating func unmark() { marked = "" }
    public mutating func deleteBackward(now: Double = ProcessInfo.processInfo.systemUptime) {
        if !snapshot.selected.isEmpty { snapshot.selected = "" }
        else if !snapshot.before.isEmpty { snapshot.before.removeLast() }
        marked = ""; remember(now: now)
    }
    public mutating func moveCursor(_ offset: Int, now: Double = ProcessInfo.processInfo.systemUptime) {
        let whole = snapshot.before + snapshot.selected + snapshot.after
        let position = max(0, min(whole.count, snapshot.before.count + offset))
        snapshot.before = String(whole.prefix(position)); snapshot.after = String(whole.dropFirst(position))
        snapshot.selected = ""; marked = ""; remember(now: now)
    }
    public mutating func reconcile(_ actual: HostTextSnapshot, now: Double = ProcessInfo.processInfo.systemUptime) -> Reconciliation {
        pending.removeAll { now - $0.1 > 1 }
        if !actual.available, actual.document == snapshot.document { return .unavailable }
        if Self.equivalent(snapshot, actual) {
            acknowledged = actual; pending.removeAll(); return .ownEdit
        }
        // A host can expose context around the marked range rather than including
        // its uncommitted spelling. This boundary remains valid after a reading pause.
        if isMarkedBoundary(actual) { acknowledged = actual; return .ownEdit }
        if actual.document == snapshot.document {
            if let index = pending.lastIndex(where: { Self.equivalent($0.0, actual) }) {
                acknowledged = actual; pending.removeFirst(index + 1); return .ownEdit
            }
            // A delayed notification may still expose the last acknowledged text.
            if !pending.isEmpty, Self.equivalent(acknowledged, actual) { return .ownEdit }
        }
        snapshot = actual; acknowledged = actual; marked = ""; pending = []; return .externalEdit
    }
    public func accepts(_ expected: HostTextSnapshot, actual: HostTextSnapshot, now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard actual.available, actual.selected.isEmpty, expected.document == actual.document,
              Self.equivalent(snapshot, expected) else { return false }
        if Self.equivalent(expected, actual) { return true }
        if isMarkedBoundary(actual) { return true }
        let recent = pending.filter { now - $0.1 <= 1 }
        return !recent.isEmpty && (Self.equivalent(acknowledged, actual) || recent.contains { Self.equivalent($0.0, actual) })
    }
}
