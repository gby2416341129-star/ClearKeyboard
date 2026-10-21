import XCTest
import Security
@testable import ClearKeyboard

private final class AppearanceMemoryBackend: ClearKeyboard.AppearanceSyncBackend {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    private(set) var writes = 0
    private(set) var writesByAccount: [String: Int] = [:]
    private(set) var usedMainThread = false
    var readFailure: ClearKeyboard.AppearanceSyncError?
    var writeFailure: ClearKeyboard.AppearanceSyncError?
    func read(account: String) -> Result<ClearKeyboard.AppearanceBackendRecord?, ClearKeyboard.AppearanceSyncError> {
        lock.lock(); defer { lock.unlock() }
        usedMainThread = usedMainThread || Thread.isMainThread
        if let readFailure { return .failure(readFailure) }
        return .success(records[account].map { ClearKeyboard.AppearanceBackendRecord(data: $0, accessGroup: "fixture.authorized.group") })
    }
    func write(_ data: Data, account: String) -> Result<String?, ClearKeyboard.AppearanceSyncError> {
        lock.lock(); defer { lock.unlock() }
        usedMainThread = usedMainThread || Thread.isMainThread
        if let writeFailure { return .failure(writeFailure) }
        records[account] = data; writes += 1; writesByAccount[account, default: 0] += 1
        return .success("fixture.authorized.group")
    }
    func seed(_ data: Data, account: String) {
        lock.lock(); defer { lock.unlock() }; records[account] = data
    }
}

