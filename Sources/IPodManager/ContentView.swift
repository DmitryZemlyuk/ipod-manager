import SwiftUI
import AppKit
import ImageIO
import IPodKit

enum SheetKind: String, Identifiable {
    case tags, soundCheck, export, autoTag
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var macSelection = Set<String>()
    @State private var ipodSelection = Set<String>()
    @State private var sheet: SheetKind?
    @State private var tagTargets = Set<String>()

    var body: some View {
        VStack(spacing: 10) {
            HSplitView {
                MacPane(selection: $macSelection, search: search)
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, 5)
                IPodPane(selection: $ipodSelection, search: search, onShowInfo: { ids in
                    tagTargets = ids
                    sheet = .tags
                }, onAutoTag: { ids in
                    ipodSelection = ids
                    sheet = .autoTag
                })
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 5)
            }
            CapacityBar()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar { toolbarContent }
        .searchable(text: $search, placement: .toolbar, prompt: Text(L("search.prompt")))
        .sheet(item: $sheet) { kind in
            switch kind {
            case .tags:
                TagEditorSheet(rowIDs: tagTargets)
            case .soundCheck:
                SoundCheckSheet(selectedRowIDs: ipodSelection)
            case .export:
                ExportSheet(selectedRowIDs: ipodSelection)
            case .autoTag:
                AutoTagSheet(selectedRowIDs: ipodSelection)
            }
        }
        .sheet(isPresented: $model.showCommitSheet) {
            CommitSheet()
        }
        .alert(L("notice.title"), isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button(L("ok"), role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .navigationTitle(L("app.title"))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            DeviceChip()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                sheet = .soundCheck
            } label: {
                Label(L("tool.soundcheck"), systemImage: "waveform")
            }
            .help(L("tool.soundcheck"))
            .disabled(model.session == nil)

            Button {
                sheet = .autoTag
            } label: {
                Label(L("tool.autotag"), systemImage: "globe")
            }
            .help(L("tool.autotag"))
            .disabled(model.session == nil || model.tracks.isEmpty)

            Button {
                tagTargets = ipodSelection
                sheet = .tags
            } label: {
                Label(L("tool.info"), systemImage: "info.circle")
            }
            .help(L("tool.info"))
            .disabled(model.session == nil || ipodSelection.isEmpty)

            Button {
                sheet = .export
            } label: {
                Label(L("tool.export"), systemImage: "square.and.arrow.down")
            }
            .help(L("tool.export"))
            .disabled(model.session == nil || model.tracks.isEmpty)

            Button {
                model.eject()
            } label: {
                Label(L("tool.eject"), systemImage: "eject")
            }
            .help(L("tool.eject"))
            .disabled(model.device == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.requestCommit()
            } label: {
                Text(L("write.button"))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canCommit)
            .help(L("write.help"))
        }
    }
}

struct DeviceChip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            if model.devices.isEmpty {
                Text(L("ipod.none.title"))
            }
            ForEach(model.devices) { d in
                Button {
                    model.select(d)
                } label: {
                    if d == model.device {
                        Label(d.volumeName, systemImage: "checkmark")
                    } else {
                        Text(d.volumeName)
                    }
                }
            }
            Divider()
            Button(L("ipod.refresh")) { model.refreshDevices() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ipod")
                if let d = model.device {
                    Text(d.volumeName).fontWeight(.semibold)
                    if let cap = model.capacity {
                        Text(formatBytes(cap.total)).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L("ipod.none.short")).foregroundStyle(.secondary)
                }
            }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("ipod.choose"))
    }
}

/// Header strip shown on top of each pane.
struct PaneHeader<Trailing: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

extension View {
    func paneBackground() -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}

/// Where a thumbnail comes from. `key` identifies the picture for caching.
struct ArtSource: Sendable {
    let key: String
    let load: @Sendable () async -> CGImage?

    static func file(_ url: URL?) -> ArtSource? {
        guard let url else { return nil }
        return ArtSource(key: "file:" + url.path) { await ArtworkCache.thumbnail(url: url, pixels: 112) }
    }

    static func data(_ data: Data) -> ArtSource {
        ArtSource(key: "data:\(data.count):\(data.hashValue)") { ArtworkCache.thumbnail(data: data, pixels: 112) }
    }
}

/// Small cover art thumbnail, loaded lazily.
struct ArtworkThumb: View {
    let source: ArtSource?
    var size: CGFloat = 26
    @State private var image: NSImage?

    init(url: URL?, size: CGFloat = 26) {
        self.source = ArtSource.file(url)
        self.size = size
    }

    init(source: ArtSource?, size: CGFloat = 26) {
        self.source = source
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 8 : 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size > 40 ? 8 : 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .task(id: source?.key) {
            image = nil
            guard let source else { return }
            image = await ArtworkCache.shared.image(for: source)
        }
    }
}

@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, NSImage>()
    private var missing = Set<String>()

    init() {
        cache.countLimit = 3000
    }

    func image(for source: ArtSource) async -> NSImage? {
        let key = source.key as NSString
        if let img = cache.object(forKey: key) { return img }
        if missing.contains(source.key) { return nil }
        let load = source.load
        let cg = await Task.detached(priority: .utility) { await load() }.value
        guard let cg else {
            if missing.count > 20000 { missing.removeAll() }
            missing.insert(source.key)
            return nil
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
        return img
    }

    nonisolated static func thumbnail(data: Data, pixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixels, 16)
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    nonisolated static func thumbnail(url: URL, pixels: Int) async -> CGImage? {
        guard let data = await AudioMetaReader.artworkData(url: url) else { return nil }
        return thumbnail(data: data, pixels: pixels)
    }
}

extension AppModel {
    /// Thumbnail for a row of the iPod list: queued cover → cover stored on the iPod → cover inside the file.
    func artSource(for row: IPodRow) -> ArtSource? {
        if let pid = row.pendingID {
            if let add = pendingAdds.first(where: { $0.id == pid }) {
                switch add.artwork {
                case .set(let d): return .data(d)
                case .remove: return nil
                case nil: break
                }
            }
            return .file(row.fileURL)
        }
        guard let id = row.trackID else { return nil }
        switch pendingArtwork[id] {
        case .set(let d): return .data(d)
        case .remove: return nil
        case nil: break
        }
        guard let device else { return nil }
        let db = artworkDB
        let url = row.fileURL
        let imageID = row.imageID, dbid = row.dbid
        return ArtSource(key: "ipod:\(device.id):\(id):\(artVersion)") {
            if let db, let img = device.thumbnail(db, imageID: imageID, songID: dbid) { return img }
            guard let url else { return nil }
            return await ArtworkCache.thumbnail(url: url, pixels: 112)
        }
    }
}
