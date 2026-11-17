import SwiftUI
import AppKit
import UniformTypeIdentifiers
import IPodKit

// MARK: - Mac pane

struct MacPane: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: Set<String>
    let search: String
    @State private var sortOrder = [KeyPathComparator(\LocalTrack.artist)]

    private var rows: [LocalTrack] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? model.macTracks : model.macTracks.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.artist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
        }
        return base.sorted(using: sortOrder)
    }

    private var subtitle: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var p = model.macFolder.path
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        return p
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(systemImage: "folder", title: "Mac", subtitle: subtitle) {
                if model.macScanning {
                    ProgressView().controlSize(.small)
                    Text(LF("mac.scanning", model.macScanned))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(L("mac.change")) { model.chooseFolder() }
                    .controlSize(.small)
            }
            Divider()
            if model.macTracks.isEmpty && !model.macScanning {
                ContentUnavailableView {
                    Label(L("mac.empty.title"), systemImage: "music.note.list")
                } description: {
                    Text(L("mac.empty.text"))
                } actions: {
                    Button(L("mac.change")) { model.chooseFolder() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .paneBackground()
    }

    private var table: some View {
        Table(of: LocalTrack.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { (t: LocalTrack) in
                ArtworkThumb(url: t.url)
            }
            .width(30)
            TableColumn(L("col.title"), value: \LocalTrack.title) { t in
                Text(t.title).foregroundStyle(t.supported ? .primary : .secondary)
            }
            TableColumn(L("col.artist"), value: \LocalTrack.artist) { t in
                Text(t.artist).foregroundStyle(.secondary)
            }
            TableColumn(L("col.album"), value: \LocalTrack.album) { t in
                Text(t.album).foregroundStyle(.secondary)
            }
            TableColumn(L("col.time"), value: \LocalTrack.durationMs) { t in
                Text(formatDuration(t.durationMs))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 50, max: 70)
            TableColumn(L("col.format"), value: \LocalTrack.formatLabel) { t in
                if t.supported {
                    Text(t.formatLabel).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(LF("format.unsupported", t.formatLabel))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .help(L("format.unsupported.help"))
                }
            }
            .width(min: 50, ideal: 64, max: 110)
            TableColumn(L("col.onipod"), value: \LocalTrack.onIPodSort) { t in
                if t.onIPod {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help(L("mac.onipod"))
                }
            }
            .width(min: 26, ideal: 30, max: 40)
        } rows: {
            ForEach(rows) { t in
                TableRow(t)
                    .itemProvider {
                        t.supported ? NSItemProvider(object: t.url as NSURL) : nil
                    }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button(L("mac.add")) { model.addFromMac(ids) }
                .disabled(model.session == nil || ids.isEmpty)
            Button(L("mac.reveal")) {
                let urls = model.macTracks.filter { ids.contains($0.id) }.map { $0.url }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            .disabled(ids.isEmpty)
        } primaryAction: { ids in
            if model.session != nil { model.addFromMac(ids) }
        }
    }
}

// MARK: - iPod pane

struct IPodPane: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: Set<String>
    let search: String
    let onShowInfo: (Set<String>) -> Void
    let onAutoTag: (Set<String>) -> Void
    @State private var sortOrder = [KeyPathComparator(\IPodRow.artist)]
    @State private var dropTargeted = false

    private var rows: [IPodRow] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? model.ipodRows : model.ipodRows.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.artist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
        }
        return base.sorted(using: sortOrder)
    }

    private var subtitle: String {
        guard model.session != nil else { return "" }
        let count = model.tracks.count - model.pendingDeletes.count + model.pendingAdds.count
        return LF("ipod.songs", count)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(systemImage: "ipod", title: "iPod", subtitle: subtitle) {
                if model.hasPending {
                    Text(pendingSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(L("pending.discard")) { model.discardPending() }
                        .controlSize(.small)
                }
            }
            Divider()
            content
        }
        .paneBackground()
        .overlay {
            if dropTargeted { dropOverlay }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            model.handleDrop(providers)
        }
    }

    private var pendingSummary: String {
        var parts: [String] = []
        if !model.pendingAdds.isEmpty { parts.append(LF("pending.add", model.pendingAdds.count)) }
        if !model.pendingDeletes.isEmpty { parts.append(LF("pending.delete", model.pendingDeletes.count)) }
        if !model.pendingEdits.isEmpty { parts.append(LF("pending.edit", model.pendingEdits.count)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if model.device == nil {
            ContentUnavailableView {
                Label(L("ipod.none.title"), systemImage: "ipod")
            } description: {
                Text(L("ipod.none.text"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = model.loadError {
            ContentUnavailableView {
                Label(L("ipod.error.title"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            } actions: {
                Button(L("ipod.refresh")) { model.refreshDevices() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.loading {
            ProgressView(L("ipod.loading"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            table
        }
    }

    private var table: some View {
        Table(of: IPodRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { (r: IPodRow) in
                ArtworkThumb(url: r.fileURL)
                    .opacity(r.status == .deleted ? 0.4 : 1)
            }
            .width(30)
            TableColumn(L("col.title"), value: \IPodRow.title) { r in
                HStack(spacing: 6) {
                    switch r.status {
                    case .added:
                        Badge(text: L("badge.new"), color: .accentColor)
                    case .deleted:
                        Badge(text: L("badge.deleted"), color: .red)
                    case .edited:
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                            .help(L("badge.edited"))
                    case .normal:
                        EmptyView()
                    }
                    Text(r.title)
                        .strikethrough(r.status == .deleted)
                        .foregroundStyle(r.status == .deleted ? .secondary : .primary)
                }
            }
            TableColumn(L("col.artist"), value: \IPodRow.artist) { r in
                Text(r.artist).foregroundStyle(.secondary)
            }
            TableColumn(L("col.album"), value: \IPodRow.album) { r in
                Text(r.album).foregroundStyle(.secondary)
            }
            TableColumn(L("col.time"), value: \IPodRow.durationMs) { r in
                Text(formatDuration(r.durationMs))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 50, max: 70)
            TableColumn(L("col.gain"), value: \IPodRow.gainSort) { r in
                Text(r.gainLabel)
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 64, max: 90)
        } rows: {
            ForEach(rows) { r in
                TableRow(r)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button(L("ctx.info")) { onShowInfo(ids) }
                .disabled(ids.isEmpty)
            Button(L("ctx.autotag")) { onAutoTag(ids) }
                .disabled(model.trackIDs(for: ids).isEmpty)
            Divider()
            Button(L("ctx.delete")) { model.markDeleted(ids) }
                .disabled(ids.isEmpty)
            Button(L("ctx.restore")) { model.restore(ids) }
                .disabled(ids.isEmpty)
        } primaryAction: { ids in
            if !ids.isEmpty { onShowInfo(ids) }
        }
        .onDeleteCommand {
            model.markDeleted(selection)
        }
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                Text(model.session == nil ? L("drop.noipod") : L("drop.title"))
                    .font(.title3.weight(.semibold))
                Text(L("drop.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(6)
        .allowsHitTesting(false)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Capacity

struct CapacityBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let cap = model.capacity, cap.total > 0 {
            let total = Double(cap.total)
            let used = Double(cap.total - cap.available)
            let music = min(Double(model.musicBytes - model.pendingDeleteBytes), used)
            let other = max(used - Double(model.musicBytes), 0)
            let adding = Double(model.pendingAddBytes)
            let freeAfter = cap.available - model.pendingAddBytes + model.pendingDeleteBytes
            HStack(spacing: 14) {
                GeometryReader { geo in
                    let w = geo.size.width
                    HStack(spacing: 1) {
                        Rectangle().fill(Color.accentColor)
                            .frame(width: max(w * music / total, 0))
                        if adding > 0 {
                            Rectangle().fill(Color.cyan)
                                .frame(width: max(w * adding / total, 2))
                        }
                        Rectangle().fill(Color.gray)
                            .frame(width: max(w * other / total, 0))
                        Spacer(minLength: 0)
                    }
                    .frame(height: 8)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 12)
                legend(color: .accentColor, text: LF("cap.music", formatBytes(Int64(max(music, 0)))))
                if adding > 0 {
                    legend(color: .cyan, text: LF("cap.adding", formatBytes(Int64(adding))))
                }
                legend(color: .gray, text: LF("cap.other", formatBytes(Int64(other))))
                Text(LF("cap.free", formatBytes(max(freeAfter, 0))))
                    .font(.caption)
                    .foregroundStyle(freeAfter < 0 ? Color.red : Color.secondary)
            }
            .padding(.horizontal, 6)
        } else {
            EmptyView()
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}
