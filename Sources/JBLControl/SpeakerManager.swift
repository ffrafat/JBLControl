import AppKit
import CoreBluetooth
import JBLControlKit
import Observation
import os

let log = Logger(subsystem: "io.github.jblcontrol", category: "ble")

/// A JBL speaker seen advertising nearby.
struct DiscoveredSpeaker: Identifiable {
    let peripheral: CBPeripheral
    var name: String
    var productID: UInt16?
    var rssi: Int
    var advertisement: [String: String]
    var id: UUID { peripheral.identifier }
    var model: SpeakerModel? { Catalog.model(productID) }
}

/// Owns the BLE link to one JBL speaker and mirrors its state for the UI.
@MainActor @Observable
final class SpeakerManager: NSObject {
    enum Status: Equatable {
        case bluetoothOff, unauthorized, searching, connecting, connected
    }

    private(set) var status: Status = .searching
    private(set) var discovered: [DiscoveredSpeaker] = []
    private(set) var name: String?
    private(set) var productID: UInt16?
    private(set) var colorCode: UInt8?
    private(set) var battery: Int?
    private(set) var firmware: String?
    private(set) var eq: EQSnapshot?
    /// Last known custom curve; survives replies that don't carry it.
    private(set) var customGains: [Float] = []
    private(set) var traffic: [TrafficEntry] = []

    var allowExperimentalWrites: Bool = UserDefaults.standard.bool(forKey: "allowExperimentalWrites") {
        didSet { UserDefaults.standard.set(allowExperimentalWrites, forKey: "allowExperimentalWrites") }
    }

    var model: SpeakerModel? { Catalog.model(productID) }
    var activePreset: EQPreset? { eq.flatMap { e in model?.pickerPresets.first { $0.category == e.activeCategory } } }
    var isCustomActive: Bool { eq != nil && eq?.activeCategory == model?.customCategory }
    var canWrite: Bool { model.map { !$0.writesNeedOptIn || allowExperimentalWrites } ?? false }
    var connectedID: UUID? { status == .connected ? peripheral?.identifier : nil }
    /// The speaker being controlled or connected to.
    var activeID: UUID? { peripheral?.identifier }
    /// Nearby speakers the user can switch to (supported models, strongest signal first).
    var switchable: [DiscoveredSpeaker] {
        discovered.filter { $0.model.map { $0.support != .unsupported } ?? false }.sorted { $0.rssi > $1.rssi }
    }

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var tx: CBCharacteristic?
    @ObservationIgnored private var decoder = MessageDecoder()
    @ObservationIgnored private var writeQueue: [Outgoing] = []
    @ObservationIgnored private var writing: Outgoing?
    // EQ writes: while one is in flight, newer ones replace each other, so a slider drag
    // sends at most one write per round trip.
    @ObservationIgnored private var eqInFlight = false
    @ObservationIgnored private var eqNext: [Data]?
    @ObservationIgnored private var eqTimeout: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var connectWatchdog: Task<Void, Never>?
    @ObservationIgnored private var browsing = false
    @ObservationIgnored private(set) var gattSummary: [String] = []

    private struct Outgoing {
        let data: Data
        let isEQWrite: Bool
    }

    private enum Saved {
        static let name = "savedSpeakerName"
        static let productID = "savedSpeakerPID"
        static let identifier = "savedSpeakerID"
    }

    private let service = CBUUID(string: JBL.serviceUUID)
    private let notifyUUID = CBUUID(string: JBL.notifyUUID)
    private let writeUUID = CBUUID(string: JBL.writeUUID)

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private var codec: EQCodec? { model.map(EQCodec.init) }

    // MARK: Actions

    /// While the panel is open, keep scanning so speakers turned on later show up to switch to.
    func panelOpened() {
        browsing = true
        // Drop speakers that may have gone away; anything still on air re-appears within a second.
        discovered.removeAll { $0.id != activeID }
        if central.state == .poweredOn { scan() }
        refresh()
    }

