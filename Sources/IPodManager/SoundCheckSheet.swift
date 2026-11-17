import SwiftUI
import IPodKit

struct GainItem: Sendable {
    let id: UInt32
    let url: URL
    let title: String
    let artist: String
    let albumKey: String
    let format: String
}

struct GainRow: Identifiable {
    let id: UInt32
    let title: String
    let artist: String
    let format: String
    let albumKey: String
    let lufs: Double
    let peak: Float
}

@MainActor
final class GainJob: ObservableObject {
    @Published var rows: [GainRow] = []
    @Published var done = 0
    @Published var total = 0
    @Published var failed = 0
    @Published var running = false
    @Published var finished = false
    private(set) var albumBlocks: [String: [Float]] = [:]
    private(set) var albumPeak: [String: Float] = [:]
    private var task: Task<Void, Never>?

    func start(_ items: [GainItem]) {
        cancel()
        rows = []
        albumBlocks = [:]
        albumPeak = [:]
        done = 0
        failed = 0
        total = items.count
        running = true
        finished = false
        task = Task {
            await withTaskGroup(of: (GainItem, LoudnessResult?).self) { group in
                var it = items.makeIterator()
                for _ in 0..<2 {
                    guard let item = it.next() else { break }
                    group.addTask { (item, GainJob.analyze(item)) }
                }
                while let pair = await group.next() {
                    let (item, result) = pair
                    if Task.isCancelled { group.cancelAll(); break }
                    self.done += 1
                    if let r = result {
                        self.rows.append(GainRow(id: item.id, title: item.title, artist: item.artist,
                                                 format: item.format, albumKey: item.albumKey,
                                                 lufs: r.integrated, peak: r.peak))
                        if !item.albumKey.isEmpty {
                            self.albumBlocks[item.albumKey, default: []].append(contentsOf: r.blocks)
                            self.albumPeak[item.albumKey] = max(self.albumPeak[item.albumKey] ?? 0, r.peak)
                        }
                    } else {
                        self.failed += 1
                    }
                    if let next = it.next() {
                        group.addTask { (next, GainJob.analyze(next)) }
                    }
                }
            }
            self.running = false
            self.finished = !Task.isCancelled
        }
    }

    nonisolated static func analyze(_ item: GainItem) -> LoudnessResult? {
        try? Loudness.analyze(url: item.url, isCancelled: { Task.isCancelled })
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }

    private var albumLoudnessCache: [String: Double] = [:]

    func albumLoudness(_ key: String) -> Double? {
        guard !key.isEmpty, !running, let blocks = albumBlocks[key] else { return nil }
        if let c = albumLoudnessCache[key] { return c }
        let v = Loudness.gated(blocks)
        albumLoudnessCache[key] = v
        return v
    }

    func resetCache() { albumLoudnessCache = [:] }

    func gain(for row: GainRow, target: Double, albumMode: Bool, preventClipping: Bool) -> Double {
        if albumMode, let album = albumLoudness(row.albumKey) {
            return SoundCheck.gain(lufs: album, targetDB: target, peak: albumPeak[row.albumKey],
                                   preventClipping: preventClipping)
        }
        return SoundCheck.gain(lufs: row.lufs, targetDB: target, peak: row.peak, preventClipping: preventClipping)
    }
}

struct SoundCheckSheet: View {
    enum Scope: Hashable { case all, selected, missing }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let selectedRowIDs: Set<String>

    @StateObject private var job = GainJob()
    @State private var scope: Scope = .all
    @AppStorage(Prefs.scTarget) private var target = 89.0
    @AppStorage(Prefs.scAlbumMode) private var albumMode = true
    @AppStorage(Prefs.scPreventClipping) private var preventClipping = true

    private var liveTracks: [Track] {
        model.tracks.filter { !model.pendingDeletes.contains($0.uniqueID) }.map { model.effective($0) }
    }

