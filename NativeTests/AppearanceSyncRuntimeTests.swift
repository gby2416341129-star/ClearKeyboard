import XCTest
import Security
import CoreFoundation
@testable import ClearKeyboard

private final class AppearanceMemoryBackend: ClearKeyboard.AppearanceSyncBackend {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    private(set) var writes = 0
    private(set) var writesByAccount: [String: Int] = [:]
    private(set) var usedMainThread = false
    var readFailure: ClearKeyboard.AppearanceSyncError?
    var writeFailure: ClearKeyboard.AppearanceSyncError?
    var didWrite: ((String) -> Void)?
    var diagnostics: ClearKeyboard.AppearanceBackendDiagnostics {
        lock.lock(); defer { lock.unlock() }
        var value = ClearKeyboard.AppearanceBackendDiagnostics()
        if case .keychain(let status)? = readFailure { value.keychainReadStatus = status }
        else { value.keychainReadStatus = records.isEmpty ? errSecItemNotFound : errSecSuccess }
        if case .keychain(let status)? = writeFailure { value.keychainWriteStatus = status }
        else if writes > 0 { value.keychainWriteStatus = errSecSuccess }
        if !records.isEmpty { value.keychainAccessGroup = "fixture.authorized.group" }
        return value
    }
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
        didWrite?(account)
        return .success("fixture.authorized.group")
    }
    func seed(_ data: Data, account: String) {
        lock.lock(); defer { lock.unlock() }; records[account] = data
    }
}

private final class AppearancePersistenceProbe {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let notificationCheck: (() -> Bool)?
    private let notificationObserved: (() -> Void)?
    init(notificationCheck: (() -> Bool)? = nil, notificationObserved: (() -> Void)? = nil) {
        self.notificationCheck = notificationCheck; self.notificationObserved = notificationObserved
    }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
    func receiveNotification() {
        guard notificationCheck?() == true else { return }
        lock.lock()
        guard !recorded.contains("notification") else { lock.unlock(); return }
        recorded.append("notification"); lock.unlock()
        notificationObserved?()
    }
}

