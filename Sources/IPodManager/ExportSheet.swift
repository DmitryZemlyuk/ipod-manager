import SwiftUI
import AppKit
import IPodKit

struct ExportItem: Sendable {
    let source: URL
    let relativePath: String
}

@MainActor
final class ExportJob: ObservableObject {
    @Published var done = 0
    @Published var total = 0
    @Published var copied = 0
    @Published var skipped = 0
    @Published var failed = 0
    @Published var running = false
    @Published var finished = false
    private var task: Task<Void, Never>?

    func start(_ items: [ExportItem], to folder: URL, skipExisting: Bool) {
        cancel()
        done = 0
        copied = 0
        skipped = 0
        failed = 0
        total = items.count
        running = true
        finished = false
        task = Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for item in items {
                if Task.isCancelled { break }
                let dest = folder.appendingPathComponent(item.relativePath)
                var outcome = 0 // 0 copied, 1 skipped, 2 failed
                if fm.fileExists(atPath: dest.path) {
                    if skipExisting {
                        outcome = 1
                    } else {
                        try? fm.removeItem(at: dest)
                    }
                }
                if outcome == 0 {
                    do {
                        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.copyItem(at: item.source, to: dest)
                    } catch {
                        outcome = 2
                    }
                }
                let result = outcome
                await MainActor.run {
                    self.done += 1
                    switch result {
                    case 0: self.copied += 1
                    case 1: self.skipped += 1
                    default: self.failed += 1
                    }
                }
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                self.running = false
                self.finished = !cancelled
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }
}

struct ExportSheet: View {
    enum Scope: Hashable { case all, selected }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let selectedRowIDs: Set<String>

    @StateObject private var job = ExportJob()
    @State private var scope: Scope = .all
    @State private var layout: ExportLayout = .artistAlbumTrack
    @State private var skipExisting = true
    @AppStorage("exportFolder") private var folderPath = ""

    private var folder: URL? {
        folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    private var tracks: [Track] {
        let all = model.tracks.filter { !model.pendingDeletes.contains($0.uniqueID) }
        switch scope {
        case .all:
            return all.map { model.effective($0) }
        case .selected:
            let ids = Set(model.trackIDs(for: selectedRowIDs))
            return all.filter { ids.contains($0.uniqueID) }.map { model.effective($0) }
        }
    }

    private var totalBytes: Int64 { tracks.reduce(0) { $0 + Int64($1.size) } }

    private var example: String {
        let t = tracks.first ?? Track.make(meta: {
            var m = AudioMeta()
            m.title = "One More Time"
            m.artist = "Daft Punk"
            m.album = "Discovery"
            m.trackNumber = 1
            m.kind = .aac
            return m
        }(), uniqueID: 0, relativePath: "iPod_Control/Music/F00/A.m4a", fileSize: 0)
        let ext = (t.relativePath as NSString).pathExtension
        return layout.relativePath(for: t, fileExtension: ext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("export.title")).font(.title3.weight(.semibold))
                    Text(L("export.subtitle")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $scope) {
                    Text(L("export.scope.all")).tag(Scope.all)
                    Text(LF("export.scope.selected", model.trackIDs(for: selectedRowIDs).count)).tag(Scope.selected)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(job.running)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("export.where")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "folder").foregroundStyle(Color.accentColor)
                    Text(folder?.path ?? L("export.nofolder"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(folder == nil ? .secondary : .primary)
                    Spacer()
                    Button(L("export.choose")) { chooseFolder() }
                        .disabled(job.running)
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("export.layout")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: $layout) {
                    Text(L("export.layout.artistAlbumTrack")).tag(ExportLayout.artistAlbumTrack)
                    Text(L("export.layout.artistDashAlbumTrack")).tag(ExportLayout.artistDashAlbumTrack)
                    Text(L("export.layout.flat")).tag(ExportLayout.flat)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .disabled(job.running)
                Text(example)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Toggle(L("export.skip"), isOn: $skipExisting)
                .disabled(job.running)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(L("export.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if job.running || job.finished {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.running ? LF("export.progress", job.done, job.total)
                         : LF("export.finished", job.copied, job.skipped, job.failed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
                }
            }

            HStack {
                Text(LF("export.summary", tracks.count, formatBytes(totalBytes)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if job.finished, let folder {
                    Button(L("export.show")) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
                Button(job.finished ? L("done") : L("cancel"), role: .cancel) {
                    job.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if job.running {
                    Button(L("sc.stop")) { job.cancel() }
                } else {
                    Button(L("export.start")) { start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(folder == nil || tracks.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear {
            if !model.trackIDs(for: selectedRowIDs).isEmpty { scope = .selected }
        }
        .onDisappear { job.cancel() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("export.choose")
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }

    private func start() {
        guard let folder, let device = model.device else { return }
        var used = Set<String>()
        var items: [ExportItem] = []
        for t in tracks {
            let ext = (t.relativePath as NSString).pathExtension
            let original = layout.relativePath(for: t, fileExtension: ext)
            let base = ext.isEmpty ? original : String(original.dropLast(ext.count + 1))
            var rel = original
            var n = 2
            while used.contains(rel.lowercased()) {
                rel = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
                n += 1
                if n > 50 { break }
            }
            used.insert(rel.lowercased())
            items.append(ExportItem(source: device.fileURL(for: t), relativePath: rel))
        }
        job.start(items, to: folder, skipExisting: skipExisting)
    }
}
