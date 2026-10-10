import AppKit
import os

/// Downloads official product photos on first use and caches them in ~/Library/Caches.
/// Photos are Harman's; they're fetched from jbl.com rather than shipped in this repository.
@MainActor
final class PhotoStore {
    static let shared = PhotoStore()

    private var memory: [String: NSImage] = [:]
    private let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("io.github.jblcontrol/photos", isDirectory: true)
    }()

    func photo(for productID: UInt16, color: UInt8) async -> NSImage? {
        guard let path = PhotoSources.path(productID: productID, color: color) else { return nil }
        let key = String(format: "%04X-%02X", productID, color)
        if let image = memory[key] { return image }

        let file = cacheDir.appendingPathComponent("\(key).png")
        if let image = NSImage(contentsOf: file) {
            memory[key] = image
            return image
        }
        guard let url = URL(string: PhotoSources.base + path + "?sw=600&sfrm=png") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return nil }
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? data.write(to: file)
            memory[key] = image
            return image
        } catch {
            log.notice("photo download failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Product photo paths on JBL's image CDN, by product ID and color code.
/// Contributions welcome: open the model's page on jbl.com and copy the hero image paths.
enum PhotoSources {
    static let base = "https://www.jbl.com/dw/image/v2/BFND_PRD/on/demandware.static/-/Sites-masterCatalog_Harman/default/"

    static func path(productID: UInt16, color: UInt8) -> String? {
        guard let colors = table[productID] else { return nil }
        return colors[color] ?? colors[0x00]
    }

    static let table: [UInt16: [UInt8: String]] = [
        // JBL Flip 7
        0x2107: [
            0x00: "dwf90f0f82/JBL_FLIP_7_HERO_BLACK_060_x2.png",
            0x01: "dwf90f0f82/JBL_FLIP_7_HERO_BLACK_060_x2.png",
            0x02: "dw68e4981d/JBL_FLIP_7_HERO_RED_071_x2.png",
            0x03: "dwad0b22ea/JBL_FLIP_7_HERO_BLUE_079_x1.png",
            0x04: "dw4519caa2/JBL_FLIP_7_HERO_WHITE_066_x1.png",
            0x08: "dwb5cb36d4/JBL_FLIP_7_HERO_SAND_076_x2.png",
            0x10: "dw3b5c0498/JBL_FLIP_7_HERO_PINK_068_x1.png",
            0x13: "dwf45a2daf/JBL_FLIP_7_HERO_SQUAD_054_x2.png",
            0x14: "dwa1a4a194/JBL_FLIP_7_HERO_PURPLE_079_x2.png",
            0x15: "dwb04e11a4/JBL_FLIP_7_HERO_FUNKY_BLACK_055_x2.png",
            0x18: "dw582e6b32/LS_JBL_FLIP_7_HERO_TURQUOISE_066_x2.png",
        ],
    ]
}
