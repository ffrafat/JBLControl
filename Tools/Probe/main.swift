// Read-only BLE probe for JBL speakers. Sends only request commands; never writes settings.
import CoreBluetooth
import Foundation

let service = CBUUID(string: "65786365-6C70-6F69-6E74-2E636F6D0000")
let rxNotify = CBUUID(string: "65786365-6C70-6F69-6E74-2E636F6D0001")
let txWrite = CBUUID(string: "65786365-6C70-6F69-6E74-2E636F6D0002")

// Read-only requests: device info (both framings), firmware version, EQ mode, advanced EQ.
let defaultRequests: [(String, [UInt8])] = [
    ("speaker info (AA 11)", [0xAA, 0x11]),
    ("speaker info (AA 11 00)", [0xAA, 0x11, 0x00]),
    ("firmware version (41)", [0xAA, 0x41, 0x00]),
    ("EQ mode (61)", [0xAA, 0x61, 0x00]),
    ("advanced EQ (98)", [0xAA, 0x98, 0x00, 0x00]),
]

// Optional override: each argument is "label=HEX". Used for controlled write/readback tests.
let requests: [(String, [UInt8])] = {
    let args = CommandLine.arguments.dropFirst().filter { $0.contains("=") }
    guard !args.isEmpty else { return defaultRequests }
    return args.map { arg in
        let parts = arg.split(separator: "=", maxSplits: 1)
        let h = Array(parts[1].filter(\.isHexDigit))
        let bytes = stride(from: 0, to: h.count, by: 2).map { UInt8(String(h[$0..<$0 + 2]), radix: 16)! }
        return (String(parts[0]), bytes)
    }
}()

func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: " ") }
func log(_ s: String) {
    let ts = String(format: "%.2f", Date().timeIntervalSince(start))
    print("[\(ts)] \(s)")
    fflush(stdout)
}
let start = Date()

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var target: CBPeripheral?
    var tx: CBCharacteristic?
    var seen = Set<UUID>()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("central state: \(c.state.rawValue) (5 = poweredOn, 3 = unauthorized)")
        guard c.state == .poweredOn else { return }
        let connected = c.retrieveConnectedPeripherals(withServices: [service])
        log("already-connected peripherals with JBL service: \(connected.map { $0.name ?? "?" })")
        if let p = connected.first { connect(p); return }
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        log("scanning…")
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let sd = ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let mfg = ad[CBAdvertisementDataManufacturerDataKey] as? Data
        let harman = sd.keys.contains { ["FDDF", "FC69", "DFFD", "0ECB"].contains($0.uuidString) }
        guard name.localizedCaseInsensitiveContains("JBL") || harman else { return }
        guard seen.insert(p.identifier).inserted else { return }
        log("found '\(name)' rssi=\(rssi) id=\(p.identifier)")
        for (k, v) in sd { log("  serviceData \(k.uuidString): \(hex(v))") }
        if let mfg { log("  manufacturerData: \(hex(mfg))") }
        if let su = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] { log("  services: \(su.map(\.uuidString))") }
        if target == nil { c.stopScan(); connect(p) }
    }

    func connect(_ p: CBPeripheral) {
        target = p
        p.delegate = self
        log("connecting to \(p.name ?? "?")…")
        central.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("connected; discovering services")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("connect failed: \(String(describing: error))"); exit(2)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            log("service \(s.uuid.uuidString)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            log("  char \(ch.uuid.uuidString) props=0x\(String(ch.properties.rawValue, radix: 16))")
        }
        guard s.uuid == service else { return }
        tx = s.characteristics?.first { $0.uuid == txWrite }
        if let rx = s.characteristics?.first(where: { $0.uuid == rxNotify }) { p.setNotifyValue(true, for: rx) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        log("notify on \(ch.uuid.uuidString): \(ch.isNotifying) err=\(String(describing: error))")
        guard ch.isNotifying else { return }
        log("max write len: \(p.maximumWriteValueLength(for: .withResponse))")
        sendNext(0)
    }

    func sendNext(_ i: Int) {
        guard i < requests.count, let tx, let p = target else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { log("done"); exit(0) }
            return
        }
        let (label, bytes) = requests[i]
        log(">>> \(label): \(hex(Data(bytes)))")
        p.writeValue(Data(bytes), for: tx, type: .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.sendNext(i + 1) }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let error { log("write error: \(error)") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        log("<<< \(ch.uuid.uuidString.suffix(4)): \(hex(ch.value ?? Data()))")
    }
}

let probe = Probe()
DispatchQueue.main.asyncAfter(deadline: .now() + 45) { log("timeout"); exit(1) }
RunLoop.main.run()
