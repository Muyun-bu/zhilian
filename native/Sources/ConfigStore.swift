import Foundation

final class ConfigStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhilianNative", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("config.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> PersistedConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? decoder.decode(PersistedConfig.self, from: data) else { return PersistedConfig() }
        return config
    }

    func save(_ config: PersistedConfig) {
        guard let data = try? encoder.encode(config) else { return }
        let temporary = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        } catch {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
