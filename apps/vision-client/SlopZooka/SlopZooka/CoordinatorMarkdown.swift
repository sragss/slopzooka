import SwiftUI

/// Foundation parses Markdown; SwiftUI renders its semantic blocks without a web
/// view, HTML execution, remote images, or a second Markdown parser.
struct CoordinatorMarkdown: View {
    let text: String

    private struct Block: Identifiable {
        var id: Int
        var text = AttributedString()
        var heading = false
        var code = false
        var quote = false
        var marker: String?
    }

    private var blocks: [Block] {
        guard let parsed = try? AttributedString(markdown: text) else { return [Block(id: 0, text: AttributedString(text))] }
        var result: [Block] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let id = components.first?.identity ?? 0
            if result.last?.id != id {
                var block = Block(id: id)
                var ordinal: Int?
                var ordered = false
                for component in components {
                    switch component.kind {
                    case .header: block.heading = true
                    case .codeBlock: block.code = true
                    case .blockQuote: block.quote = true
                    case .listItem(let value): ordinal = value
                    case .orderedList: ordered = true
                    default: break
                    }
                }
                if let ordinal { block.marker = ordered ? "\(ordinal)." : "•" }
                result.append(block)
            }
            result[result.count - 1].text += AttributedString(parsed[run.range])
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                HStack(alignment: .top, spacing: 8) {
                    if block.quote { Rectangle().fill(.secondary).frame(width: 2) }
                    if let marker = block.marker { Text(marker).foregroundStyle(.secondary) }
                    Text(block.text)
                        .font(block.code ? .system(.callout, design: .monospaced) : block.heading ? .headline : .body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(block.code ? 10 : 0)
                .background(block.code ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}
