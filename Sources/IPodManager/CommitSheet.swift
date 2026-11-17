import SwiftUI
import IPodKit

struct CommitSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            icon
                .font(.system(size: 40))
                .frame(height: 48)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            detail
            buttons
        }
        .padding(28)
        .frame(width: 420)
        .interactiveDismissDisabled(model.commitState.isRunning)
    }

    @ViewBuilder
    private var icon: some View {
        switch model.commitState {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            Image(systemName: "ipod").foregroundStyle(Color.accentColor)
        }
    }

    private var title: String {
        switch model.commitState {
        case .idle: return L("commit.preparing")
        case .running(let phase):
            switch phase {
            case .copying: return L("commit.copying")
            case .changingFiles: return L("commit.files")
            case .writingArtwork: return L("commit.artwork")
            case .writingDatabase: return L("commit.writing")
            case .removingFiles: return L("commit.removing")
            case .finished: return L("commit.writing")
            }
        case .done: return L("commit.done")
        case .failed: return L("commit.failed")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.commitState {
        case .running(.copying(let done, let total, let name)):
            VStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                HStack {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(LF("commit.count", done, total)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .running(.changingFiles(let done, let total)):
            VStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                HStack {
                    Text(L("commit.dontunplug"))
                    Spacer()
                    Text(LF("commit.count", done, total)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .running, .idle:
            ProgressView().controlSize(.small)
            Text(L("commit.dontunplug")).font(.caption).foregroundStyle(.secondary)
        case .done:
            Text(L("commit.done.text"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            let lines = reportLines
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines, id: \.self) { Text($0) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
    }

    private var reportLines: [String] {
        let r = model.lastReport
        var out: [String] = []
        if r.artworkWritten > 0 { out.append(LF("report.art.ok", r.artworkWritten)) }
        if r.artworkUnsupported {
            out.append(L("report.art.unsupported"))
        } else if r.artworkFailed > 0 {
            out.append(LF("report.art.failed", r.artworkFailed))
        }
        if r.filesChanged > 0 { out.append(LF("report.files.ok", r.filesChanged)) }
        if r.filesRestored > 0 { out.append(LF("report.files.restored", r.filesRestored)) }
        if r.filesFailed > 0 { out.append(LF("report.files.failed", r.filesFailed)) }
        return out
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.commitState {
        case .done:
            HStack {
                Button(L("tool.eject")) {
                    dismiss()
                    model.eject()
                }
                Button(L("done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .failed:
            Button(L("ok")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        default:
            EmptyView()
        }
    }
}
