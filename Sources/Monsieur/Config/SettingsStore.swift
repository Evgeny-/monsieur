import Foundation
import Combine

/// Owns `settings.json`. Deliberately a plain readable file rather than the
/// Keychain: you asked to be able to edit it by hand. It is watched, so an
/// external edit is picked up live without restarting the app.
@MainActor
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue, !isApplyingExternalChange else { return }
            save()
        }
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var isApplyingExternalChange = false

    static var directory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Monsieur", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("settings.json") }
    static var historyURL: URL { directory.appendingPathComponent("history.jsonl") }

    private init() {
        try? FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true)
        settings = Self.loadFromDisk() ?? Settings()
        if !FileManager.default.fileExists(atPath: Self.fileURL.path) {
            save()
        }
        startWatching()
    }

    // MARK: - Disk

    private static func loadFromDisk() -> Settings? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            Log.config.error("settings.json is not valid JSON: \(error.localizedDescription)")
            return nil
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(settings) else { return }
        // Suspend the watcher so our own write does not bounce back at us.
        stopWatching()
        defer { startWatching() }
        do {
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            Log.config.error("could not write settings.json: \(error.localizedDescription)")
        }
    }

    func reload() {
        guard let fresh = Self.loadFromDisk(), fresh != settings else { return }
        isApplyingExternalChange = true
        settings = fresh
        isApplyingExternalChange = false
        Log.config.info("reloaded settings.json after an external edit")
        NotificationCenter.default.post(name: .settingsChangedExternally, object: nil)
    }

    // MARK: - Live reload

    private func startWatching() {
        guard watcher == nil else { return }
        let fd = open(Self.fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend],
            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Most editors replace rather than modify; re-arm on the new inode.
                self.stopWatching()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.reload()
                    self.startWatching()
                }
            } else {
                self.reload()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    // MARK: - Bootstrapping from .env files

    /// Pulls `ELEVENLABS_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` out of a
    /// dotenv file. Only fills in fields that are currently empty.
    @discardableResult
    func importKeys(fromEnvFile url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq])
                .replacingOccurrences(of: "export ", with: "")
                .trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last,
               f == l, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }
            found[key] = value
        }

        var imported: [String] = []
        if settings.elevenLabsAPIKey.isEmpty, let v = found["ELEVENLABS_API_KEY"] ?? found["XI_API_KEY"] {
            settings.elevenLabsAPIKey = v; imported.append("ElevenLabs")
        }
        if settings.openAIAPIKey.isEmpty, let v = found["OPENAI_API_KEY"] {
            settings.openAIAPIKey = v; imported.append("OpenAI")
        }
        if settings.anthropicAPIKey.isEmpty, let v = found["ANTHROPIC_API_KEY"] {
            settings.anthropicAPIKey = v; imported.append("Anthropic")
        }
        return imported
    }
}

extension Notification.Name {
    static let settingsChangedExternally = Notification.Name("settingsChangedExternally")
}