    private func items(for scope: Scope) -> [GainItem] {
        guard let device = model.device else { return [] }
        let selected = Set(model.trackIDs(for: selectedRowIDs))
        return liveTracks.compactMap { t in
            switch scope {
            case .all: break
            case .selected: if !selected.contains(t.uniqueID) { return nil }
            case .missing: if t.soundCheck != 0 { return nil }
            }
            let artist = t.albumArtist.isEmpty ? t.artist : t.albumArtist
            let key = t.album.isEmpty ? "" : artist.lowercased() + "\u{1F}" + t.album.lowercased()
            let label = t.fileTypeDescription.contains("Lossless") ? "ALAC"
                : (t.relativePath as NSString).pathExtension.uppercased()
            return GainItem(id: t.uniqueID, url: device.fileURL(for: t), title: t.title,
                            artist: t.artist, albumKey: key, format: label)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("sc.title")).font(.title3.weight(.semibold))
                    Text(L("sc.subtitle")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $scope) {
                    Text(LF("sc.scope.all", items(for: .all).count)).tag(Scope.all)
                    Text(LF("sc.scope.selected", items(for: .selected).count)).tag(Scope.selected)
                    Text(LF("sc.scope.missing", items(for: .missing).count)).tag(Scope.missing)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(job.running)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("sc.mode.soundcheck")).fontWeight(.semibold)
                            Text(L("sc.mode.soundcheck.text")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "circle").foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("sc.mode.files")).fontWeight(.semibold).foregroundStyle(.secondary)
                            Text(L("sc.mode.files.text")).font(.callout).foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    Text(L("sc.target"))
                    Stepper(value: $target, in: 80...100, step: 0.5) {
                        Text(String(format: "%.1f", locale: Locale.current, target) + " " + L("db"))
                            .monospacedDigit()
                            .frame(minWidth: 64)
                    }
                }
                Toggle(L("sc.album"), isOn: $albumMode)
                Toggle(L("sc.noclip"), isOn: $preventClipping)
            }
            .onChange(of: albumMode) { _, _ in job.resetCache() }

            resultsTable
                .frame(minHeight: 260)

            if job.running || job.finished {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(job.running ? LF("sc.progress", job.done, job.total) : LF("sc.finished", job.rows.count))
                        Spacer()
                        if job.failed > 0 {
                            Text(LF("sc.failed", job.failed)).foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
                }
            }

            HStack {
                if job.running {
                    Button(L("sc.stop")) { job.cancel() }
                } else {
                    Button(L("sc.analyze")) { job.start(items(for: scope)) }
                        .disabled(items(for: scope).isEmpty)
                }
                Spacer()
                Button(L("cancel"), role: .cancel) {
                    job.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(job.rows.isEmpty ? L("sc.apply") : LF("sc.apply.count", job.rows.count)) { apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.running || job.rows.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 820, height: 640)
        .onAppear {
            if !selectedRowIDs.isEmpty, !items(for: .selected).isEmpty { scope = .selected }
        }
        .onDisappear { job.cancel() }
    }

    private var resultsTable: some View {
        Table(job.rows) {
            TableColumn(L("col.title")) { (r: GainRow) in Text(r.title) }
            TableColumn(L("col.artist")) { (r: GainRow) in Text(r.artist).foregroundStyle(.secondary) }
            TableColumn(L("col.format")) { (r: GainRow) in Text(r.format).font(.caption).foregroundStyle(.secondary) }
                .width(56)
            TableColumn(L("sc.col.loudness")) { (r: GainRow) in
                Text(r.lufs <= -69.9 ? "–" : String(format: "%.1f", locale: Locale.current, SoundCheck.displayDB(lufs: r.lufs)) + " " + L("db"))
                    .monospacedDigit()
            }
            .width(80)
            TableColumn(L("sc.col.clip")) { (r: GainRow) in
                let g = job.gain(for: r, target: target, albumMode: albumMode, preventClipping: preventClipping)
                let clips = Double(r.peak) * pow(10, g / 20) > 1.0001
                Text(clips ? L("yes") : "–")
                    .foregroundStyle(clips ? Color.red : Color.secondary)
                    .fontWeight(clips ? .semibold : .regular)
            }
            .width(70)
            TableColumn(L("sc.col.gain")) { (r: GainRow) in
                let g = job.gain(for: r, target: target, albumMode: albumMode, preventClipping: preventClipping)
                Text(formatGain(g))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(g > 0.05 ? Color.green : Color.accentColor)
            }
            .width(80)
        }
        .overlay {
            if job.rows.isEmpty && !job.running {
                Text(L("sc.empty"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }

    private func apply() {
        var values: [UInt32: UInt32] = [:]
        for r in job.rows {
            let g = job.gain(for: r, target: target, albumMode: albumMode, preventClipping: preventClipping)
            values[r.id] = SoundCheck.value(forGain: g)
        }
        model.applySoundCheck(values)
        dismiss()
    }
}
