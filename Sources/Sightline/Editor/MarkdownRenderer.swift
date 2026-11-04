import Foundation
import Markdown

/// Markdown → HTML for the preview. Uses swift-markdown's parser (CommonMark + GFM tables, task lists,
/// strikethrough) with our own walker, because swift-markdown's `HTMLFormatter` doesn't escape text or code.
/// Code blocks are syntax highlighted with the editor's highlighter.
enum MarkdownRenderer {
    static func body(_ markdown: String) -> String {
        var walker = HTMLWalker()
        walker.visit(Document(parsing: markdown, options: [.disableSmartOpts]))
        return walker.html
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    /// GitHub-style slug for heading anchors.
    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" }
        return String(String.UnicodeScalarView(kept)).replacingOccurrences(of: " ", with: "-")
    }

    // MARK: Code blocks

    private static let languageExtensions: [String: String] = [
        "ts": "ts", "typescript": "ts", "tsx": "tsx", "js": "js", "javascript": "js", "jsx": "jsx", "mjs": "js",
        "go": "go", "golang": "go", "rust": "rs", "rs": "rs", "python": "py", "py": "py", "swift": "swift",
        "java": "java", "kotlin": "kt", "kt": "kt", "csharp": "cs", "cs": "cs", "c": "c", "cpp": "cpp", "c++": "cpp",
        "sh": "sh", "bash": "sh", "zsh": "sh", "shell": "sh", "console": "sh", "json": "json", "jsonc": "json",
        "yaml": "yml", "yml": "yml", "toml": "toml", "ini": "ini", "html": "html", "xml": "xml", "svg": "svg",
        "css": "css", "scss": "scss", "sql": "sql", "ruby": "rb", "rb": "rb", "php": "php", "hcl": "tf",
        "terraform": "tf", "tf": "tf", "graphql": "graphql", "proto": "proto", "lua": "lua", "dockerfile": "dockerfile",
        "makefile": "makefile", "make": "makefile", "env": "env",
    ]

    static func codeBlock(_ code: String, language: String?) -> String {
        let lang = (language ?? "").lowercased().split(separator: " ").first.map(String.init) ?? ""
        if lang == "diff" || lang == "patch" { return diffBlock(code) }
        // Rendered to SVG by Mermaid in the preview; shown as source if Mermaid isn't available.
        if lang == "mermaid" { return "<pre class=\"mermaid\">\(escape(code))</pre>\n" }
        let classAttr = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
        guard let ext = languageExtensions[lang] else {
            return "<pre><code\(classAttr)>\(escape(code))</code></pre>\n"
        }
        let path = ext == "dockerfile" || ext == "makefile" ? "/x/\(ext.capitalized)" : "/x/file.\(ext)"
        return "<pre><code\(classAttr)>\(highlighted(code, language: Language.detect(path: path)))</code></pre>\n"
    }

    /// Wraps highlighter tokens in `<span class="tok-…">`, escaping everything.
    static func highlighted(_ code: String, language: Language) -> String {
        let tokens = SyntaxHighlighter.tokens(for: code, language: language)
            .sorted { $0.range.location < $1.range.location }
        let utf16 = Array(code.utf16)
        func slice(_ from: Int, _ to: Int) -> String {
            String(decoding: utf16[from..<to], as: UTF16.self)
        }
        var out = ""
        var position = 0
        for token in tokens where token.range.location >= position && NSMaxRange(token.range) <= utf16.count {
            out += escape(slice(position, token.range.location))
            out += "<span class=\"tok-\(token.kind)\">\(escape(slice(token.range.location, NSMaxRange(token.range))))</span>"
            position = NSMaxRange(token.range)
        }
        out += escape(slice(position, utf16.count))
        return out
    }

    private static func diffBlock(_ code: String) -> String {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let text = escape(String(line))
            switch line.first {
            case "+": return "<span class=\"diff-add\">\(text)</span>"
            case "-": return "<span class=\"diff-del\">\(text)</span>"
            case "@": return "<span class=\"diff-hunk\">\(text)</span>"
            default: return "<span>\(text)</span>"
            }
        }
        // Every line is a block span, so no newline characters between them (they'd double-space).
        return "<pre class=\"diff\"><code>\(lines.joined())</code></pre>\n"
    }
}

/// Markdown AST → HTML.
private struct HTMLWalker: MarkupWalker {
    var html = ""
    private var tableAlignments: [Table.ColumnAlignment?] = []
    private var cellIndex = 0
    private var inTableHead = false

