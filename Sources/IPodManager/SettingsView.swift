import SwiftUI
import AppKit

enum AppLanguage {
    static let key = "appLanguage"
    /// Language the app was started with ("" = follow the system).
    static let atLaunch: String = UserDefaults.standard.string(forKey: key) ?? ""

    static func apply(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

enum Prefs {
    static let scTarget = "scTarget"
    static let scAlbumMode = "scAlbumMode"
    static let scPreventClipping = "scPreventClipping"
    static let acoustIDKey = "acoustIDKey"
    static let scChangeFiles = "scChangeFiles"
    static let writeFileTags = "writeFileTags"
    /// Folder on the Mac chosen for caches ("" = the system's cache folder).
    static let cacheFolder = "cacheFolder"
}

/// Files the app keeps on the Mac only to save work. Safe to delete at any time; never written to the iPod.
enum AppCache {
    static let bundleID = "io.github.dmitryzemlyuk.ipodmanager"
    /// The only things the app ever creates (and deletes) inside its cache folder.
    static let searchFolder = "musicbrainz"     // answers of the tag search
    static let webFolder = "web"                // downloaded cover previews and other web answers

    static var customFolder: String { UserDefaults.standard.string(forKey: Prefs.cacheFolder) ?? "" }

    /// The app's own folder inside the chosen (or the system's) cache location.
    static func root(custom: String) -> URL {
        if !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true).appendingPathComponent("iPod Manager Cache", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Caches", isDirectory: true)
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    static var root: URL { root(custom: customFolder) }
    static var search: URL { root.appendingPathComponent(searchFolder, isDirectory: true) }

    /// Points the system's web cache (cover previews) at the cache folder.
    static func installWebCache() {
        let dir = root.appendingPathComponent(webFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20, directory: dir)
    }

    /// Size of what the app cached in a location.
    static func size(custom: String) -> Int64 {
        let r = root(custom: custom)
        return [searchFolder, webFolder].reduce(Int64(0)) { $0 + size(of: r.appendingPathComponent($1, isDirectory: true)) }
    }

    static func size(of folder: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    /// Deletes what the app cached in a location. Only the two folders it created are removed,
    /// and its own folder goes too once nothing else is left in it.
    static func clear(custom: String) {
        let fm = FileManager.default
        let r = root(custom: custom)
        if custom == customFolder { URLCache.shared.removeAllCachedResponses() }
        for name in [searchFolder, webFolder] {
            try? fm.removeItem(at: r.appendingPathComponent(name, isDirectory: true))
        }
        if let rest = try? fm.contentsOfDirectory(atPath: r.path), rest.filter({ $0 != ".DS_Store" }).isEmpty {
            try? fm.removeItem(at: r)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppLanguage.key) private var language = ""
    @AppStorage(Prefs.scTarget) private var target = 89.0
    @AppStorage(Prefs.scAlbumMode) private var albumMode = true
    @AppStorage(Prefs.scPreventClipping) private var preventClipping = true
    @AppStorage(Prefs.acoustIDKey) private var acoustIDKey = ""
    @AppStorage(Prefs.writeFileTags) private var writeFileTags = true
    @AppStorage(Prefs.cacheFolder) private var cacheFolder = ""
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section {
                Picker(L("settings.language"), selection: $language) {
                    Text(L("settings.language.system")).tag("")
                    Text("Українська").tag("uk")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
                .onChange(of: language) { _, newValue in
                    AppLanguage.apply(newValue)
                }
                if language != AppLanguage.atLaunch {
                    HStack {
                        Text(model.hasPending ? L("settings.language.pending") : L("settings.language.restart"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("settings.restart")) { AppLanguage.relaunch() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.hasPending || model.commitState.isRunning)
                    }
                }
            }

            Section {
                Toggle(L("settings.filetags"), isOn: $writeFileTags)
            } footer: {
                Text(L("settings.filetags.text"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(L("settings.cache")) {
                    Text(cacheFolder.isEmpty ? L("settings.cache.default") : (cacheFolder as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(AppCache.root.path)
                }
                HStack {
                    Button(L("settings.cache.choose")) { chooseCacheFolder() }
                    Button(L("mac.reveal")) { revealCache() }
                    if !cacheFolder.isEmpty {
                        Button(L("settings.cache.reset")) { setCacheFolder("") }
                    }
                    Spacer()
                }
                LabeledContent(L("settings.cache.size")) {
                    HStack {
                        Text(formatBytes(cacheSize)).foregroundStyle(.secondary).monospacedDigit()
                        Button(L("settings.cache.clear")) {
                            AppCache.clear(custom: cacheFolder)
                            AppCache.installWebCache()
                            refreshCacheSize()
                        }
                        .disabled(cacheSize == 0)
                    }
                }
            } footer: {
                Text(L("settings.cache.text"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("sc.title")) {
                LabeledContent(L("sc.target")) {
                    Stepper(value: $target, in: 80...100, step: 0.5) {
                        Text(String(format: "%.1f", locale: Locale.current, target) + " " + L("db"))
                            .monospacedDigit()
                    }
                }
                Toggle(L("sc.album"), isOn: $albumMode)
                Toggle(L("sc.noclip"), isOn: $preventClipping)
            }

            Section {
                TextField(L("settings.acoustid"), text: $acoustIDKey, prompt: Text(L("settings.optional")))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text(L("settings.online"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("settings.acoustid.text"))
                    Link(L("settings.acoustid.get"), destination: URL(string: "https://acoustid.org/new-application")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { refreshCacheSize() }
    }

    private func refreshCacheSize() {
        let custom = cacheFolder
        Task {
            let size = await Task.detached(priority: .utility) { AppCache.size(custom: custom) }.value
            if custom == cacheFolder { cacheSize = size }
        }
    }

    private func setCacheFolder(_ new: String) {
        guard new != cacheFolder else { return }
        // It is only a cache: nothing is moved, the old copy is simply removed.
        AppCache.clear(custom: cacheFolder)
        cacheFolder = new
        AppCache.installWebCache()
        refreshCacheSize()
    }

    private func revealCache() {
        let fm = FileManager.default
        var url = AppCache.root
        // Show the nearest folder that exists (the app creates its own on the first search).
        while !fm.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func chooseCacheFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("mac.choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        // Caches belong on the Mac: an iPod is slow, and its space is for music.
        let onIPod = model.devices.contains { d in
            let root = d.mountURL.standardizedFileURL.path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        if onIPod {
            model.notice = L("settings.cache.onipod")
            return
        }
        let probe = url.appendingPathComponent(".ipm-probe-\(UUID().uuidString)")
        guard (try? Data([1]).write(to: probe)) != nil else {
            model.notice = L("settings.cache.readonly")
            return
        }
        try? FileManager.default.removeItem(at: probe)
        setCacheFolder(path)
    }
}
