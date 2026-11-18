import SwiftUI
import IPodKit

@MainActor
final class AutoTagJob: ObservableObject {
    @Published var groups: [TagGroup] = []
    @Published var done = 0
    @Published var total = 0
    @Published var running = false
    @Published var finished = false
    @Published var checked = Set<String>()
    @Published var choice: [String: String] = [:]   // group id → release id
    @Published var errorCount = 0
    @Published var lastError = ""
    private var task: Task<Void, Never>?
    private var generation = 0

    func start(_ items: [TagItem], acoustIDKey: String, fpcalc: URL?) {
        cancel()
        groups = []
        checked = []
        choice = [:]
        done = 0
        total = 0
        errorCount = 0
        lastError = ""
        running = true
        finished = false
        generation += 1
        let gen = generation
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let cache = AppCache.search
        let tagger = AutoTagger(client: MusicBrainzClient(appVersion: version, cacheDirectory: cache),
                                acoustIDKey: acoustIDKey, fpcalc: fpcalc)
        task = Task {
            let result = await tagger.run(items: items, progress: { d, t in
                Task { @MainActor in
                    guard self.generation == gen else { return }
                    self.done = d
                    self.total = t
                    let errs = tagger.errors
                    self.errorCount = errs.count
                    self.lastError = errs.last ?? ""
                }
            }, onGroup: { g in
                Task { @MainActor in self.add(g, gen) }
            })
            guard self.generation == gen else { return }
            for g in result { self.add(g, gen) }
            let errs = tagger.errors
            self.errorCount = errs.count
            self.lastError = errs.last ?? ""
            self.running = false
            self.finished = !Task.isCancelled
        }
    }

    private func add(_ g: TagGroup, _ gen: Int) {
        guard gen == generation, !groups.contains(where: { $0.id == g.id }) else { return }
        groups.append(g)
        if let first = g.options.first {
            choice[g.id] = first.id
            if g.status == .found { checked.insert(g.id) }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        running = false
    }

    func option(for g: TagGroup) -> ReleaseOption? {
        let id = choice[g.id]
        return g.options.first { $0.id == id } ?? g.options.first
    }
}

struct AutoTagSheet: View {
    enum Scope: Hashable { case all, selected, incomplete }
    enum Filter: Hashable { case all, found, choose, notFound }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let selectedRowIDs: Set<String>

    @StateObject private var job = AutoTagJob()
    @AppStorage(Prefs.acoustIDKey) private var acoustIDKey = ""
    @AppStorage("autoTagKeepFilled") private var keepFilled = true
    @AppStorage("autoTagReplaceGenre") private var replaceGenre = false
    @AppStorage("autoTagAddCovers") private var addCovers = true
    @AppStorage("autoTagReplaceCovers") private var replaceCovers = false
    @State private var scope: Scope = .all
    @State private var filter: Filter = .all
    @State private var coverProgress: (done: Int, total: Int)?

    private var coversPossible: Bool { addCovers && (model.artworkSupported) }

    /// Whether a cover should be fetched for this song (given the found tags).
    private func wantsCover(_ t: Track, _ p: TagProposal) -> Bool {
        guard coversPossible else { return false }
        if AutoTagSheet.albumMismatch(t, p, keepFilled: keepFilled) { return false }
        return replaceCovers || !model.hasArtwork(t)
    }

    private var fpcalc: URL? { Bundle.main.url(forAuxiliaryExecutable: "fpcalc") }

    private var tracksByID: [UInt32: Track] {
        var d: [UInt32: Track] = [:]
        for t in model.tracks where !model.pendingDeletes.contains(t.uniqueID) { d[t.uniqueID] = model.effective(t) }
        return d
    }