    mutating func visitDocument(_ document: Document) { descendInto(document) }

    mutating func visitHeading(_ heading: Heading) {
        let id = MarkdownRenderer.slug(heading.plainText)
        html += "<h\(heading.level) id=\"\(MarkdownRenderer.escape(id))\">"
        descendInto(heading)
        html += "</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        html += "<p>"
        descendInto(paragraph)
        html += "</p>\n"
    }

    mutating func visitText(_ text: Markdown.Text) { html += MarkdownRenderer.escape(text.string) }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) { html += "\n" }
    mutating func visitLineBreak(_ lineBreak: LineBreak) { html += "<br>\n" }
    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) { html += "<hr>\n" }

    mutating func visitEmphasis(_ emphasis: Emphasis) { wrap("em", emphasis) }
    mutating func visitStrong(_ strong: Strong) { wrap("strong", strong) }
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) { wrap("del", strikethrough) }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        html += "<code>\(MarkdownRenderer.escape(inlineCode.code))</code>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        html += MarkdownRenderer.codeBlock(codeBlock.code, language: codeBlock.language)
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        html += "<code>\(MarkdownRenderer.escape(symbolLink.destination ?? ""))</code>"
    }

    mutating func visitLink(_ link: Link) {
        let href = MarkdownRenderer.escape(link.destination ?? "")
        let title = link.title.map { " title=\"\(MarkdownRenderer.escape($0))\"" } ?? ""
        html += "<a href=\"\(href)\"\(title)>"
        descendInto(link)
        html += "</a>"
    }

    mutating func visitImage(_ image: Image) {
        let source = MarkdownRenderer.escape(image.source ?? "")
        let title = image.title.map { " title=\"\(MarkdownRenderer.escape($0))\"" } ?? ""
        html += "<img src=\"\(source)\" alt=\"\(MarkdownRenderer.escape(image.plainText))\"\(title)>"
    }

    // Raw HTML is passed through, as on GitHub (<details>, <img>, <br>…). The preview runs with
    // JavaScript disabled, so embedded scripts don't execute.
    mutating func visitHTMLBlock(_ html: HTMLBlock) { self.html += html.rawHTML }
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) { html += inlineHTML.rawHTML }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        html += "<blockquote>\n"
        descendInto(blockQuote)
        html += "</blockquote>\n"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) {
        let isTasks = list.listItems.contains { $0.checkbox != nil }
        html += isTasks ? "<ul class=\"tasks\">\n" : "<ul>\n"
        descendInto(list)
        html += "</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        html += list.startIndex == 1 ? "<ol>\n" : "<ol start=\"\(list.startIndex)\">\n"
        descendInto(list)
        html += "</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        html += "<li>"
        if let checkbox = listItem.checkbox {
            html += "<input type=\"checkbox\" disabled\(checkbox == .checked ? " checked" : "")> "
        }
        descendInto(listItem)
        html += "</li>\n"
    }

    mutating func visitTable(_ table: Table) {
        tableAlignments = table.columnAlignments
        html += "<table>\n"
        descendInto(table)
        html += "</table>\n"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        inTableHead = true
        cellIndex = 0
        html += "<thead><tr>"
        descendInto(tableHead)
        html += "</tr></thead>\n"
        inTableHead = false
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        html += "<tbody>\n"
        descendInto(tableBody)
        html += "</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        cellIndex = 0
        html += "<tr>"
        descendInto(tableRow)
        html += "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        let tag = inTableHead ? "th" : "td"
        var attrs = ""
        if cellIndex < tableAlignments.count, let alignment = tableAlignments[cellIndex] {
            attrs += " align=\"\(alignment == .left ? "left" : alignment == .right ? "right" : "center")\""
        }
        if tableCell.colspan > 1 { attrs += " colspan=\"\(tableCell.colspan)\"" }
        if tableCell.rowspan > 1 { attrs += " rowspan=\"\(tableCell.rowspan)\"" }
        html += "<\(tag)\(attrs)>"
        descendInto(tableCell)
        html += "</\(tag)>"
        cellIndex += Int(max(1, tableCell.colspan))
    }

    private mutating func wrap(_ tag: String, _ markup: Markup) {
        html += "<\(tag)>"
        descendInto(markup)
        html += "</\(tag)>"
    }
}
