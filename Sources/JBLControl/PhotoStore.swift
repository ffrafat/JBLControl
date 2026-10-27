import AppKit

/// Official product photos, bundled in Resources/SpeakerPhotos (built by scripts/make-speaker-photos.py).
/// index.json maps product ID and color code to a file; colors without their own photo use code 00.
@MainActor
final class PhotoStore {
    static let shared = PhotoStore()

    private let folder = Bundle.main.resourceURL?.appendingPathComponent("SpeakerPhotos", isDirectory: true)
    private lazy var index: [String: [String: String]] = {
        guard let url = folder?.appendingPathComponent("index.json"),
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return index
    }()
    private var memory: [String: NSImage] = [:]

    func photo(for productID: UInt16, color: UInt8) -> NSImage? {
        guard let colors = index[String(format: "%04X", productID)],
              let name = colors[String(format: "%02X", color)] ?? colors["00"]
        else { return nil }
        if let image = memory[name] { return image }
        guard let url = folder?.appendingPathComponent(name), let image = NSImage(contentsOf: url) else { return nil }
        memory[name] = image
        return image
    }
}