    private func items(_ scope: Scope) -> [TagItem] {
        guard let device = model.device else { return [] }
        let selected = Set(model.trackIDs(for: selectedRowIDs))
        return model.tracks.compactMap { raw -> TagItem? in
            guard !model.pendingDeletes.contains(raw.uniqueID) else { return nil }
            let t = model.effective(raw)
            switch scope {
            case .all: break
            case .selected: if !selected.contains(t.uniqueID) { return nil }
            case .incomplete:
                let complete = !t.album.isEmpty && !AutoTagger.isPlaceholderArtist(t.artist)
                    && !AutoTagger.isJunkTitle(t.title) && t.year > 0 && !t.genre.isEmpty && t.trackNumber > 0
                if complete { return nil }
            }
            return TagItem(id: t.uniqueID, title: t.title, artist: t.artist, album: t.album,
                           albumArtist: t.albumArtist, genre: t.genre, trackNumber: Int(t.trackNumber),
                           discNumber: Int(t.discNumber), durationMs: Int(t.durationMs),
                           fileURL: device.fileURL(for: t))
        }
    }

    private var visibleGroups: [TagGroup] {
        job.groups.filter { g in
            switch filter {
            case .all: return true
            case .found: return g.status == .found
            case .choose: return g.status == .choose
            case .notFound: return g.status == .notFound
            }
        }
    }

    private func count(_ s: TagGroup.Status) -> Int {
        job.groups.filter { $0.status == s }.reduce(0) { $0 + $1.itemIDs.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if job.running || !job.groups.isEmpty { filterChips }
            results
            progress
            optionsRow
            footer
        }
        .padding(22)
        .frame(width: 900, height: 700)
        .onAppear {
            if !items(.selected).isEmpty { scope = .selected }
        }
        .onDisappear { job.cancel() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("at.title")).font(.title3.weight(.semibold))
                Text(L("at.subtitle")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $scope) {
                Text(LF("sc.scope.all", items(.all).count)).tag(Scope.all)
                Text(LF("sc.scope.selected", items(.selected).count)).tag(Scope.selected)
                Text(LF("at.scope.incomplete", items(.incomplete).count)).tag(Scope.incomplete)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(job.running)
        }
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            chip(.all, LF("at.filter.all", job.groups.reduce(0) { $0 + $1.itemIDs.count }), nil)
            chip(.found, LF("at.filter.found", count(.found)), .green)
            chip(.choose, LF("at.filter.choose", count(.choose)), .orange)
            chip(.notFound, LF("at.filter.notfound", count(.notFound)), .gray)
            Spacer()
        }
    }

