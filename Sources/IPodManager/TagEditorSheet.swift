import SwiftUI
import AppKit
import UniformTypeIdentifiers
import IPodKit

enum TagField: Hashable, CaseIterable {
    case title, artist, albumArtist, album, genre, composer, year, trackNumber, trackCount, discNumber, discCount, compilation
}

struct TagForm: Equatable {
    var title = ""
    var artist = ""
    var albumArtist = ""
    var album = ""
    var genre = ""
    var composer = ""
    var year = ""
    var trackNumber = ""
    var trackCount = ""
    var discNumber = ""
    var discCount = ""
    var compilation = false

    static func text(_ m: AudioMeta, _ f: TagField) -> String {
        func num(_ v: Int) -> String { v > 0 ? String(v) : "" }
        switch f {
        case .title: return m.title
        case .artist: return m.artist
        case .albumArtist: return m.albumArtist
        case .album: return m.album
        case .genre: return m.genre
        case .composer: return m.composer
        case .year: return num(m.year)
        case .trackNumber: return num(m.trackNumber)
        case .trackCount: return num(m.trackCount)
        case .discNumber: return num(m.discNumber)
        case .discCount: return num(m.discCount)
        case .compilation: return m.compilation ? "1" : "0"
        }
    }

    func value(_ f: TagField) -> String {
        switch f {
        case .title: return title
        case .artist: return artist
        case .albumArtist: return albumArtist
        case .album: return album
        case .genre: return genre
        case .composer: return composer
        case .year: return year
        case .trackNumber: return trackNumber
        case .trackCount: return trackCount
        case .discNumber: return discNumber
        case .discCount: return discCount
        case .compilation: return compilation ? "1" : "0"
        }
    }

    mutating func set(_ f: TagField, _ v: String) {
        switch f {
        case .title: title = v
        case .artist: artist = v
        case .albumArtist: albumArtist = v
        case .album: album = v
        case .genre: genre = v
        case .composer: composer = v
        case .year: year = v
        case .trackNumber: trackNumber = v
        case .trackCount: trackCount = v
        case .discNumber: discNumber = v
        case .discCount: discCount = v
        case .compilation: compilation = v == "1"
        }
    }
}

struct TagEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let rowIDs: Set<String>

    @State private var initial = TagForm()
    @State private var form = TagForm()
    @State private var mixed = Set<TagField>()
    @State private var count = 0
    @State private var artChoice: ArtworkChange?
    @State private var dropTargeted = false

    private var artSource: ArtSource? {
        switch artChoice {
        case .set(let d): return .data(d)
        case .remove: return nil
        case nil:
            guard let row = model.ipodRows.first(where: { rowIDs.contains($0.id) }) else { return nil }
            return model.artSource(for: row)
        }
    }

    private var artworkSupported: Bool { model.artworkSupported }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ArtworkThumb(source: artSource, size: 96)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            .opacity(dropTargeted ? 1 : 0)
                    )
                    .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
                        guard artworkSupported, let p = providers.first else { return false }
                        loadImage(p)
                        return true
                    }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("tags.title")).font(.title3.weight(.semibold))
                    Text(count > 1 ? LF("tags.subtitle.many", count) : L("tags.subtitle.one"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if artworkSupported {
                        HStack(spacing: 8) {
                            Button(L("art.choose")) { chooseImage() }
                            Button(L("art.remove")) { artChoice = .remove }
                            if artChoice != nil {
                                Button(L("art.revert")) { artChoice = nil }
                            }
                        }
                        .controlSize(.small)
                        Text(L("art.hint")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L("art.unsupported")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(20)

            Form {
                Section {
                    field(.title, L("tag.title"))
                        .disabled(count > 1)
                    field(.artist, L("tag.artist"))
                    field(.albumArtist, L("tag.albumArtist"))
                    field(.album, L("tag.album"))
                    field(.genre, L("tag.genre"))
                    field(.composer, L("tag.composer"))
                }
                Section {
                    field(.year, L("tag.year"))
                    HStack {
                        field(.trackNumber, L("tag.track"))
                            .disabled(count > 1)
                        Text(L("tag.of")).foregroundStyle(.secondary)
                        field(.trackCount, "")
                            .frame(maxWidth: 70)
                    }
                    HStack {
                        field(.discNumber, L("tag.disc"))
                        Text(L("tag.of")).foregroundStyle(.secondary)
                        field(.discCount, "")
                            .frame(maxWidth: 70)
                    }
                    Toggle(L("tag.compilation"), isOn: $form.compilation)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Text(L("tags.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(form == initial && artChoice == nil)
            }
            .padding(20)
        }
        .frame(width: 540)
        .onAppear(perform: load)
    }

    private func field(_ f: TagField, _ label: String) -> some View {
        TextField(label, text: Binding(
            get: { form.value(f) },
            set: { form.set(f, $0) }
        ), prompt: Text(mixed.contains(f) ? L("tag.mixed") : ""))
    }

    private func load() {
        let items = model.editableItems(rowIDs)
        count = items.count
        var f = TagForm()
        var m = Set<TagField>()
        if let first = items.first {
            for field in TagField.allCases {
                let v = TagForm.text(first, field)
                if items.allSatisfy({ TagForm.text($0, field) == v }) {
                    f.set(field, v)
                } else if field != .compilation {
                    m.insert(field)
                }
            }
        }
        initial = f
        form = f
        mixed = m
    }

    private func save() {
        var e = TrackEdit()
        for field in TagField.allCases where form.value(field) != initial.value(field) {
            let v = form.value(field).trimmingCharacters(in: .whitespaces)
            switch field {
            case .title: e.title = v
            case .artist: e.artist = v
            case .albumArtist: e.albumArtist = v
            case .album: e.album = v
            case .genre: e.genre = v
            case .composer: e.composer = v
            case .year: e.year = Int(v) ?? 0
            case .trackNumber: e.trackNumber = Int(v) ?? 0
            case .trackCount: e.trackCount = Int(v) ?? 0
            case .discNumber: e.discNumber = Int(v) ?? 0
            case .discCount: e.discCount = Int(v) ?? 0
            case .compilation: e.compilation = form.compilation
            }
        }
        model.applyEdit(e, to: rowIDs)
        if let artChoice { model.setArtwork(artChoice, rowIDs: rowIDs) }
        dismiss()
    }

    private func useImage(_ data: Data?) {
        guard let data, ArtworkCache.thumbnail(data: data, pixels: 32) != nil else {
            model.notice = L("art.badimage")
            return
        }
        artChoice = .set(data)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            useImage(try? Data(contentsOf: url))
        }
    }

    private func loadImage(_ provider: NSItemProvider) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                let data = url.flatMap { try? Data(contentsOf: $0) }
                Task { @MainActor in useImage(data) }
            }
        } else {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                Task { @MainActor in useImage(data) }
            }
        }
    }
}