@MainActor final class AppearanceSyncRuntimeTests: XCTestCase {
    // Explicit same-process identity injection only exercises receipt matching.
    // Production obtains this identity from the installed .appex bundle.
    private func receiver(build: String = "53") -> ClearKeyboard.AppearanceReceiverIdentity {
        ClearKeyboard.AppearanceReceiverIdentity(bundleIdentifier: "fixture.ClearKeyboard.Keyboard",
            version: "0.1.50", build: build, extensionPoint: "com.apple.keyboard-service")
    }
    private enum FixtureFailure: Error { case timeout }
    private func waitFor(_ condition: () -> Bool, message: String) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(message); throw FixtureFailure.timeout
    }
    private func envelope() -> ClearKeyboard.AppearanceEnvelope {
        var settings = ClearKeyboard.KeyboardSettings()
        settings.keyGlassStrength = 0.23
        settings.keyColorHex = "#292C39"; settings.candidateColorHex = "#558DF2"
        settings.candidateTextSize = .large; settings.accent = .rose
        return ClearKeyboard.AppearanceEnvelope(snapshot: ClearKeyboard.AppearanceSnapshot(settings: settings))
    }
    func testSnapshotAppliesEveryAppearanceFieldAndPreservesInputPreferences() {
        let appearance = envelope().snapshot
        var input = ClearKeyboard.KeyboardSettings()
        input.language = .english; input.learnChoices = false; input.predictions = false
        input.selectionLearningVersion = nil
        input.keyHeight = 57; input.hand = .left; input.automaticClipboard = false
        input.clipboardLifetimeHours = 24; input.vibrationEnabled = true; input.fuzzyPairs = ["n/l"]
        let merged = appearance.applying(to: input)
        XCTAssertEqual(ClearKeyboard.AppearanceSnapshot(settings: merged), appearance)
        XCTAssertEqual(merged.language, input.language); XCTAssertEqual(merged.learnChoices, input.learnChoices)
        XCTAssertEqual(merged.selectionLearningVersion, input.selectionLearningVersion)
        XCTAssertEqual(merged.predictions, input.predictions); XCTAssertEqual(merged.vibrationEnabled, appearance.vibrationEnabled)
        XCTAssertEqual(merged.keyHeight, appearance.keyHeight); XCTAssertEqual(merged.hand, appearance.hand)
        XCTAssertEqual(merged.automaticClipboard, appearance.automaticClipboard)
        XCTAssertEqual(merged.clipboardLifetimeHours, appearance.clipboardLifetimeHours)
        XCTAssertEqual(merged.fuzzyPairs, input.fuzzyPairs)
    }
    func testAppearancePayloadDoesNotContainInputOrClipboardPreferences() throws {
        let value = envelope(), data = try ClearKeyboard.AppearanceSyncClient.encode(value).get()
        XCTAssertEqual(try ClearKeyboard.AppearanceSyncClient.decode(data).get(), value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        XCTAssertEqual(Set(snapshot.keys), Set(["accent", "keyGlassStrength", "keyColorHex", "candidateColorHex", "candidateTextSize", "keyHeight", "vibrationEnabled", "vibrationIntensity", "vibrationMode", "hand", "oneHandWidth", "toolbar", "localPinyinComposition", "automaticClipboard", "clipboardLifetimeHours"]))
        XCTAssertNil(snapshot["language"]); XCTAssertNil(snapshot["learnChoices"]); XCTAssertNotNil(snapshot["clipboardLifetimeHours"])
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
        snapshot["keyColorHex"] = "#FFFFFF"; snapshot["keyGlassStrength"] = 3; object["snapshot"] = snapshot
        XCTAssertThrowsError(try ClearKeyboard.AppearanceSyncClient.decode(JSONSerialization.data(withJSONObject: object)).get())
        snapshot["keyGlassStrength"] = 0.23
        for invalidHeight in [43.0, 58.1, -1, 10_000] {
            snapshot["keyHeight"] = invalidHeight; object["snapshot"] = snapshot
            XCTAssertThrowsError(try ClearKeyboard.AppearanceSyncClient.decode(JSONSerialization.data(withJSONObject: object)).get())
        }
        for invalidHeight in [Double.nan, .infinity, -.infinity] {
            var settings = ClearKeyboard.KeyboardSettings(); settings.keyHeight = invalidHeight
            let normalized = ClearKeyboard.AppearanceSnapshot(settings: settings)
            XCTAssertEqual(normalized.keyHeight, 50); XCTAssertTrue(normalized.isValid)
        }
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
    func testLegacyAppearanceWithoutHeightPreservesReceiverLayoutAndStillConfirmsReceipt() async throws {
        let source = try ClearKeyboard.AppearanceSyncClient.encode(envelope()).get()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        var fields = try XCTUnwrap(object["snapshot"] as? [String: Any])
        fields.removeValue(forKey: "keyHeight"); object["snapshot"] = fields
        let data = try JSONSerialization.data(withJSONObject: object)
        let legacy = try ClearKeyboard.AppearanceSyncClient.decode(data).get()
        XCTAssertNil(legacy.snapshot.keyHeight)
        var keyboardSettings = ClearKeyboard.KeyboardSettings()
        keyboardSettings.keyHeight = 57; keyboardSettings.language = .english; keyboardSettings.learnChoices = false
        var appSettings = ClearKeyboard.KeyboardSettings(); appSettings.keyHeight = 44
        let backend = AppearanceMemoryBackend()
        backend.seed(data, account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
        let appClient = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let keyboardClient = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let identity = receiver()
        let app = ClearKeyboard.AppearanceSettingsLink(role: .app, client: appClient, expectedReceiver: identity)
        let keyboard = ClearKeyboard.AppearanceSettingsLink(role: .keyboard, client: keyboardClient, receiverIdentity: identity)
        var confirmed = false, deliveries = 0
        app.currentSettings = { appSettings }; app.onReceive = { appSettings = $0.applying(to: appSettings) }
        app.onStatus = { confirmed = confirmed || $0 == .receivedByKeyboard }
        keyboard.currentSettings = { keyboardSettings }
        keyboard.onReceive = { keyboardSettings = $0.applying(to: keyboardSettings); deliveries += 1 }
        app.activate(); keyboard.activate()
        defer { app.deactivate(); keyboard.deactivate() }
        try await waitFor({ confirmed }, message: "A compatible legacy appearance could not acknowledge its requested fields")
        XCTAssertEqual(keyboardSettings.keyHeight, 57); XCTAssertEqual(appSettings.keyHeight, 44)
        XCTAssertEqual(keyboardSettings.language, .english); XCTAssertFalse(keyboardSettings.learnChoices)
        XCTAssertTrue(legacy.snapshot.isApplied(to: keyboardSettings))
        XCTAssertNotEqual(ClearKeyboard.AppearanceSnapshot(settings: keyboardSettings), legacy.snapshot,
                          "Strict snapshot equality must not turn an absent height into a wildcard")
        let received = expectation(description: "legacy exact request receipt read")
        appClient.readReceipt { result in
            do {
                let receipt = try XCTUnwrap(result.get()).receipt
                XCTAssertEqual(receipt.revision, legacy.revision); XCTAssertEqual(receipt.snapshot, legacy.snapshot)
                XCTAssertNil(receipt.snapshot.keyHeight)
            } catch { XCTFail("\(error)") }
            received.fulfill()
        }
        await fulfillment(of: [received], timeout: 3)
        keyboard.refresh()
        let drained = expectation(description: "same legacy revision refresh settled")
        keyboardClient.flush { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertEqual(deliveries, 1, "The omitted height must not cause repeated delivery or receipt loops")
        XCTAssertEqual(backend.writesByAccount[ClearKeyboard.AppearanceSyncClient.receiptAccount], 1)
    }
    func testHeightOnlyEditsCrossAppearanceChannelAndReceiptsMatchActualHeight() async throws {
        var appSettings = ClearKeyboard.KeyboardSettings(); appSettings.keyHeight = 58
        var keyboardSettings = ClearKeyboard.KeyboardSettings()
        keyboardSettings.keyHeight = 44; keyboardSettings.language = .english
        keyboardSettings.learnChoices = false; keyboardSettings.predictions = false
        keyboardSettings.hand = .left; keyboardSettings.vibrationEnabled = true
        let backend = AppearanceMemoryBackend(), identity = receiver()
        let initial = ClearKeyboard.AppearanceEnvelope(snapshot: ClearKeyboard.AppearanceSnapshot(settings: appSettings))
        backend.seed(try ClearKeyboard.AppearanceSyncClient.encode(initial).get(), account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
        let appClient = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let keyboardClient = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let app = ClearKeyboard.AppearanceSettingsLink(role: .app, client: appClient, expectedReceiver: identity)
        let keyboard = ClearKeyboard.AppearanceSettingsLink(role: .keyboard, client: keyboardClient, receiverIdentity: identity)
        var states: [ClearKeyboard.AppearanceSettingsLink.Status] = []
        app.currentSettings = { appSettings }; app.onReceive = { appSettings = $0.applying(to: appSettings) }
        app.onStatus = { states.append($0) }
        keyboard.currentSettings = { keyboardSettings }; keyboard.onReceive = { keyboardSettings = $0.applying(to: keyboardSettings) }
        app.activate(); keyboard.activate()
        defer { app.deactivate(); keyboard.deactivate() }
        try await waitFor({ states.contains(.receivedByKeyboard) }, message: "The initial height did not reach its receiver")
        XCTAssertEqual(keyboardSettings.keyHeight, 58)
        appSettings.keyHeight = 44; states.removeAll(); app.publish(appSettings)
        let revision = try XCTUnwrap(app.diagnostics.latestRevision)
        XCTAssertNotEqual(revision, initial.revision, "A height-only change must create a new appearance revision")
        try await waitFor({ states.contains(.receivedByKeyboard) && keyboardSettings.keyHeight == 44 },
                          message: "A height-only App edit was not applied and confirmed")
        let received = expectation(description: "height receipt read")
        appClient.readReceipt { result in
            do {
                let receipt = try XCTUnwrap(result.get()).receipt
                XCTAssertEqual(receipt.revision, revision); XCTAssertEqual(receipt.snapshot.keyHeight, 44)
                XCTAssertEqual(receipt.snapshot, ClearKeyboard.AppearanceSnapshot(settings: keyboardSettings))
            } catch { XCTFail("\(error)") }
            received.fulfill()
        }
        await fulfillment(of: [received], timeout: 3)
        XCTAssertEqual(keyboardSettings.language, .english); XCTAssertFalse(keyboardSettings.learnChoices)
        XCTAssertFalse(keyboardSettings.predictions); XCTAssertEqual(keyboardSettings.hand, .full)
        XCTAssertEqual(keyboardSettings.vibrationEnabled, false, "Feedback is now an App-controlled synchronized setting")
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
        let snapshot = envelope().snapshot, identity = receiver()
        keyboard.writeReceipt(revision: received, snapshot: snapshot, receiver: identity) { result in
            XCTAssertEqual(try? result.get().revision, received); saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 3)
        app.readReceipt { result in
            do {
                let receipt = try XCTUnwrap(result.get())
                XCTAssertEqual(receipt.receipt.revision, received); XCTAssertNotEqual(receipt.receipt.revision, different)
                XCTAssertEqual(receipt.receipt.snapshot, snapshot); XCTAssertEqual(receipt.receipt.receiver, identity)
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
        // The old schema only recorded transport revision, so it cannot prove
        // which installed extension applied which appearance after an upgrade.
        let legacy = Data("{\"schema\":1,\"revision\":\"\(UUID().uuidString)\",\"updatedAt\":0}".utf8)
        XCTAssertThrowsError(try ClearKeyboard.AppearanceSyncClient.decodeReceipt(legacy).get())
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
        let link = ClearKeyboard.AppearanceSettingsLink(role: .keyboard, client: client, receiverIdentity: receiver())
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
        XCTAssertThrowsError(try backend.write(data, account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get())
        XCTAssertEqual(backend.diagnostics.fileWrite, "failed")
        XCTAssertNotNil(backend.diagnostics.fileWriteError)
        XCTAssertEqual(backend.diagnostics.keychainWriteStatus, errSecMissingEntitlement)
        XCTAssertNil(backend.diagnostics.selectedChannel)
        XCTAssertEqual(keychain.writes, 0)
        XCTAssertThrowsError(try backend.write(data, account: "../outside").get())
    }
    func testDynamicGroupContainerRecoversAfterInitiallyUnavailableCapability() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clear.appearance.recovered." + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = AppearanceMemoryBackend()
        keychain.readFailure = .keychain(errSecMissingEntitlement)
        keychain.writeFailure = .keychain(errSecMissingEntitlement)
        var available = false, resolutions = 0
        let backend = ClearKeyboard.AppearanceMirroredBackend(groupRootProvider: {
            resolutions += 1; return available ? root : nil
        }, configuredGroup: "fixture.dynamic.group", keychain: keychain)
        let value = envelope(), data = try ClearKeyboard.AppearanceSyncClient.encode(value).get()
        XCTAssertThrowsError(try backend.read(account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get())
        XCTAssertThrowsError(try backend.write(data, account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get())
        XCTAssertFalse(backend.diagnostics.containerAvailable)
        available = true
        XCTAssertEqual(try backend.write(data, account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get(), "app-group")
        let received = try XCTUnwrap(backend.read(account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get())
        XCTAssertEqual(try ClearKeyboard.AppearanceSyncClient.decode(received.data).get(), value)
        XCTAssertEqual(resolutions, 4, "An unavailable container must be resolved again on each later I/O")
        XCTAssertTrue(backend.diagnostics.containerAvailable)
        XCTAssertEqual(backend.diagnostics.configuredGroup, "fixture.dynamic.group")
        XCTAssertEqual(backend.diagnostics.selectedChannel, "app-group")
    }
    func testAvailableGroupURLDoesNotTurnUnreadableOrMissingStorageIntoSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clear.appearance.read-errors." + UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("Appearance-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = AppearanceMemoryBackend(); keychain.readFailure = .keychain(errSecMissingEntitlement)
        let backend = ClearKeyboard.AppearanceMirroredBackend(groupRoot: root, keychain: keychain)
        // A genuine group URL says nothing about the result of reading it.
        XCTAssertThrowsError(try backend.read(account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get()) {
            XCTAssertEqual($0 as? ClearKeyboard.AppearanceSyncError, .keychain(errSecMissingEntitlement))
        }
        XCTAssertEqual(backend.diagnostics.fileRead, "missing")
        let file = directory.appendingPathComponent("appearance.json")
        try Data("malformed".utf8).write(to: file)
        XCTAssertThrowsError(try backend.read(account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get()) {
            XCTAssertEqual($0 as? ClearKeyboard.AppearanceSyncError, .invalidPayload)
        }
        XCTAssertEqual(backend.diagnostics.fileRead, "invalid-payload")
        XCTAssertEqual(backend.diagnostics.keychainReadStatus, errSecMissingEntitlement)
        XCTAssertNil(backend.diagnostics.selectedChannel)
        // An unavailable compatible record cannot hide the corrupt group file.
        keychain.readFailure = nil
        XCTAssertThrowsError(try backend.read(account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get())
    }
    func testPersistSignalRunsAfterActualSaveWhileMainCompletionIsNotYetRunning() async throws {
        let backend = AppearanceMemoryBackend(), client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let value = envelope(), probe = AppearancePersistenceProbe(), signal = DispatchSemaphore(value: 0)
        let completed = expectation(description: "main completion eventually delivered")
        client.publish(value, didPersist: {
            XCTAssertFalse(Thread.isMainThread)
            do {
                let record = try XCTUnwrap(backend.read(account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get())
                XCTAssertEqual(try ClearKeyboard.AppearanceSyncClient.decode(record.data).get(), value)
            } catch { XCTFail("Persistence notification preceded the real save: \(error)") }
            probe.append("persisted"); signal.signal()
        }) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result.get().revision, value.revision)
            probe.append("completion"); completed.fulfill()
        }
        // This bounded main-thread hold models an App that has not resumed its
        // UI callback. The receiver notification must already be independent.
        XCTAssertEqual(signal.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(probe.events, ["persisted"])
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(probe.events, ["persisted", "completion"])
    }
    func testFailedSaveDoesNotEmitPersistSignalOrReceiverReceipt() async {
        let backend = AppearanceMemoryBackend(); backend.writeFailure = .keychain(errSecMissingEntitlement)
        let client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let probe = AppearancePersistenceProbe(), completed = expectation(description: "failed write completed")
        let value = envelope()
        client.publish(value, didPersist: { probe.append("false-save") }) { result in
            if case .failure(.keychain(errSecMissingEntitlement)) = result {} else { XCTFail("Expected the actual denied save result") }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 3)
        let receipt = expectation(description: "failed receipt completed")
        client.writeReceipt(revision: value.revision, snapshot: value.snapshot, receiver: receiver(),
                            didPersist: { probe.append("false-receipt") }) { result in
            if case .failure(.keychain(errSecMissingEntitlement)) = result {} else { XCTFail("Expected the actual denied receipt result") }
            receipt.fulfill()
        }
        await fulfillment(of: [receipt], timeout: 3)
        XCTAssertTrue(probe.events.isEmpty)
        XCTAssertEqual(backend.writes, 0)
    }
    func testDeactivationFlushCompletionWaitsForDurableSaveAndEmitsNotification() async throws {
        let backend = AppearanceMemoryBackend()
        let client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 30)
        let link = ClearKeyboard.AppearanceSettingsLink(role: .app, client: client)
        let desired = envelope().snapshot.applying(to: ClearKeyboard.KeyboardSettings())
        link.currentSettings = { desired }
        link.publish(desired)
        let revision = try XCTUnwrap(link.diagnostics.latestRevision)
        XCTAssertTrue(link.hasPendingWrite)
        let completed = expectation(description: "deactivation flush completed")
        let notified = expectation(description: "real durable revision notification observed")
        let probe = AppearancePersistenceProbe(notificationCheck: {
            guard case .success(let record?) = backend.read(account: ClearKeyboard.AppearanceSyncClient.settingsAccount),
                  let value = try? ClearKeyboard.AppearanceSyncClient.decode(record.data).get() else { return false }
            return value.revision == revision
        }, notificationObserved: { notified.fulfill() })
        let center = CFNotificationCenterGetDarwinNotifyCenter(), pointer = Unmanaged.passUnretained(probe).toOpaque()
        CFNotificationCenterAddObserver(center, pointer, { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<AppearancePersistenceProbe>.fromOpaque(observer).takeUnretainedValue().receiveNotification()
        }, ClearKeyboard.AppearanceSettingsLink.notification as CFString, nil, .deliverImmediately)
        defer { CFNotificationCenterRemoveEveryObserver(center, pointer) }
        link.deactivate {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(link.hasPendingWrite)
            XCTAssertFalse(link.diagnostics.active)
            XCTAssertEqual(backend.writesByAccount[ClearKeyboard.AppearanceSyncClient.settingsAccount], 1)
            do {
                let record = try XCTUnwrap(backend.read(account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get())
                XCTAssertEqual(try ClearKeyboard.AppearanceSyncClient.decode(record.data).get().revision, revision)
            } catch { XCTFail("Deactivation completed before a durable write: \(error)") }
            completed.fulfill()
        }
        // The finite flush must bypass the 30-second slider debounce. Darwin
        // delivery is asynchronous, so its observer is awaited independently.
        await fulfillment(of: [completed, notified], timeout: 3)
        XCTAssertTrue(probe.events.contains("notification"))
    }
    func testRefreshBeforeMainWriteCompletionDoesNotSaveSameRevisionAgain() async {
        let backend = AppearanceMemoryBackend(), savedOnQueue = DispatchSemaphore(value: 0)
        backend.didWrite = { account in
            if account == ClearKeyboard.AppearanceSyncClient.settingsAccount { savedOnQueue.signal() }
        }
        let client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let link = ClearKeyboard.AppearanceSettingsLink(role: .app, client: client)
        let desired = envelope().snapshot.applying(to: ClearKeyboard.KeyboardSettings())
        link.currentSettings = { desired }
        link.publish(desired)
        XCTAssertEqual(savedOnQueue.wait(timeout: .now() + 2), .success)
        // Persistence has happened, but the main save callback cannot have
        // cleared pendingEnvelope yet. Repeated activation/notifications race here.
        link.activate(); defer { link.deactivate() }
        for _ in 0..<20 { link.activate(); link.refresh() }
        let drained = expectation(description: "queued writes drained")
        client.flush { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertEqual(backend.writesByAccount[ClearKeyboard.AppearanceSyncClient.settingsAccount], 1)
    }
    func testEarlyReceiptIsReadAfterPendingWriteCompletionWithoutAnotherUserAction() async throws {
        let backend = AppearanceMemoryBackend(), savedOnQueue = DispatchSemaphore(value: 0)
        backend.didWrite = { account in
            if account == ClearKeyboard.AppearanceSyncClient.settingsAccount { savedOnQueue.signal() }
        }
        let client = ClearKeyboard.AppearanceSyncClient(backend: backend, coalesceInterval: 0)
        let identity = receiver(), link = ClearKeyboard.AppearanceSettingsLink(role: .app,
            client: client, expectedReceiver: identity)
        let desired = envelope().snapshot.applying(to: ClearKeyboard.KeyboardSettings())
        link.currentSettings = { desired }
        var confirmed = false
        link.onStatus = { confirmed = confirmed || $0 == .receivedByKeyboard }
        link.publish(desired)
        let revision = try XCTUnwrap(link.diagnostics.latestRevision)
        XCTAssertEqual(savedOnQueue.wait(timeout: .now() + 2), .success)
        let receipt = ClearKeyboard.AppearanceReceipt(revision: revision,
            snapshot: ClearKeyboard.AppearanceSnapshot(settings: desired), receiver: identity)
        backend.seed(try ClearKeyboard.AppearanceSyncClient.encodeReceipt(receipt).get(), account: ClearKeyboard.AppearanceSyncClient.receiptAccount)
        // The receiver's response is already durable, and this activation hint
        // occurs before the pending main save callback. No later edit or manual
        // refresh is provided to rescue an acknowledgement that was skipped.
        link.activate(); defer { link.deactivate() }
        try await waitFor({ confirmed }, message: "An early receiver reply was permanently hidden by the pending-write guard")
        XCTAssertEqual(link.diagnostics.receiptRevision, revision)
        XCTAssertEqual(backend.writesByAccount[ClearKeyboard.AppearanceSyncClient.settingsAccount], 1)
    }
    func testAppConfirmationRequiresExactRevisionSnapshotAndReceiverVersion() async throws {
        let value = envelope(), identity = receiver()
        var differentSettings = ClearKeyboard.KeyboardSettings(); differentSettings.keyColorHex = "#FFFFFF"
        let differentSnapshot = ClearKeyboard.AppearanceSnapshot(settings: differentSettings)
        let invalidReceipts = [
            ClearKeyboard.AppearanceReceipt(revision: UUID(), snapshot: value.snapshot, receiver: identity),
            ClearKeyboard.AppearanceReceipt(revision: value.revision, snapshot: differentSnapshot, receiver: identity),
            ClearKeyboard.AppearanceReceipt(revision: value.revision, snapshot: value.snapshot, receiver: receiver(build: "52"))
        ]
        for receipt in invalidReceipts {
            let backend = AppearanceMemoryBackend()
            backend.seed(try ClearKeyboard.AppearanceSyncClient.encode(value).get(), account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
            backend.seed(try ClearKeyboard.AppearanceSyncClient.encodeReceipt(receipt).get(), account: ClearKeyboard.AppearanceSyncClient.receiptAccount)
            let link = ClearKeyboard.AppearanceSettingsLink(role: .app,
                client: ClearKeyboard.AppearanceSyncClient(backend: backend), expectedReceiver: identity)
            var states: [ClearKeyboard.AppearanceSettingsLink.Status] = []
            link.onStatus = { states.append($0) }
            link.currentSettings = { value.snapshot.applying(to: ClearKeyboard.KeyboardSettings()) }
            link.activate()
            try await waitFor({ states.contains(.waitingForKeyboard) }, message: "A mismatched receiver must remain unconfirmed")
            XCTAssertFalse(states.contains(.receivedByKeyboard))
            XCTAssertEqual(link.diagnostics.rejection, "receipt-identity-revision-or-snapshot-mismatch")
            link.deactivate()
        }
        let backend = AppearanceMemoryBackend()
        backend.seed(try ClearKeyboard.AppearanceSyncClient.encode(value).get(), account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
        backend.seed(try ClearKeyboard.AppearanceSyncClient.encodeReceipt(ClearKeyboard.AppearanceReceipt(revision: value.revision,
            snapshot: value.snapshot, receiver: identity)).get(), account: ClearKeyboard.AppearanceSyncClient.receiptAccount)
        let link = ClearKeyboard.AppearanceSettingsLink(role: .app,
            client: ClearKeyboard.AppearanceSyncClient(backend: backend), expectedReceiver: identity)
        var received = false; link.onStatus = { received = received || $0 == .receivedByKeyboard }
        link.activate(); defer { link.deactivate() }
        try await waitFor({ received }, message: "An exact applied receipt was not accepted")
        XCTAssertEqual(link.diagnostics.receiptRevision, value.revision)
        XCTAssertNil(link.diagnostics.rejection)
    }
    func testAppTestHostAndUnappliedKeyboardCannotProduceReceiverProof() async throws {
        XCTAssertNil(ClearKeyboard.AppearanceReceiverIdentity.keyboardBundle(.main), "The unit-test App is not the installed keyboard extension")
        let value = envelope()
        for identity in [nil, receiver()] as [ClearKeyboard.AppearanceReceiverIdentity?] {
            let backend = AppearanceMemoryBackend()
            backend.seed(try ClearKeyboard.AppearanceSyncClient.encode(value).get(), account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
            let client = ClearKeyboard.AppearanceSyncClient(backend: backend)
            let link = ClearKeyboard.AppearanceSettingsLink(role: .keyboard, client: client, receiverIdentity: identity)
            link.currentSettings = { ClearKeyboard.KeyboardSettings() }
            // Deliberately decline to apply onReceive: transport receipt alone
            // must not be promoted to a model or rendering confirmation.
            link.onReceive = { _ in }
            link.activate()
            try await waitFor({ link.diagnostics.rejection != nil }, message: "An unverified receiver was silently accepted")
            XCTAssertNil(link.diagnostics.appliedRevision)
            XCTAssertNil(backend.writesByAccount[ClearKeyboard.AppearanceSyncClient.receiptAccount])
            XCTAssertEqual(link.diagnostics.rejection, identity == nil ? "receiver-is-not-a-keyboard-extension" : "model-snapshot-not-applied")
            link.deactivate()
        }
    }
    func testReceiptWriteFailureRetriesAfterCapabilityRecovers() async throws {
        let value = envelope(), backend = AppearanceMemoryBackend()
        backend.seed(try ClearKeyboard.AppearanceSyncClient.encode(value).get(), account: ClearKeyboard.AppearanceSyncClient.settingsAccount)
        backend.writeFailure = .keychain(errSecInteractionNotAllowed)
        let link = ClearKeyboard.AppearanceSettingsLink(role: .keyboard,
            client: ClearKeyboard.AppearanceSyncClient(backend: backend), receiverIdentity: receiver())
        var settings = ClearKeyboard.KeyboardSettings()
        link.currentSettings = { settings }; link.onReceive = { settings = $0.applying(to: settings) }
        link.activate(); defer { link.deactivate() }
        try await waitFor({ link.diagnostics.event == "receipt-write-failed" }, message: "A failed acknowledgement was reported as success")
        XCTAssertNil(link.diagnostics.receiptRevision)
        backend.writeFailure = nil
        link.activate()
        try await waitFor({ link.diagnostics.receiptRevision == value.revision }, message: "Repeated activation failed to retry the blocked receipt")
        XCTAssertEqual(backend.writesByAccount[ClearKeyboard.AppearanceSyncClient.receiptAccount], 1)
    }
    func testDiagnosticPayloadContainsCapabilitiesAndNoInputOrAppearanceValues() throws {
        let backend = AppearanceMemoryBackend(); backend.readFailure = .keychain(errSecMissingEntitlement)
        let mirror = ClearKeyboard.AppearanceMirroredBackend(groupRoot: nil, keychain: backend)
        XCTAssertThrowsError(try mirror.read(account: ClearKeyboard.AppearanceSyncClient.settingsAccount).get())
        var value = ClearKeyboard.AppearanceSyncDiagnostics()
        value.backend = mirror.diagnostics; value.receiver = receiver(); value.event = "read-failed"
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let status = try XCTUnwrap(object["backend"] as? [String: Any])
        XCTAssertEqual(status["keychainReadStatus"] as? Int, Int(errSecMissingEntitlement))
        XCTAssertEqual(status["fileRead"] as? String, "container-unavailable")
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["snapshot", "candidateColorHex", "clipboardContents", "composition", "learnedWords", "containerPath"] {
            XCTAssertFalse(text.contains(forbidden), "Diagnostics accidentally included private settings/input: " + forbidden)
        }
        XCTAssertLessThan(data.count, 2_048)
    }
}
