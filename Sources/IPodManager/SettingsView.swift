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
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppLanguage.key) private var language = ""
    @AppStorage(Prefs.scTarget) private var target = 89.0
    @AppStorage(Prefs.scAlbumMode) private var albumMode = true
    @AppStorage(Prefs.scPreventClipping) private var preventClipping = true
    @AppStorage(Prefs.acoustIDKey) private var acoustIDKey = ""

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
    }
}