    func panelClosed() {
        browsing = false
        if status == .connected { central.stopScan() }
    }

    func refresh() {
        guard status == .connected else { return }
        enqueue([Frame.requestInfo.encoded] + (codec?.readRequests() ?? []))
    }

    func select(_ preset: EQPreset) {
        guard canWrite, let codec, var state = eq else { return }
        state.activeCategory = preset.category
        eq = state
        sendEQ(codec.select(preset, customGains: customGains))
    }

    func setCustomGain(_ gain: Float, band: Int) {
        guard canWrite, let codec, let model, model.customBands.indices.contains(band),
              customGains.indices.contains(band) else { return }
        let snapped = model.customBands[band].snap(gain)
        guard customGains[band] != snapped || !isCustomActive else { return }
        customGains[band] = snapped
        eq = EQSnapshot(activeCategory: model.customCategory, gains: customGains)
        sendEQ(codec.setCustom(customGains))
    }

    func resetCustom() {
        guard canWrite, let codec, let model else { return }
        customGains = Array(repeating: 0, count: model.customBands.count)
        eq = EQSnapshot(activeCategory: model.customCategory, gains: customGains)
        sendEQ(codec.setCustom(customGains))
    }

    /// Connect to a specific speaker from the list and remember it.
    func choose(_ speaker: DiscoveredSpeaker) {
        remember(name: speaker.name, productID: speaker.productID, id: speaker.id)
        clearDeviceState()
        name = nil; colorCode = nil; battery = nil; firmware = nil; eq = nil
        if let pid = speaker.productID { setProductID(pid) }
        connect(speaker.peripheral)
    }

    func forgetSpeaker() {
        for key in [Saved.name, Saved.productID, Saved.identifier] { UserDefaults.standard.removeObject(forKey: key) }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        clearDeviceState()
        name = nil; productID = nil; colorCode = nil; battery = nil; firmware = nil; eq = nil
        status = .searching
        scan()
    }

    // MARK: Connection

    private func startDiscovery() {
        guard central.state == .poweredOn else { return }
        if let saved = UserDefaults.standard.string(forKey: Saved.identifier).flatMap(UUID.init),
           let known = central.retrievePeripherals(withIdentifiers: [saved]).first {
            connect(known)
        }
        status = peripheral == nil ? .searching : .connecting
        scan()
    }

    /// Scanning continues until a link is up: speakers rotate their BLE address, so a remembered
    /// identifier can go stale and only a fresh advertisement leads back to it.
    private func scan() {
        central.stopScan()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connect(_ p: CBPeripheral) {
        if peripheral?.identifier != p.identifier, let old = peripheral {
            central.cancelPeripheralConnection(old)
        }
        peripheral = p
        p.delegate = self
        status = .connecting
        log.info("connecting to \(p.identifier, privacy: .public)")
        central.connect(p)
        connectWatchdog?.cancel()
        connectWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.status != .connected, self.peripheral?.identifier == p.identifier else { return }
            log.notice("connect to \(p.identifier, privacy: .public) stalled; rescanning")
            self.central.cancelPeripheralConnection(p)
            self.peripheral = nil
            self.status = .searching
            self.scan()
        }
    }

    private func remember(name: String?, productID: UInt16?, id: UUID) {
        let d = UserDefaults.standard
        d.set(id.uuidString, forKey: Saved.identifier)
        if let name { d.set(name, forKey: Saved.name) }
        if let productID { d.set(Int(productID), forKey: Saved.productID) }
    }

    /// The remembered speaker, matched by advertised name and model (identifiers rotate).
    private func isRemembered(_ s: DiscoveredSpeaker) -> Bool? {
        let d = UserDefaults.standard
        guard let savedName = d.string(forKey: Saved.name) else { return nil }
        let savedPID = d.object(forKey: Saved.productID) as? Int
        return s.name == savedName && (savedPID == nil || s.productID.map(Int.init) == savedPID)
    }

