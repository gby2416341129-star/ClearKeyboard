import Foundation

struct CandidateRequestKey: Hashable {
    let raw: String
    let preceding: String
}

enum CandidateLanguageContext {
    static func tail(_ text: String) -> String {
        // V21 takes the actual last32 committed Unicode scalars.
        String(String.UnicodeScalarView(text.unicodeScalars.suffix(32)))
    }

    static func preceding(before: String, markedDraft: String) -> String {
        guard markedDraft.isEmpty || before.hasSuffix(markedDraft) else { return "" }
        return tail(markedDraft.isEmpty ? before : String(before.dropLast(markedDraft.count)))
    }
}

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
    public enum Reconciliation: Equatable { case ownEdit, compositionContextChanged, externalEdit, unavailable }
    public private(set) var snapshot: HostTextSnapshot
    private var acknowledged: HostTextSnapshot
    private var pending: [(HostTextSnapshot, Double)] = []
    private var marked = ""
    private var markedOrigin: HostTextSnapshot?
    private struct MarkedPath {
        var text: String
        var requestedLengths: Set<Int>
    }
    private var markedHistory: [MarkedPath] = []
    private struct MarkedAcknowledgements {
        var origin: HostTextSnapshot
        var paths: [MarkedPath]
    }
    private var convertedMarkedHistory: [MarkedAcknowledgements] = []
    public init(_ snapshot: HostTextSnapshot = HostTextSnapshot()) { self.snapshot = snapshot; acknowledged = snapshot }
    public func hasPendingEdits(now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        pending.contains { now - $0.1 <= 1 }
    }
    public var hasMarkedText: Bool { !marked.isEmpty }
    public func shouldRecheck(_ actual: HostTextSnapshot, now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        actual.available && actual.document == snapshot.document &&
        !Self.equivalent(snapshot, actual) && !isMarkedBoundary(actual) && hasPendingEdits(now: now)
    }
    private mutating func endMarkedSession() {
        marked = ""; markedOrigin = nil; markedHistory.removeAll(keepingCapacity: true)
        convertedMarkedHistory.removeAll(keepingCapacity: true)
    }
    private func isMarkedAcknowledgement(_ actual: HostTextSnapshot) -> Bool {
        guard !marked.isEmpty else { return false }
        if let origin = markedOrigin, matchesMarkedAcknowledgement(actual, origin: origin, paths: markedHistory) { return true }
        return convertedMarkedHistory.contains {
            // The explicit empty-mark write can be acknowledged before the
            // Chinese insertion. A nonempty original boundary is recognizable;
            // an empty field is ambiguous with a real external Clear and keeps
            // the ordinary bounded edit lease instead of an infinite exemption.
            (!$0.origin.before.isEmpty && Self.equivalent($0.origin, actual)) ||
                matchesMarkedAcknowledgement(actual, origin: $0.origin, paths: $0.paths)
        }
    }
    private func matchesMarkedAcknowledgement(_ actual: HostTextSnapshot, origin: HostTextSnapshot, paths: [MarkedPath]) -> Bool {
        guard !actual.before.isEmpty,
              actual.document == origin.document, actual.selected.isEmpty else { return false }
        // Store maximal typing paths and the lengths actually requested along
        // each path. A long append-only draft needs one string, not one full
        // copy per key. Earlier acknowledgements remain owned after 512 keys.
        for path in paths.reversed() {
            let full = origin.before + path.text
            if actual.before.count < 32 {
                let length = actual.before.count - origin.before.count
                if full.hasPrefix(actual.before), path.requestedLengths.contains(length) {
                    var expected = origin; expected.before = actual.before
                    if Self.equivalent(expected, actual) { return true }
                }
                continue
            }
            var search = full.startIndex..<full.endIndex
            while let range = full.range(of: actual.before, range: search) {
                let length = full.distance(from: full.startIndex, to: range.upperBound) - origin.before.count
                if path.requestedLengths.contains(length) {
                    var expected = origin; expected.before = String(full[..<range.upperBound])
                    if Self.equivalent(expected, actual) { return true }
                }
                if range.lowerBound == full.endIndex { break }
                search = full.index(after: range.lowerBound)..<full.endIndex
            }
        }
        return false
    }
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
        if !marked.isEmpty, snapshot.before.hasSuffix(marked) {
            let prefix = snapshot.before.dropLast(marked.count)
            snapshot.before = String(prefix.suffix(4_096)) + marked
        } else { snapshot.before = String(snapshot.before.suffix(4_096)) }
        snapshot.after = String(snapshot.after.prefix(4_096))
        pending.removeAll { now - $0.1 > 1 }
        if pending.last?.0 == snapshot { pending[pending.count - 1].1 = now }
        else { pending.append((snapshot, now)) }
        if pending.count > 64 { pending.removeFirst(pending.count - 64) }
    }
    public mutating func insert(_ text: String, now: Double = ProcessInfo.processInfo.systemUptime) {
        // UIKeyInput insertion replaces an active marked range. Mirror that
        // operation locally rather than appending Chinese after its pinyin.
        if !marked.isEmpty {
            remember(now: now)
            if snapshot.before.hasSuffix(marked) { snapshot.before.removeLast(marked.count) }
        }
        snapshot.before += text; snapshot.selected = ""; endMarkedSession(); remember(now: now)
    }
    /// A prefix conversion and its untouched spelling are one edit transaction.
    /// Some hosts acknowledge the old whole draft after the ordinary edit lease
    /// has expired. Keep those exact requested marked paths while the remainder
    /// is active, rather than treating that acknowledgement as a cursor move.
    public mutating func commitMarked(_ text: String, remaining: String, now: Double = ProcessInfo.processInfo.systemUptime) {
        var history = convertedMarkedHistory
        if !marked.isEmpty, let origin = markedOrigin {
            history.append(MarkedAcknowledgements(origin: origin, paths: markedHistory))
            setMarked("", now: now)
        }
        insert(text, now: now)
        guard !remaining.isEmpty else { return }
        setMarked(remaining, now: now)
        // Retain the initial whole draft and recent partial conversions. This
        // is scoped to one live composition, never to a later field or word.
        if history.count > 32 { history.removeSubrange(1..<(history.count - 31)) }
        convertedMarkedHistory = history
    }
    public mutating func setMarked(_ text: String, now: Double = ProcessInfo.processInfo.systemUptime) {
        if markedOrigin == nil {
            var origin = snapshot; origin.selected = ""; markedOrigin = origin
        }
        if let last = markedHistory.indices.last,
           text.hasPrefix(markedHistory[last].text) || markedHistory[last].text.hasPrefix(text) {
            if text.count > markedHistory[last].text.count { markedHistory[last].text = text }
            markedHistory[last].requestedLengths.insert(text.count)
        } else { markedHistory.append(MarkedPath(text: text, requestedLengths: [text.count])) }
        // Bound distinct replacement branches, rather than truncating the
        // acknowledgement history halfway through one long typing path.
        if markedHistory.count > 512 { markedHistory.removeFirst(markedHistory.count - 512) }
        // A long-lived draft may be older than the acknowledgement window.
        // Renew its predecessor snapshot before replacement, so an immediately
        // delayed host read cannot turn a confirmed word back into raw pinyin.
        if !marked.isEmpty { remember(now: now) }
        if !marked.isEmpty, snapshot.before.hasSuffix(marked) { snapshot.before.removeLast(marked.count) }
        snapshot.before += text; snapshot.selected = ""; marked = text; remember(now: now)
        if text.isEmpty { endMarkedSession() }
    }
    public mutating func unmark() { endMarkedSession() }
    public mutating func deleteBackward(now: Double = ProcessInfo.processInfo.systemUptime) {
        if !snapshot.selected.isEmpty { snapshot.selected = "" }
        else if !snapshot.before.isEmpty { snapshot.before.removeLast() }
        endMarkedSession(); remember(now: now)
    }
    public mutating func moveCursor(_ offset: Int, now: Double = ProcessInfo.processInfo.systemUptime) {
        let whole = snapshot.before + snapshot.selected + snapshot.after
        let position = max(0, min(whole.count, snapshot.before.count + offset))
        snapshot.before = String(whole.prefix(position)); snapshot.after = String(whole.dropFirst(position))
        snapshot.selected = ""; endMarkedSession(); remember(now: now)
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
        if isMarkedAcknowledgement(actual) { acknowledged = actual; return .ownEdit }
        if !marked.isEmpty, actual.selected.isEmpty, actual.document == snapshot.document,
           actual.before.hasSuffix(marked) {
            var surrounding = snapshot; surrounding.before = actual.before; surrounding.selected = ""
            let prefix = String(actual.before.dropLast(marked.count))
            // An old pre-conversion spelling can also end in the remainder.
            // Never adopt its earlier Latin syllables as committed text.
            let latinPrefix = prefix.last.map { $0.isASCII && ($0.isLetter || $0 == "'") } ?? false
            if !latinPrefix, Self.equivalent(surrounding, actual) {
                // The latest spelling is still at the caret, but committed
                // text before it changed (for example the app cleared a field
                // and the user already started the next word). Adopt the real
                // context without unmarking and committing that new pinyin.
                snapshot = actual; acknowledged = actual
                var origin = actual; origin.before.removeLast(marked.count); markedOrigin = origin
                markedHistory = [MarkedPath(text: marked, requestedLengths: [marked.count])]
                convertedMarkedHistory.removeAll(keepingCapacity: true)
                remember(now: now); return .compositionContextChanged
            }
        }
        if actual.document == snapshot.document {
            if let index = pending.lastIndex(where: { Self.equivalent($0.0, actual) }) {
                acknowledged = actual; pending.removeFirst(index + 1); return .ownEdit
            }
            // A delayed notification may still expose the last acknowledged text.
            if !pending.isEmpty, Self.equivalent(acknowledged, actual) { return .ownEdit }
        }
        snapshot = actual; acknowledged = actual; endMarkedSession(); pending = []; return .externalEdit
    }
    public func accepts(_ expected: HostTextSnapshot, actual: HostTextSnapshot, now: Double = ProcessInfo.processInfo.systemUptime,
                        boundedAcknowledgements: Bool = false) -> Bool {
        guard actual.available, actual.selected.isEmpty, expected.document == actual.document,
              Self.equivalent(snapshot, expected) else { return false }
        if Self.equivalent(expected, actual) { return true }
        if isMarkedBoundary(actual) { return true }
        // A clipboard replacement may wait for a prior request, but must not
        // treat a permanently truncated prior value as an indefinite receipt.
        if isMarkedAcknowledgement(actual), !boundedAcknowledgements || hasPendingEdits(now: now) { return true }
        let recent = pending.filter { now - $0.1 <= 1 }
        return !recent.isEmpty && (Self.equivalent(acknowledged, actual) || recent.contains { Self.equivalent($0.0, actual) })
    }
}
