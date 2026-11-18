import SwiftUI
import AppKit

@main
struct IPodManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        // Freeze the language the app started with before Settings can change it.
        _ = AppLanguage.atLaunch
        AppCache.installWebCache()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu(L("menu.ipod")) {
                Button(L("write.button")) { model.requestCommit() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(!model.canCommit)
                Button(L("pending.discard")) { model.discardPending() }
                    .disabled(!model.hasPending)
                Divider()
                Button(model.coverScan.map { LF("covers.scanning", $0.done, $0.total) } ?? L("covers.fromfiles")) {
                    model.addCoversFromFiles()
                }
                .disabled(model.session == nil || model.coverScan != nil || model.commitState.isRunning)
                Button(L("sync.all")) { model.queueTagSync(nil) }
                    .disabled(model.session == nil || model.tracks.isEmpty || model.commitState.isRunning)
                Button(model.compacting ? L("compact.running") : L("compact.menu")) { model.compactArtwork() }
                    .disabled(model.session == nil || model.compacting || model.commitState.isRunning || !model.artworkSupported)
                Divider()
                Button(L("tool.eject")) { model.eject() }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(model.device == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

func formatDuration(_ ms: Int) -> String {
    let s = max(ms, 0) / 1000
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

func formatGain(_ g: Double?) -> String {
    guard let g else { return "–" }
    let v = String(format: "%.1f", locale: Locale.current, abs(g))
    if abs(g) < 0.05 { return LF("gain.db", v) }
    return LF("gain.db", (g > 0 ? "+" : "−") + v)
}
