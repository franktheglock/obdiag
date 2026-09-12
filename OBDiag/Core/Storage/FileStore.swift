import Foundation

/// Lightweight JSON persistence in Application Support. All user data stays
/// on-device; nothing here touches the network.
enum FileStore {
    static let directoryName = "OBDiag"

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directoryURL.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    @discardableResult
    static func save<T: Encodable>(_ value: T, to name: String) -> Bool {
        let url = directoryURL.appendingPathComponent(name)
        guard let data = try? encoder.encode(value) else { return false }
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    static func delete(_ name: String) {
        let url = directoryURL.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteAll() {
        let url = directoryURL
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
        for item in contents { try? FileManager.default.removeItem(at: item) }
    }

    static var debugExportURL: URL { directoryURL }
}
