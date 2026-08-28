import CueCore
import SwiftUI

struct EvidenceListView: View {
    let evidence: [EvidenceReference]
    let onOpen: (EvidenceReference) -> Void
    let onCopy: (EvidenceReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(evidence) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.kind.symbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(item.kind.displayName)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            Text(item.label)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                        }
                        if let location = item.displayLocation {
                            Text(location)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        if let excerpt = item.excerpt, !excerpt.isEmpty {
                            Text(excerpt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        if item.kind == .screenContext {
                            HStack(spacing: 8) {
                                if let meetingTime = item.meetingTime {
                                    Text("会議時刻 \(formatTime(meetingTime))")
                                }
                                if let count = item.regions?.count, count > 0 {
                                    Text("変更領域 \(count)件")
                                }
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer(minLength: 4)

                    if item.isOpenable {
                        Button {
                            onOpen(item)
                        } label: {
                            Image(systemName: item.kind == .transcript ? "arrow.up.left" : "arrow.up.forward.app")
                        }
                        .buttonStyle(.plain)
                        .help(item.kind == .transcript ? "該当発言へ移動" : "根拠を開く")
                    }

                    Button {
                        onCopy(item)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("根拠の場所をコピー")
                }
                .padding(7)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private extension EvidenceReference {
    var displayLocation: String? {
        guard let location, !location.isEmpty else { return nil }
        return line.map { "\(location):\($0)" } ?? location
    }

    var isOpenable: Bool {
        switch kind {
        case .transcript, .projectFile, .sourceCode, .web, .screenContext:
            true
        case .gitHistory:
            false
        }
    }
}

private extension EvidenceKind {
    var displayName: String {
        switch self {
        case .transcript: "発言"
        case .projectFile: "資料"
        case .sourceCode: "ソース"
        case .gitHistory: "Git"
        case .web: "Web"
        case .screenContext: "画面"
        }
    }

    var symbolName: String {
        switch self {
        case .transcript: "text.bubble"
        case .projectFile: "doc.text"
        case .sourceCode: "chevron.left.forwardslash.chevron.right"
        case .gitHistory: "point.3.connected.trianglepath.dotted"
        case .web: "globe"
        case .screenContext: "rectangle.inset.filled.and.person.filled"
        }
    }
}