    private func chip(_ f: Filter, _ text: String, _ dot: Color?) -> some View {
        Button {
            filter = f
        } label: {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                Text(text)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(filter == f ? Color.primary.opacity(0.85) : Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(filter == f ? Color(nsColor: .windowBackgroundColor) : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var results: some View {
        if job.groups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text(job.running ? L("at.searching") : L("at.empty"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !job.running && (acoustIDKey.isEmpty || fpcalc == nil) {
                    Text(L("at.nofingerprint"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            let tracks = tracksByID
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(visibleGroups) { g in
                        GroupCard(group: g, job: job, tracks: tracks, keepFilled: keepFilled, replaceGenre: replaceGenre,
                                  wantsCover: wantsCover)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        if job.errorCount > 0 {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(LF("at.errors", job.errorCount) + " " + job.lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        if job.running {
            VStack(alignment: .leading, spacing: 6) {
                Text(LF("at.progress", job.done, max(job.total, job.done)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
            }
        }
    }

    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 22) {
                Toggle(L("at.keepfilled"), isOn: $keepFilled)
                Toggle(L("at.replacegenre"), isOn: $replaceGenre)
                    .disabled(!keepFilled)
            }
            HStack(spacing: 22) {
                Toggle(L("at.addcovers"), isOn: $addCovers)
                Toggle(L("at.replacecovers"), isOn: $replaceCovers)
                    .disabled(!addCovers)
            }
            .disabled(!(model.artworkSupported))
        }
        .disabled(coverProgress != nil)
    }

    private var footer: some View {
        HStack {
            if job.running {
                Button(L("sc.stop")) { job.cancel() }
            } else {
                Button(job.groups.isEmpty ? L("at.start") : L("at.restart")) {
                    job.start(items(scope), acoustIDKey: acoustIDKey, fpcalc: fpcalc)
                }
                .disabled(items(scope).isEmpty)
            }
            Spacer()
            if let cp = coverProgress {
                ProgressView().controlSize(.small)
                Text(LF("at.covers.progress", cp.done, cp.total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("at.nowrite"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(L("cancel"), role: .cancel) {
                job.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            let edits = computeEdits()
            let covers = coverTargets()
            let songs = Set(edits.keys).union(covers.flatMap { $0.trackIDs }).count
            Button(songs == 0 ? L("sc.apply") : LF("sc.apply.count", songs)) {
                apply(edits: edits, covers: covers)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(songs == 0 || coverProgress != nil)
        }
    }

    struct CoverTarget: Sendable {
        let releaseID: String
        let releaseGroupID: String?
        let trackIDs: [UInt32]
    }

    private func coverTargets() -> [CoverTarget] {
        guard coversPossible else { return [] }
        let tracks = tracksByID
        var out: [CoverTarget] = []
        for g in job.groups where job.checked.contains(g.id) {
            guard let opt = job.option(for: g) else { continue }
            let ids = opt.proposals.compactMap { id, p -> UInt32? in
                guard let t = tracks[id], wantsCover(t, p) else { return nil }
                return id
            }
            if !ids.isEmpty { out.append(CoverTarget(releaseID: opt.id, releaseGroupID: opt.releaseGroupID, trackIDs: ids)) }
        }
        return out
    }

    private func apply(edits: [UInt32: TrackEdit], covers: [CoverTarget]) {
        guard !covers.isEmpty else {
            model.applyEdits(edits)
            dismiss()
            return
        }
        job.cancel()
        coverProgress = (0, covers.count)
        Task {
            var found: [UInt32: Data] = [:]
            var albums = 0
            var done = 0
            await withTaskGroup(of: (CoverTarget, Data?).self) { group in
                var it = covers.makeIterator()
                for _ in 0..<4 {
                    guard let c = it.next() else { break }
                    group.addTask { (c, await AutoTagSheet.fetchCover(c)) }
                }
                while let pair = await group.next() {
                    done += 1
                    coverProgress = (done, covers.count)
                    if let raw = pair.1, let data = ArtworkPixels.normalized(raw) {
                        albums += 1
                        for id in pair.0.trackIDs { found[id] = data }
                    }
                    if let c = it.next() {
                        group.addTask { (c, await AutoTagSheet.fetchCover(c)) }
                    }
                }
            }
            model.applyEdits(edits)
            model.applyArtwork(found)
            if albums < covers.count {
                model.notice = LF("at.covers.result", albums, covers.count)
            }
            coverProgress = nil
            dismiss()
        }
    }

    /// Front cover from the Cover Art Archive: this release first, then any release of the album.
    nonisolated static func fetchCover(_ c: CoverTarget) async -> Data? {
        var urls = ["https://coverartarchive.org/release/\(c.releaseID)/front-500"]
        if let rg = c.releaseGroupID { urls.append("https://coverartarchive.org/release-group/\(rg)/front-500") }
        for u in urls {
            guard let url = URL(string: u) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  ArtworkCache.thumbnail(data: data, pixels: 32) != nil else { continue }
            return data
        }
        return nil
    }

    private func computeEdits() -> [UInt32: TrackEdit] {
        var out: [UInt32: TrackEdit] = [:]
        let tracks = tracksByID
        for g in job.groups where job.checked.contains(g.id) {
            guard let opt = job.option(for: g) else { continue }
            for (id, p) in opt.proposals {
                guard let t = tracks[id] else { continue }
                let e = AutoTagSheet.edit(for: t, proposal: p, keepFilled: keepFilled, replaceGenre: replaceGenre)
                if !e.isEmpty { out[id] = e }
            }
        }
        return out
    }

    static func edit(for t: Track, proposal p: TagProposal, keepFilled: Bool, replaceGenre: Bool) -> TrackEdit {
        var e = TrackEdit()
        func str(_ cur: String, _ new: String, placeholder: Bool = false, force: Bool = false) -> String? {
            guard !new.isEmpty, new != cur else { return nil }
            if keepFilled && !force && !cur.isEmpty && !placeholder { return nil }
            return new
        }
        func num(_ cur: UInt32, _ new: Int) -> Int? {
            guard new > 0, Int(cur) != new else { return nil }
            if keepFilled && cur > 0 { return nil }
            return new
        }
        e.title = str(t.title, p.title, placeholder: AutoTagger.isJunkTitle(t.title))
        e.artist = str(t.artist, p.artist, placeholder: AutoTagger.isPlaceholderArtist(t.artist))
        e.album = str(t.album, p.album)
        e.genre = str(t.genre, p.genre, force: replaceGenre)
        // Year, numbers and album artist describe the found album. If the song keeps
        // a different album name, writing them would mix two albums together.
        if !albumMismatch(t, p, keepFilled: keepFilled) {
            e.albumArtist = str(t.albumArtist, p.albumArtist)
            e.year = num(t.year, p.year)
            e.trackNumber = num(t.trackNumber, p.trackNumber)
            e.trackCount = num(t.trackCount, p.trackCount)
            e.discNumber = num(t.discNumber, p.discNumber)
            e.discCount = num(t.discCount, p.discCount)
            if p.compilation && !t.compilation { e.compilation = true }
        }
        return e
    }

    /// The song stays in its current album, and the match belongs to another one.
    static func albumMismatch(_ t: Track, _ p: TagProposal, keepFilled: Bool) -> Bool {
        keepFilled && !t.album.isEmpty && !p.album.isEmpty && !AutoTagger.sameAlbum(t.album, p.album)
    }
}

private struct GroupCard: View {
    let group: TagGroup
    @ObservedObject var job: AutoTagJob
    let tracks: [UInt32: Track]
    let keepFilled: Bool
    let replaceGenre: Bool
    let wantsCover: (Track, TagProposal) -> Bool

    @State private var expanded = false

    private var option: ReleaseOption? { job.option(for: group) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Toggle("", isOn: Binding(
                get: { job.checked.contains(group.id) },
                set: { if $0 { job.checked.insert(group.id) } else { job.checked.remove(group.id) } }
            ))
            .labelsHidden()
            .disabled(group.options.isEmpty)
            .padding(.top, 2)

            cover
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(group.title).font(.headline).lineLimit(1)
                    Text(group.artist.isEmpty ? LF("at.songs", group.itemIDs.count)
                         : group.artist + " · " + LF("at.songs", group.itemIDs.count))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    badge
                }
                if group.options.count > 1 {
                    editions
                }
                if let option {
                    changes(option)
                    Button {
                        expanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            Text(expanded ? L("at.details.hide") : L("at.details.show"))
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    if expanded {
                        details(option)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(group.status == .choose ? Color.orange.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(group.status == .choose ? Color.orange.opacity(0.6) : Color.primary.opacity(0.1),
                              lineWidth: group.status == .choose ? 1.5 : 0.5)
        )
    }

    @ViewBuilder
    private var cover: some View {
        if let option {
            AsyncImage(url: URL(string: "https://coverartarchive.org/release/\(option.id)/front-250")) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            placeholder
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "music.note").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch group.status {
        case .found:
            Badge(text: group.source == .fingerprint
                  ? LF("at.badge.sound", Int(group.confidence * 100))
                  : LF("at.badge.tags", Int(group.confidence * 100)),
                  color: .green)
        case .choose:
            Badge(text: L("at.badge.choose"), color: .orange)
        case .notFound:
            Badge(text: L("at.badge.notfound"), color: .gray)
        }
    }

    private func changes(_ option: ReleaseOption) -> some View {
        let lines = summary(option)
        return VStack(alignment: .leading, spacing: 3) {
            if lines.isEmpty {
                Text(L("at.nochanges")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("at.willchange")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Text(line.label + ":").foregroundStyle(.secondary)
                    if !line.old.isEmpty {
                        Text(line.old).strikethrough().foregroundStyle(.tertiary)
                        Text("→").foregroundStyle(.secondary)
                    }
                    Text(line.new).fontWeight(.semibold).foregroundStyle(.green)
                }
                .font(.caption)
                .lineLimit(1)
            }
        }
    }

    private struct Line { let label: String; let old: String; let new: String }

    private struct FieldRow: Identifiable {
        let id: Int
        let label: String
        let now: String
        let found: String
        /// 0 same, 1 will be written, 2 kept as is, 3 nothing found, 4 skipped (other album)
        let state: Int
    }

    private func fieldRows(_ t: Track, _ p: TagProposal) -> [FieldRow] {
        let e = AutoTagSheet.edit(for: t, proposal: p, keepFilled: keepFilled, replaceGenre: replaceGenre)
        func n(_ v: UInt32) -> String { v > 0 ? String(v) : "" }
        func ni(_ v: Int) -> String { v > 0 ? String(v) : "" }
        func pair(_ a: String, _ b: String) -> String { b.isEmpty ? a : (a.isEmpty ? "" : a + " / " + b) }
        let specs: [(String, String, String, Bool)] = [
            (L("tag.title"), t.title, p.title, e.title != nil),
            (L("tag.artist"), t.artist, p.artist, e.artist != nil),
            (L("tag.album"), t.album, p.album, e.album != nil),
            (L("tag.albumArtist"), t.albumArtist, p.albumArtist, e.albumArtist != nil),
            (L("tag.genre"), t.genre, p.genre, e.genre != nil),
            (L("tag.year"), n(t.year), ni(p.year), e.year != nil),
            (L("tag.track"), pair(n(t.trackNumber), n(t.trackCount)), pair(ni(p.trackNumber), ni(p.trackCount)),
             e.trackNumber != nil || e.trackCount != nil),
            (L("tag.disc"), pair(n(t.discNumber), n(t.discCount)), pair(ni(p.discNumber), ni(p.discCount)),
             e.discNumber != nil || e.discCount != nil)
        ]
        let mismatch = AutoTagSheet.albumMismatch(t, p, keepFilled: keepFilled)
        return specs.enumerated().map { i, s in
            var state = s.3 ? 1 : (s.2.isEmpty ? 3 : (s.1 == s.2 ? 0 : 2))
            // rows 3 (album artist), 5 (year), 6 (track), 7 (disc) depend on the album
            if mismatch, state == 2, [3, 5, 6, 7].contains(i) { state = 4 }
            return FieldRow(id: i, label: s.0, now: s.1, found: s.2, state: state)
        }
    }

    private func stateView(_ state: Int, wasEmpty: Bool) -> some View {
        let text: String
        let color: Color
        switch state {
        case 1: text = wasEmpty ? L("at.state.fill") : L("at.state.replace"); color = .green
        case 2: text = L("at.state.keep"); color = .orange
        case 3: text = L("at.state.none"); color = .secondary
        case 4: text = L("at.state.otheralbum"); color = .orange
        default: text = L("at.state.same"); color = .secondary
        }
        return Text(text).foregroundStyle(color).fontWeight(state == 1 ? .semibold : .regular)
    }

    /// Full comparison: every field of every song, what is there now, what was found and what happens.
    private func details(_ option: ReleaseOption) -> some View {
        let songs: [(Track, TagProposal)] = group.itemIDs.compactMap { id in
            guard let t = tracks[id], let p = option.proposals[id] else { return nil }
            return (t, p)
        }
        .sorted { ($0.1.discNumber, $0.1.trackNumber) < ($1.1.discNumber, $1.1.trackNumber) }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(songs.prefix(40).enumerated()), id: \.offset) { _, song in
                VStack(alignment: .leading, spacing: 4) {
                    if songs.count > 1 {
                        Text(song.0.title).font(.caption.weight(.semibold))
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                        GridRow {
                            Text(L("at.col.field"))
                            Text(L("at.col.now"))
                            Text(L("at.col.found"))
                            Text(L("at.col.result"))
                        }
                        .foregroundStyle(.tertiary)
                        ForEach(fieldRows(song.0, song.1)) { r in
                            GridRow {
                                Text(r.label).foregroundStyle(.secondary)
                                Text(r.now.isEmpty ? "–" : r.now).lineLimit(1)
                                Text(r.found.isEmpty ? "–" : r.found).lineLimit(1)
                                stateView(r.state, wasEmpty: r.now.isEmpty)
                            }
                        }
                    }
                    .font(.caption)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if songs.count > 40 {
                Text(LF("at.more", songs.count - 40)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Album-level changes from the first song, plus a count of per-song changes.
    private func summary(_ option: ReleaseOption) -> [Line] {
        var lines: [Line] = []
        var titleChanges = 0
        var numberChanges = 0
        var first: (Track, TrackEdit)?
        var coverCount = 0
        for id in group.itemIDs {
            guard let t = tracks[id], let p = option.proposals[id] else { continue }
            if wantsCover(t, p) { coverCount += 1 }
            let e = AutoTagSheet.edit(for: t, proposal: p, keepFilled: keepFilled, replaceGenre: replaceGenre)
            if e.title != nil { titleChanges += 1 }
            if e.trackNumber != nil || e.trackCount != nil { numberChanges += 1 }
            if first == nil { first = (t, e) }
        }
        guard let f = first else { return [] }
        let (t, e) = f
        let single = group.itemIDs.count == 1
        if single, let v = e.title { lines.append(Line(label: L("tag.title"), old: t.title, new: v)) }
        if let v = e.artist { lines.append(Line(label: L("tag.artist"), old: t.artist, new: v)) }
        if let v = e.album { lines.append(Line(label: L("tag.album"), old: t.album, new: v)) }
        if let v = e.albumArtist, v != e.artist ?? t.artist { lines.append(Line(label: L("tag.albumArtist"), old: t.albumArtist, new: v)) }
        if let v = e.year { lines.append(Line(label: L("tag.year"), old: t.year > 0 ? String(t.year) : "", new: String(v))) }
        if let v = e.genre { lines.append(Line(label: L("tag.genre"), old: t.genre, new: v)) }
        if !single, titleChanges > 0 { lines.append(Line(label: L("at.titles"), old: "", new: LF("at.count", titleChanges))) }
        if numberChanges > 0 {
            if single {
                let n = e.trackNumber ?? Int(t.trackNumber)
                let total = e.trackCount ?? Int(t.trackCount)
                lines.append(Line(label: L("tag.track"), old: "", new: total > 0 ? "\(n) / \(total)" : "\(n)"))
            } else {
                lines.append(Line(label: L("at.numbers"), old: "", new: LF("at.count", numberChanges)))
            }
        }
        if coverCount > 0 {
            lines.append(Line(label: L("at.cover"), old: "", new: single ? L("at.cover.add") : LF("at.count", coverCount)))
        }
        return lines
    }

    private var editions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(group.options) { o in
                Button {
                    job.choice[group.id] = o.id
                    job.checked.insert(group.id)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: job.option(for: group)?.id == o.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text([o.year.map(String.init), o.format.isEmpty ? nil : o.format, o.country.isEmpty ? nil : o.country]
                                .compactMap { $0 }.joined(separator: " · "))
                                .fontWeight(.semibold)
                            Text(LF("at.tracks", o.trackCount)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(job.option(for: group)?.id == o.id ? Color.accentColor : Color.primary.opacity(0.12),
                                          lineWidth: job.option(for: group)?.id == o.id ? 1.5 : 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