    private func clearDeviceState() {
        tx = nil
        writeQueue.removeAll()
        writing = nil
        eqInFlight = false
        eqNext = nil
        eqTimeout?.cancel()
        pollTask?.cancel()
    }

    // MARK: Writes

    private func enqueue(_ packets: [Data], eqWrite: Bool = false) {
        writeQueue += packets.map { Outgoing(data: $0, isEQWrite: eqWrite) }
        pump()
    }

    private func pump() {
        guard writing == nil, let tx, let peripheral, !writeQueue.isEmpty else { return }
        let next = writeQueue.removeFirst()
        writing = next
        record(.sent, next.data)
        peripheral.writeValue(next.data, for: tx, type: .withResponse)
    }

    private func sendEQ(_ packets: [Data]) {
        guard !packets.isEmpty else { return }
        if eqInFlight {
            eqNext = packets
            return
        }
        eqInFlight = true
        enqueue(packets, eqWrite: true)
        eqTimeout?.cancel()
        eqTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.eqWriteFinished()
        }
    }

    private func eqWriteFinished() {
        eqTimeout?.cancel()
        guard eqInFlight else { return }
        eqInFlight = false
        if let next = eqNext {
            eqNext = nil
            sendEQ(next)
        } else if let codec, !codec.writeRepliesWithState {
            // These families acknowledge without state; read it back to confirm.
            enqueue(codec.readRequests())
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.enqueue([Frame.requestInfo.encoded])
            }
        }
    }

    // MARK: Incoming

    private func handle(_ message: Incoming) {
        if let codec, let snapshot = codec.parse(message) {
            let superseded = eqNext != nil
            if eqInFlight { eqWriteFinished() }
            // A reply to an older write would undo a newer optimistic change; wait for the last one.
            if !superseded {
                if let gains = snapshot.gains { customGains = gains }
                eq = EQSnapshot(activeCategory: snapshot.activeCategory, gains: customGains)
            }
            return
        }
        guard case .legacy(let frame) = message else { return }
        switch Command(rawValue: frame.command) {
        case .info:
            guard let token = InfoToken.parse(frame.payload) else { return }
            switch token {
            case .name(let n): name = n
            case .productID(let pid): setProductID(pid)
            case .color(let c): colorCode = c
            case .battery(let b): battery = b
            case .firmware(let f): firmware = f
            default: break
            }
        case .version:
            firmware = FirmwareVersion.format(frame.payload)
        case .notifyEQChange:
            enqueue(codec?.readRequests() ?? [])
        case .unsupported:
            log.notice("speaker rejected command \(frame.payload.first ?? 0, format: .hex)")
            if [Command.setAdvancedEQ.rawValue, 0x6E].contains(frame.payload.first) { eqWriteFinished() }
        default:
            break
        }
    }

    private func setProductID(_ pid: UInt16) {
        guard productID != pid else { return }
        productID = pid
        if let model, customGains.count != model.customBands.count {
            customGains = Array(repeating: 0, count: model.customBands.count)
        }
    }

    // MARK: Diagnostics

    struct TrafficEntry {
        enum Direction { case sent, received }
        let date: Date
        let direction: Direction
        let data: Data
    }

    private func record(_ direction: TrafficEntry.Direction, _ data: Data) {
        traffic.append(TrafficEntry(date: .now, direction: direction, data: data))
        if traffic.count > 200 { traffic.removeFirst(traffic.count - 200) }
    }

    /// Sends every read-only request we know of, so the report shows how this speaker answers.
    func runDiagnosticProbe() async {
        guard status == .connected else { return }
        enqueue([
            Frame.requestInfo.encoded, Frame.requestVersion.encoded, Frame(0x61).encoded,
            Frame(0x6C, [0x00]).encoded, Frame.requestEQ.encoded,
        ] + P4Message.set([(P4EQ.query, [0xFF])]).packets)
        try? await Task.sleep(for: .seconds(3))
    }

    var currentAdvertisement: [String: String] {
        discovered.first { $0.id == peripheral?.identifier }?.advertisement ?? [:]
    }
}

