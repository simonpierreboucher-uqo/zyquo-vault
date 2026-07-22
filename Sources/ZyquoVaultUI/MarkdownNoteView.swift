import SwiftUI
import ZyquoVaultDesign

/// Safe Markdown rendering for secure notes (§10.10): pure SwiftUI text — no
/// HTML, no script execution, no network, no image loading. Supports headings,
/// bullet/numbered lists, checklists, code blocks, quotes, rules, and inline
/// emphasis (via Foundation's Markdown parser, inline-only per line).
struct MarkdownNoteView: View {
    let source: String

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(Int, String)
        case checklist(done: Bool, text: String)
        case quote(String)
        case code([String])
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Zyquo.spacing.xs) {
            ForEach(Array(Self.parse(source).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: Parsing (line-oriented, crash-free on any input)

    nonisolated static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var codeBuffer: [String]?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let buffer = codeBuffer {
                    blocks.append(.code(buffer))
                    codeBuffer = nil
                } else {
                    codeBuffer = []
                }
                continue
            }
            if codeBuffer != nil {
                codeBuffer?.append(rawLine)
                continue
            }
            if line.isEmpty { continue }
            if line == "---" || line == "***" || line == "___" {
                blocks.append(.rule)
            } else if let heading = parseHeading(line) {
                blocks.append(heading)
            } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                blocks.append(.checklist(done: true, text: String(line.dropFirst(6))))
            } else if line.hasPrefix("- [ ] ") {
                blocks.append(.checklist(done: false, text: String(line.dropFirst(6))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let numbered = parseNumbered(line) {
                blocks.append(numbered)
            } else if line.hasPrefix("> ") {
                blocks.append(.quote(String(line.dropFirst(2))))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        if let buffer = codeBuffer, !buffer.isEmpty {
            blocks.append(.code(buffer)) // unterminated fence: still render safely
        }
        return blocks
    }

    nonisolated private static func parseHeading(_ line: String) -> Block? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
    }

    nonisolated private static func parseNumbered(_ line: String) -> Block? {
        guard let dot = line.firstIndex(of: "."),
              let number = Int(line[line.startIndex..<dot]),
              line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " " else { return nil }
        return .numbered(number, String(line[line.index(dot, offsetBy: 2)...]))
    }

    // MARK: Rendering

    /// Inline emphasis only — links render as styled text, never auto-opened.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? Zyquo.type.title : (level == 2 ? Zyquo.type.headline : Zyquo.type.body.weight(.semibold)))
                .foregroundStyle(Zyquo.color.inkPrimary)
                .padding(.top, Zyquo.spacing.xxs)
        case .paragraph(let text):
            Text(inline(text))
                .font(Zyquo.type.body)
                .foregroundStyle(Zyquo.color.inkPrimary)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: Zyquo.spacing.xs) {
                Text("•").foregroundStyle(Zyquo.color.accent)
                Text(inline(text)).font(Zyquo.type.body).foregroundStyle(Zyquo.color.inkPrimary)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: Zyquo.spacing.xs) {
                Text("\(number).")
                    .font(Zyquo.type.body.monospacedDigit())
                    .foregroundStyle(Zyquo.color.inkSecondary)
                Text(inline(text)).font(Zyquo.type.body).foregroundStyle(Zyquo.color.inkPrimary)
            }
        case .checklist(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: Zyquo.spacing.xs) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? Zyquo.color.positive : Zyquo.color.inkTertiary)
                    .font(.system(size: 12))
                Text(inline(text))
                    .font(Zyquo.type.body)
                    .foregroundStyle(Zyquo.color.inkPrimary)
                    .strikethrough(done, color: Zyquo.color.inkTertiary)
            }
        case .quote(let text):
            HStack(spacing: Zyquo.spacing.xs) {
                RoundedRectangle(cornerRadius: Zyquo.radius.xs, style: .continuous)
                    .fill(Zyquo.color.accentSoft)
                    .frame(width: 3)
                Text(inline(text))
                    .font(Zyquo.type.body.italic())
                    .foregroundStyle(Zyquo.color.inkSecondary)
            }
        case .code(let lines):
            Text(lines.joined(separator: "\n"))
                .font(Zyquo.type.mono)
                .foregroundStyle(Zyquo.color.inkPrimary)
                .padding(Zyquo.spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Zyquo.radius.s, style: .continuous)
                        .fill(Zyquo.color.surfaceSunken)
                )
        case .rule:
            Rectangle()
                .fill(Zyquo.color.hairline)
                .frame(height: 1)
                .padding(.vertical, Zyquo.spacing.xxs)
        }
    }
}