@MainActor final class AppearanceSyncRuntimeTests: XCTestCase {
    private func envelope() -> ClearKeyboard.AppearanceEnvelope {
        var settings = ClearKeyboard.KeyboardSettings()
        settings.glass = .mist; settings.backgroundGlassStrength = 0.87; settings.keyGlassStrength = 0.23
        settings.backgroundColorHex = "#D799BC"; settings.keyColorHex = "#292C39"; settings.candidateColorHex = "#558DF2"
        settings.candidateTextSize = .large; settings.accent = .rose
        return ClearKeyboard.AppearanceEnvelope(snapshot: ClearKeyboard.AppearanceSnapshot(settings: settings))
    }
    func testSnapshotAppliesEveryAppearanceFieldAndPreservesInputPreferences() {
        let appearance = envelope().snapshot
        var input = ClearKeyboard.KeyboardSettings()
        input.language = .english; input.learnChoices = false; input.predictions = false
        input.selectionLearningVersion = nil
        input.keyHeight = 57; input.hand = .left; input.automaticClipboard = false
        input.clipboardLifetimeHours = 24; input.haptics = true; input.fuzzyPairs = ["n/l"]
        let merged = appearance.applying(to: input)
        XCTAssertEqual(ClearKeyboard.AppearanceSnapshot(settings: merged), appearance)
        XCTAssertEqual(merged.language, input.language); XCTAssertEqual(merged.learnChoices, input.learnChoices)
        XCTAssertEqual(merged.selectionLearningVersion, input.selectionLearningVersion)
        XCTAssertEqual(merged.predictions, input.predictions); XCTAssertEqual(merged.haptics, input.haptics)
        XCTAssertEqual(merged.keyHeight, input.keyHeight); XCTAssertEqual(merged.hand, input.hand)
        XCTAssertEqual(merged.automaticClipboard, input.automaticClipboard)
        XCTAssertEqual(merged.clipboardLifetimeHours, input.clipboardLifetimeHours)
        XCTAssertEqual(merged.fuzzyPairs, input.fuzzyPairs)
    }
    func testAppearancePayloadDoesNotContainInputOrClipboardPreferences() throws {
        let value = envelope(), data = try ClearKeyboard.AppearanceSyncClient.encode(value).get()
        XCTAssertEqual(try ClearKeyboard.AppearanceSyncClient.decode(data).get(), value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        XCTAssertEqual(Set(snapshot.keys), Set(["glass", "accent", "glassOpacity", "backgroundGlassStrength", "keyGlassStrength", "backgroundColorHex", "keyColorHex", "candidateColorHex", "candidateTextSize"]))
        XCTAssertNil(snapshot["language"]); XCTAssertNil(snapshot["learnChoices"]); XCTAssertNil(snapshot["clipboardLifetimeHours"])
        XCTAssertLessThan(data.count, 2_048)
    }
    func testMalformedUnsupportedAndOversizedAppearancePayloadsAreRejected() throws {
        let source = try ClearKeyboard.AppearanceSyncClient.encode(envelope()).get()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        object["schema"] = 999
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ClearKeyboard.AppearanceSyncClient.decode(unsupported).get()) {
            XCTAssertEqual($0 as? ClearKeyboard.AppearanceSyncError, .unsupportedSchema(999))
        }
        object["schema"] = 1
        var snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        snapshot["keyColorHex"] = "not-a-color"; object["snapshot"] = snapshot
        XCTAssertThrowsError(try ClearKeyboard.AppearanceSyncClient.decode(JSONSerialization.data(withJSONObject: object)).get())
        snapshot["keyColorHex"] = "#FFFFFF"; snapshot["backgroundGlassStrength"] = 3; object["snapshot"] = snapshot
        XCTAssertThrowsError(try ClearKeyboard.AppearanceSyncClient.decode(JSONSerialization.data(withJSONObject: object)).get())
        XCTAssertThrowsError(try ClearKeyboard.AppearanceSyncClient.decode(Data("{".utf8)).get())
        XCTAssertThrowsError(try ClearKeyboard.AppearanceSyncClient.decode(Data(repeating: 0, count: 16_385)).get())
    }
    func testTwoIndependentClientsReceiveLatestAppearanceAndActualGroup() async throws {
        let backend = AppearanceMemoryBackend()
        let app = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let keyboard = ClearKeyboard.AppearanceSyncClient(backend: backend)
        let value = envelope(), published = expectation(description: "appearance saved"), loaded = expectation(description: "keyboard received")
        app.publish(value) { result in
            do {
                let write = try result.get(); XCTAssertEqual(write.revision, value.revision)
                XCTAssertEqual(write.accessGroup, "fixture.authorized.group")
            } catch { XCTFail("\(error)") }
            published.fulfill()
        }
        await fulfillment(of: [published], timeout: 3)
        keyboard.load { result in
            do {
                let read = try XCTUnwrap(result.get())
                XCTAssertEqual(read.envelope, value); XCTAssertEqual(read.accessGroup, "fixture.authorized.group")
            } catch { XCTFail("\(error)") }
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 3)
    }
    func testRapidSliderWritesCoalesceAndReportSupersededRevisions() async {
        let backend = AppearanceMemoryBackend(), client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0.2)
        let callbacks = expectation(description: "each write callback"); callbacks.expectedFulfillmentCount = 100
        let latest = envelope(); var successfulRevisions: [UUID] = []; var superseded = 0
        for index in 0..<100 {
            let value = index == 99 ? latest : envelope()
            client.publish(value) { result in
                switch result {
                case .success(let write): successfulRevisions.append(write.revision)
                case .failure(.superseded): superseded += 1
                case .failure(let error): XCTFail("\(error)")
                }
                callbacks.fulfill()
            }
        }
        await fulfillment(of: [callbacks], timeout: 5)
        XCTAssertEqual(backend.writes, 1)
        XCTAssertEqual(successfulRevisions, [latest.revision]); XCTAssertEqual(superseded, 99)
    }
    func testActivationFlushesPendingAppearanceBeforeReading() async {
        let backend = AppearanceMemoryBackend(), client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 30)
        let value = envelope(), saved = expectation(description: "flush saved"), read = expectation(description: "read after flush")
        client.publish(value) { result in
            XCTAssertEqual(try? result.get().revision, value.revision); saved.fulfill()
        }
        client.load { result in
            XCTAssertEqual(try? result.get()?.envelope, value); read.fulfill()
        }
        await fulfillment(of: [saved, read], timeout: 3)
        XCTAssertEqual(backend.writes, 1)
    }
    func testMissingSettingsAndReceiptRemainUnconfirmed() async {
        let client = ClearKeyboard.AppearanceSyncClient(backend: AppearanceMemoryBackend())
        let settings = expectation(description: "missing settings"), receipt = expectation(description: "missing receipt")
        client.load { result in
            do { XCTAssertNil(try result.get()) } catch { XCTFail("\(error)") }; settings.fulfill()
        }
        client.readReceipt { result in
            do { XCTAssertNil(try result.get()) } catch { XCTFail("\(error)") }; receipt.fulfill()
        }
        await fulfillment(of: [settings, receipt], timeout: 3)
    }
    func testReceiverReceiptCarriesExactRevisionAndNeverAssumesLatest() async {
        let backend = AppearanceMemoryBackend(), keyboard = ClearKeyboard.AppearanceSyncClient(backend: backend)
        let app = ClearKeyboard.AppearanceSyncClient(backend: backend)
        let received = UUID(), different = UUID(), saved = expectation(description: "receipt saved"), loaded = expectation(description: "receipt loaded")
        keyboard.writeReceipt(revision: received) { result in
            XCTAssertEqual(try? result.get().revision, received); saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 3)
        app.readReceipt { result in
            do {
                let receipt = try XCTUnwrap(result.get())
                XCTAssertEqual(receipt.receipt.revision, received); XCTAssertNotEqual(receipt.receipt.revision, different)
                XCTAssertEqual(receipt.accessGroup, "fixture.authorized.group")
            } catch { XCTFail("\(error)") }
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 3)
    }
    func testPermissionAndLockedDeviceErrorsAreReportedWithoutFalseSuccess() async {
        let backend = AppearanceMemoryBackend()
        backend.writeFailure = .keychain(errSecMissingEntitlement); backend.readFailure = .keychain(errSecInteractionNotAllowed)
        let client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let saved = expectation(description: "write denied"), loaded = expectation(description: "read locked")
        client.publish(envelope()) { result in
            if case .failure(.keychain(errSecMissingEntitlement)) = result {} else { XCTFail("Expected real entitlement error") }
            saved.fulfill()
        }
        client.load { result in
            if case .failure(.keychain(errSecInteractionNotAllowed)) = result {} else { XCTFail("Expected real locked-device error") }
            loaded.fulfill()
        }
        await fulfillment(of: [saved, loaded], timeout: 3)
        XCTAssertEqual(backend.writes, 0)
    }
    func testSecurityWorkRunsOffMainAndCallbacksRunOnMain() async {
        let backend = AppearanceMemoryBackend(), client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let saved = expectation(description: "write callback"), loaded = expectation(description: "read callback")
        client.publish(envelope()) { _ in XCTAssertTrue(Thread.isMainThread); saved.fulfill() }
        client.load { _ in XCTAssertTrue(Thread.isMainThread); loaded.fulfill() }
        await fulfillment(of: [saved, loaded], timeout: 3)
        XCTAssertFalse(backend.usedMainThread)
    }
    func testMalformedReceiptAndSettingsCannotBeAccepted() async {
        let backend = AppearanceMemoryBackend()
        backend.seed(Data("{}".utf8), account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
        backend.seed(Data("{}".utf8), account: ClearKeyboard.AppearanceSyncClient.receiptAccount)
        let client = ClearKeyboard.AppearanceSyncClient(backend: backend)
        let loaded = expectation(description: "bad settings"), receipt = expectation(description: "bad receipt")
        client.load { result in
            if case .failure(.invalidPayload) = result {} else { XCTFail("Malformed settings accepted") }; loaded.fulfill()
        }
        client.readReceipt { result in
            if case .failure(.invalidPayload) = result {} else { XCTFail("Malformed receipt accepted") }; receipt.fulfill()
        }
        await fulfillment(of: [loaded, receipt], timeout: 3)
    }
    func testPublicKeychainRoundTripReturnsAssignedGroupAndUpdatesIsolatedItem() async {
        // This checks actual Security APIs in the test host. Cross-process
        // permission still requires the signed App and keyboard on a phone.
        let backend = ClearKeyboard.AppearanceKeychainBackend(service: "clear.appearance.fixture." + UUID().uuidString)
        let client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        defer { _ = backend.remove(account: ClearKeyboard.AppearanceSyncClient.settingsAccount) }
        for value in [envelope(), envelope()] {
            let saved = expectation(description: "real keychain saved"), loaded = expectation(description: "real keychain read")
            client.publish(value) { result in
                do {
                    let write = try result.get(); XCTAssertEqual(write.revision, value.revision)
                    XCTAssertFalse(write.accessGroup?.isEmpty ?? true)
                } catch { XCTFail("Actual keychain write failed: \(error)") }
                saved.fulfill()
            }
            await fulfillment(of: [saved], timeout: 5)
            client.load { result in
                do {
                    let read = try XCTUnwrap(result.get()); XCTAssertEqual(read.envelope, value)
                    XCTAssertFalse(read.accessGroup?.isEmpty ?? true)
                } catch { XCTFail("Actual keychain read failed: \(error)") }
                loaded.fulfill()
            }
            await fulfillment(of: [loaded], timeout: 5)
        }
    }
    func testAppearanceLinkRetriesFailedWriteOnActivation() async {
        let backend = AppearanceMemoryBackend()
        backend.writeFailure = .keychain(errSecMissingEntitlement)
        let client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let link = ClearKeyboard.AppearanceSettingsLink(role: .app, client: client)
        let desired = envelope().snapshot.applying(to: ClearKeyboard.KeyboardSettings())
        link.currentSettings = { desired }
        let failed = expectation(description: "initial unavailable"), recovered = expectation(description: "activation saved dirty edit")
        var failureReported = false, recoveryReported = false
        link.onStatus = { status in
            if status == .unavailable, !failureReported { failureReported = true; failed.fulfill() }
            if status == .waitingForKeyboard, !recoveryReported { recoveryReported = true; recovered.fulfill() }
        }
        link.publish(desired)
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(backend.writes, 0)
        backend.writeFailure = nil
        link.activate(); defer { link.deactivate() }
        await fulfillment(of: [recovered], timeout: 3)
        let loaded = expectation(description: "persisted recovered edit")
        client.load { result in
            XCTAssertEqual(try? result.get()?.envelope.snapshot, ClearKeyboard.AppearanceSnapshot(settings: desired))
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 3)
        XCTAssertEqual(backend.writesByAccount[ClearKeyboard.AppearanceSyncClient.settingsAccount], 1)
    }
    func testAppearanceLinkRetriesUnchangedValueAfterWriteFailure() async {
        let backend = AppearanceMemoryBackend()
        backend.writeFailure = .keychain(errSecInteractionNotAllowed)
        let client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let link = ClearKeyboard.AppearanceSettingsLink(role: .app, client: client)
        let desired = envelope().snapshot.applying(to: ClearKeyboard.KeyboardSettings())
        link.currentSettings = { desired }
        let failed = expectation(description: "device locked"), recovered = expectation(description: "same value retried")
        var failureReported = false, recoveryReported = false
        link.onStatus = { status in
            if status == .unavailable, !failureReported { failureReported = true; failed.fulfill() }
            if status == .waitingForKeyboard, !recoveryReported { recoveryReported = true; recovered.fulfill() }
        }
        link.publish(desired)
        await fulfillment(of: [failed], timeout: 3)
        backend.writeFailure = nil
        link.publish(desired)
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertEqual(backend.writesByAccount[ClearKeyboard.AppearanceSyncClient.settingsAccount], 1)
    }
    func testAppearanceLinkWithoutReceiverReceiptNeverReportsReceived() async throws {
        let backend = AppearanceMemoryBackend(), value = envelope()
        backend.seed(try ClearKeyboard.AppearanceSyncClient.encode(value).get(), account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
        let link = ClearKeyboard.AppearanceSettingsLink(role: .app,
            client: ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0))
        link.currentSettings = { value.snapshot.applying(to: ClearKeyboard.KeyboardSettings()) }
        var states: [ClearKeyboard.AppearanceSettingsLink.Status] = []
        let waiting = expectation(description: "saved does not mean received")
        link.onStatus = { status in
            states.append(status)
            if status == .waitingForKeyboard, states.filter({ $0 == .waitingForKeyboard }).count == 1 { waiting.fulfill() }
        }
        link.activate(); defer { link.deactivate() }
        await fulfillment(of: [waiting], timeout: 3)
        XCTAssertFalse(states.contains(.receivedByKeyboard))
        XCTAssertNil(backend.writesByAccount[ClearKeyboard.AppearanceSyncClient.receiptAccount])
    }
    func testAppearanceLinkNotificationRefreshDoesNotLoopReceiptWrites() async throws {
        let backend = AppearanceMemoryBackend(), value = envelope()
        backend.seed(try ClearKeyboard.AppearanceSyncClient.encode(value).get(), account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
        let client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let link = ClearKeyboard.AppearanceSettingsLink(role: .keyboard, client: client)
        var settings = ClearKeyboard.KeyboardSettings(), deliveries = 0
        link.currentSettings = { settings }
        let received = expectation(description: "keyboard received exact revision")
        link.onReceive = { snapshot in
            settings = snapshot.applying(to: settings); deliveries += 1
            if deliveries == 1 { received.fulfill() }
        }
        link.activate(); defer { link.deactivate() }
        await fulfillment(of: [received], timeout: 3)
        for _ in 0..<20 { link.refresh() }
        let settled = expectation(description: "notification and receipt queues settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 3)
        let inspected = expectation(description: "inspect written receipt")
        client.readReceipt { result in
            XCTAssertEqual(try? result.get()?.receipt.revision, value.revision); inspected.fulfill()
        }
        await fulfillment(of: [inspected], timeout: 3)
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(backend.writesByAccount[ClearKeyboard.AppearanceSyncClient.receiptAccount], 1)
        XCTAssertNil(backend.writesByAccount[ClearKeyboard.AppearanceSyncClient.settingsAccount])
    }
    func testMirroredBackendPersistsToRealGroupFileWhenKeychainIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clear.appearance.file." + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = AppearanceMemoryBackend()
        keychain.writeFailure = .keychain(errSecMissingEntitlement)
        keychain.readFailure = .keychain(errSecMissingEntitlement)
        let writer = ClearKeyboard.AppearanceMirroredBackend(groupRoot: root, keychain: keychain)
        let value = envelope(), data = try ClearKeyboard.AppearanceSyncClient.encode(value).get()
        XCTAssertEqual(try writer.write(data, account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get(), "app-group")
        let path = root.appendingPathComponent("Appearance-v1/appearance.json")
        XCTAssertEqual(try Data(contentsOf: path), data)
        // A newly created reader has no process-local state from the writer.
        let reader = ClearKeyboard.AppearanceMirroredBackend(groupRoot: root, keychain: keychain)
        let read = try XCTUnwrap(reader.read(account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get())
        XCTAssertEqual(try ClearKeyboard.AppearanceSyncClient.decode(read.data).get(), value)
        XCTAssertEqual(read.accessGroup, "app-group")
        XCTAssertEqual(keychain.writes, 0)
    }
    func testMirroredBackendChoosesNewestValidChannelAndIgnoresCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clear.appearance.newest." + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Appearance-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("appearance.json")
        let keychain = AppearanceMemoryBackend(), backend = ClearKeyboard.AppearanceMirroredBackend(groupRoot: root, keychain: keychain)
        let old = ClearKeyboard.AppearanceEnvelope(snapshot: envelope().snapshot, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let new = ClearKeyboard.AppearanceEnvelope(snapshot: envelope().snapshot, updatedAt: Date(timeIntervalSince1970: 1_700_000_001))
        let oldData = try ClearKeyboard.AppearanceSyncClient.encode(old).get(), newData = try ClearKeyboard.AppearanceSyncClient.encode(new).get()
        func latestRevision() throws -> UUID {
            let read = try XCTUnwrap(backend.read(account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get())
            return try ClearKeyboard.AppearanceSyncClient.decode(read.data).get().revision
        }
        try oldData.write(to: file, options: .atomic)
        keychain.seed(newData, account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
        XCTAssertEqual(try latestRevision(), new.revision, "A newer compatible channel must beat a stale group file")
        try newData.write(to: file, options: .atomic)
        keychain.seed(oldData, account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
        XCTAssertEqual(try latestRevision(), new.revision, "A newer group file must beat a stale compatible channel")
        try Data("malformed".utf8).write(to: file, options: .atomic)
        keychain.seed(newData, account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
        XCTAssertEqual(try latestRevision(), new.revision, "A corrupt primary file must not hide another valid channel")
        try newData.write(to: file, options: .atomic)
        keychain.seed(Data("{}".utf8), account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
        XCTAssertEqual(try latestRevision(), new.revision, "A corrupt compatible channel must not hide a valid primary file")
    }
    func testMirroredBackendReportsFailureWhenNeitherChannelCanSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clear.appearance.blocked." + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedRoot = root.appendingPathComponent("regular-file")
        try Data("This is not a container directory".utf8).write(to: blockedRoot)
        let keychain = AppearanceMemoryBackend(); keychain.writeFailure = .keychain(errSecMissingEntitlement)
        let backend = ClearKeyboard.AppearanceMirroredBackend(groupRoot: blockedRoot, keychain: keychain)
        let data = try ClearKeyboard.AppearanceSyncClient.encode(envelope()).get()
        if case .failure(.keychain(errSecMissingEntitlement)) = backend.write(data, account: ClearKeyboard.AppearanceSyncClient.settingsAccount) {} else {
            XCTFail("Two failed channels must never report a saved appearance")
        }
        XCTAssertEqual(keychain.writes, 0)
        XCTAssertThrowsError(try backend.write(data, account: "../outside").get())
    }
}