// MARK: - CBCentralManagerDelegate

extension SpeakerManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: startDiscovery()
        case .unauthorized: status = .unauthorized
        default:
            status = .bluetoothOff
            clearDeviceState()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        let serviceData = ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let manufacturer = ad[CBAdvertisementDataManufacturerDataKey] as? Data
        let advertisedName = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let pid = manufacturer.flatMap(JBL.productID)
        let isJBL = serviceData.keys.contains { JBL.advertisedServiceIDs.contains($0.uuidString) }
            || advertisedName.localizedCaseInsensitiveContains("JBL") || pid != nil
        guard isJBL || discovered.contains(where: { $0.id == p.identifier }) else { return }

        var summary = ["name": advertisedName, "rssi": "\(rssi)"]
        if let manufacturer { summary["manufacturerData"] = manufacturer.hex }
        for (key, value) in serviceData { summary["serviceData.\(key.uuidString)"] = value.hex }
        var speaker = DiscoveredSpeaker(peripheral: p, name: advertisedName, productID: pid,
                                        rssi: rssi.intValue, advertisement: summary)
        if let i = discovered.firstIndex(where: { $0.id == p.identifier }) {
            // Advertisement and scan response arrive separately; merge rather than lose fields.
            let old = discovered[i]
            speaker.productID = pid ?? old.productID
            if advertisedName.isEmpty { speaker.name = old.name }
            speaker.advertisement = old.advertisement.merging(summary) { _, new in new }
            discovered[i] = speaker
        } else {
            log.info("found \(advertisedName, privacy: .public) pid \(pid ?? 0, format: .hex)")
            discovered.append(speaker)
        }

        // Auto-connect: the remembered speaker, or the first supported one when none is remembered.
        guard status != .connected, peripheral?.identifier != p.identifier,
              let model = speaker.model, model.support != .unsupported else { return }
        switch isRemembered(speaker) {
        case true?, nil:
            setProductID(model.productID)
            connect(p)
        case false?:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        log.info("connected to \(p.identifier, privacy: .public)")
        if !browsing { central.stopScan() }
        connectWatchdog?.cancel()
        let advertised = discovered.first { $0.id == p.identifier }
        remember(name: advertised?.name, productID: advertised?.productID ?? productID, id: p.identifier)
        gattSummary = []
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log.error("connect failed: \(error?.localizedDescription ?? "?", privacy: .public)")
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        log.notice("disconnected: \(error?.localizedDescription ?? "no error", privacy: .public)")
        clearDeviceState()
        connect(p)
        scan()
    }
}

// MARK: - CBPeripheralDelegate

extension SpeakerManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        gattSummary.append("service \(s.uuid.uuidString)")
        for c in s.characteristics ?? [] {
            gattSummary.append("  char \(c.uuid.uuidString) props=0x\(String(c.properties.rawValue, radix: 16))")
        }
        guard s.uuid == service else { return }
        tx = s.characteristics?.first { $0.uuid == writeUUID }
        if let rx = s.characteristics?.first(where: { $0.uuid == notifyUUID }) {
            p.setNotifyValue(true, for: rx)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c.isNotifying else { return }
        log.info("control channel ready")
        decoder = MessageDecoder()
        status = .connected
        enqueue([Frame.requestInfo.encoded, Frame.requestVersion.encoded] + (codec?.readRequests() ?? []))
        startPolling()
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { log.error("write failed: \(error.localizedDescription, privacy: .public)") }
        let finished = writing
        writing = nil
        if finished?.isEQWrite == true, codec?.writeRepliesWithState == false, writeQueue.allSatisfy({ !$0.isEQWrite }) {
            // Acknowledged at the ATT layer; give the speaker a moment before reading back.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.eqWriteFinished()
            }
        }
        pump()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let value = c.value else { return }
        record(.received, value)
        for message in decoder.feed(value) { handle(message) }
    }
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
