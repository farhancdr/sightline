import Foundation

/// Lexical rules for the lightweight highlighter. Not a parser: enough to color keywords,
/// strings, comments, numbers, types, calls and keys for the common languages in the workspace.
struct Language: Sendable {
    enum Mode: Sendable { case code, markdown, markup, plain }

    let name: String
    var mode: Mode = .code
    var keywords: Set<String> = []
    var constants: Set<String> = []
    var builtinTypes: Set<String> = []
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)?
    /// Quote characters that start a string.
    var quotes: Set<Character> = ["\"", "'"]
    /// Quotes whose strings may span lines (backticks, shell quotes, …).
    var multilineQuotes: Set<Character> = []
    var tripleQuotes = false
    var capitalizedIsType = false
    var highlightCalls = true
    /// JSON/YAML/TOML: a string or word followed by ":" (or "=") is a key.
    var keySeparator: Character?
    var caseInsensitiveKeywords = false
    /// Extra identifier characters (e.g. "-" for YAML keys / CSS properties, "$" for JS).
    var identifierExtras: Set<Character> = ["_"]
    /// `@decorator`, `#[attr]`-ish prefix highlighted as an attribute.
    var decoratorPrefix: Character?
    /// Shell-style `$VAR` / `${VAR}`.
    var dollarVariables = false
    /// Rust: `'a` is a lifetime, only `'x'` / `'\n'` are chars.
    var strictCharLiterals = false
}

extension Language {
    static func detect(path: String) -> Language {
        let name = (path as NSString).lastPathComponent
        let lower = name.lowercased()
        switch lower {
        case "dockerfile", "containerfile": return .dockerfile
        case "makefile", "gnumakefile": return .make
        case ".gitignore", ".dockerignore", ".npmignore", ".prettierignore", ".eslintignore", ".nvmrc", "codeowners":
            return .config
        case ".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile": return .shell
        default: break
        }
        if lower.hasPrefix(".env") { return .config }
        if lower.hasPrefix("dockerfile.") || lower.hasSuffix(".dockerfile") { return .dockerfile }

        switch (name as NSString).pathExtension.lowercased() {
        case "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs": return .typescript
        case "go": return .go
        case "rs": return .rust
        case "py", "pyi": return .python
        case "swift": return .swift
        case "java", "kt", "kts", "scala", "groovy", "gradle", "cs", "dart": return .jvm
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm": return .cFamily
        case "sh", "bash", "zsh", "fish", "command": return .shell
        case "json", "jsonc", "json5", "babelrc", "eslintrc", "prettierrc": return .json
        case "yml", "yaml": return .yaml
        case "toml", "ini", "cfg", "conf", "properties": return .toml
        case "md", "mdx", "markdown": return .markdown
        case "html", "htm", "xml", "svg", "plist", "vue", "svelte", "xib", "storyboard": return .markup
        case "css", "scss", "sass", "less": return .css
        case "sql", "ddl": return .sql
        case "rb", "rake", "gemspec": return .ruby
        case "php": return .php
        case "tf", "tfvars", "hcl": return .hcl
        case "graphql", "gql", "proto": return .schema
        case "lua": return .lua
        default: return .plain
        }
    }

    static let plain = Language(name: "Plain Text", mode: .plain)
    static let markdown = Language(name: "Markdown", mode: .markdown)
    static let markup = Language(name: "Markup", mode: .markup)

    private static let cComments = (open: "/*", close: "*/")

    static let typescript = Language(
        name: "TypeScript",
        keywords: [
            "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
            "declare", "default", "delete", "do", "else", "enum", "export", "extends", "finally", "for", "from",
            "function", "get", "if", "implements", "import", "in", "infer", "instanceof", "interface", "is", "keyof",
            "let", "namespace", "new", "of", "override", "package", "private", "protected", "public", "readonly",
            "return", "satisfies", "set", "static", "super", "switch", "this", "throw", "try", "type", "typeof",
            "var", "void", "while", "with", "yield",
        ],
        constants: ["true", "false", "null", "undefined", "NaN", "Infinity"],
        builtinTypes: ["string", "number", "boolean", "any", "unknown", "never", "object", "symbol", "bigint"],
        lineComments: ["//"], blockComment: cComments,
        quotes: ["\"", "'", "`"], multilineQuotes: ["`"],
        capitalizedIsType: true, identifierExtras: ["_", "$"], decoratorPrefix: "@"
    )

    static let go = Language(
        name: "Go",
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
            "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var",
        ],
        constants: ["true", "false", "nil", "iota"],
        builtinTypes: [
            "any", "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16",
            "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
        ],
        lineComments: ["//"], blockComment: cComments,
        quotes: ["\"", "'", "`"], multilineQuotes: ["`"]
    )

    static let rust = Language(
        name: "Rust",
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn",
            "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
            "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while",
        ],
        constants: ["true", "false", "None", "Some", "Ok", "Err"],
        builtinTypes: [
            "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64",
            "bool", "char", "str", "String", "Vec", "Option", "Result", "Box",
        ],
        lineComments: ["//"], blockComment: cComments,
        quotes: ["\"", "'"], multilineQuotes: ["\""],
        capitalizedIsType: true, decoratorPrefix: "#", strictCharLiterals: true
    )

    static let python = Language(
        name: "Python",
        keywords: [
            "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif",
            "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match",
            "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
        ],
        constants: ["True", "False", "None", "self", "cls"],
        builtinTypes: ["int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "object"],
        lineComments: ["#"], tripleQuotes: true, capitalizedIsType: true, decoratorPrefix: "@"
    )

    static let swift = Language(
        name: "Swift",
        keywords: [
            "actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
            "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "fileprivate", "final",
            "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let",
            "mutating", "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat",
            "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript", "super", "switch",
            "throw", "throws", "try", "typealias", "var", "weak", "where", "while", "any",
        ],
        constants: ["true", "false", "nil"],
        lineComments: ["//"], blockComment: cComments,
        quotes: ["\""], tripleQuotes: true, capitalizedIsType: true, decoratorPrefix: "@"
    )

    static let jvm = Language(
        name: "JVM / C#",
        keywords: [
            "abstract", "as", "break", "case", "catch", "class", "companion", "const", "continue", "data", "default",
            "do", "else", "enum", "extends", "final", "finally", "for", "fun", "if", "implements", "import", "in",
            "interface", "internal", "is", "namespace", "new", "object", "open", "override", "package", "private",
            "protected", "public", "return", "sealed", "static", "super", "switch", "this", "throw", "throws", "try",
            "using", "val", "var", "void", "when", "while", "async", "await", "def", "record", "suspend",
        ],
        constants: ["true", "false", "null"],
        builtinTypes: ["int", "long", "short", "byte", "char", "float", "double", "boolean", "bool", "string"],
        lineComments: ["//"], blockComment: cComments,
        quotes: ["\"", "'"], tripleQuotes: true, capitalizedIsType: true, decoratorPrefix: "@"
    )

    static let cFamily = Language(
        name: "C / C++",
        keywords: [
            "auto", "break", "case", "class", "const", "constexpr", "continue", "default", "delete", "do", "else",
            "enum", "extern", "for", "goto", "if", "inline", "namespace", "new", "private", "protected", "public",
            "return", "sizeof", "static", "struct", "switch", "template", "this", "typedef", "typename", "union",
            "using", "virtual", "volatile", "while", "@interface", "@implementation", "@end", "@property",
        ],
        constants: ["true", "false", "NULL", "nullptr", "nil", "YES", "NO"],
        builtinTypes: ["void", "int", "char", "short", "long", "float", "double", "unsigned", "signed", "bool"],
        lineComments: ["//"], blockComment: cComments,
        capitalizedIsType: true, decoratorPrefix: "#"
    )

    static let shell = Language(
        name: "Shell",
        keywords: [
            "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in",
            "function", "return", "local", "export", "readonly", "declare", "set", "unset", "shift", "exit",
            "source", "alias", "echo", "cd", "eval", "exec", "trap",
        ],
        constants: ["true", "false"],
        lineComments: ["#"], multilineQuotes: ["\"", "'"],
        highlightCalls: false, identifierExtras: ["_", "-"], dollarVariables: true
    )

    static let config = Language(
        name: "Config", lineComments: ["#"], quotes: ["\"", "'"], highlightCalls: false,
        keySeparator: "=", identifierExtras: ["_", "-", "."], dollarVariables: true
    )

    static let dockerfile = Language(
        name: "Dockerfile",
        keywords: [
            "FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR",
            "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL", "AS",
        ],
        lineComments: ["#"], highlightCalls: false, dollarVariables: true
    )

    static let make = Language(
        name: "Makefile",
        keywords: ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define", "endef", "export"],
        lineComments: ["#"], highlightCalls: false, keySeparator: ":",
        identifierExtras: ["_", "-", "."], dollarVariables: true
    )

    static let json = Language(
        name: "JSON", constants: ["true", "false", "null"], lineComments: ["//"], blockComment: cComments,
        quotes: ["\""], highlightCalls: false, keySeparator: ":"
    )

    static let yaml = Language(
        name: "YAML", constants: ["true", "false", "null", "yes", "no", "on", "off", "~"],
        lineComments: ["#"], highlightCalls: false, keySeparator: ":",
        identifierExtras: ["_", "-", ".", "/"], decoratorPrefix: "&"
    )

    static let toml = Language(
        name: "TOML", constants: ["true", "false"], lineComments: ["#", ";"],
        tripleQuotes: true, highlightCalls: false, keySeparator: "=", identifierExtras: ["_", "-", "."]
    )

    static let css = Language(
        name: "CSS",
        keywords: ["@media", "@import", "@keyframes", "@font-face", "@supports", "@use", "@mixin", "@include",
                   "!important", "from", "to"],
        blockComment: cComments, highlightCalls: true, keySeparator: ":", identifierExtras: ["_", "-"],
        decoratorPrefix: "@", dollarVariables: true
    )

    static let sql = Language(
        name: "SQL",
        keywords: [
            "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table",
            "alter", "drop", "add", "column", "index", "view", "join", "left", "right", "inner", "outer", "full",
            "cross", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "is", "in",
            "between", "like", "distinct", "union", "all", "case", "when", "then", "else", "end", "primary", "key",
            "foreign", "references", "default", "with", "exists", "engine", "partition", "if", "asc", "desc",
            "materialized", "database", "final", "format", "settings",
        ],
        constants: ["null", "true", "false"],
        lineComments: ["--"], blockComment: cComments, caseInsensitiveKeywords: true
    )

    static let ruby = Language(
        name: "Ruby",
        keywords: [
            "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "for",
            "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then",
            "undef", "unless", "until", "when", "while", "yield", "require", "attr_accessor",
        ],
        constants: ["true", "false", "nil"], lineComments: ["#"], capitalizedIsType: true
    )

    static let php = Language(
        name: "PHP",
        keywords: [
            "abstract", "as", "break", "case", "catch", "class", "const", "continue", "default", "do", "echo", "else",
            "elseif", "extends", "final", "finally", "for", "foreach", "function", "if", "implements", "interface",
            "namespace", "new", "private", "protected", "public", "return", "static", "switch", "throw", "trait",
            "try", "use", "while", "fn", "match",
        ],
        constants: ["true", "false", "null"], lineComments: ["//", "#"], blockComment: cComments,
        capitalizedIsType: true, dollarVariables: true
    )

    static let hcl = Language(
        name: "HCL",
        keywords: ["resource", "data", "variable", "output", "module", "provider", "locals", "terraform", "for",
                   "in", "if", "dynamic", "content"],
        constants: ["true", "false", "null"], lineComments: ["#", "//"], blockComment: cComments,
        keySeparator: "=", identifierExtras: ["_", "-"]
    )

    static let schema = Language(
        name: "Schema",
        keywords: ["type", "query", "mutation", "subscription", "fragment", "on", "input", "enum", "interface",
                   "union", "scalar", "schema", "extend", "implements", "directive", "syntax", "package", "import",
                   "message", "service", "rpc", "returns", "repeated", "optional", "option"],
        constants: ["true", "false", "null"], lineComments: ["#", "//"], capitalizedIsType: true, decoratorPrefix: "@"
    )

    static let lua = Language(
        name: "Lua",
        keywords: ["and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local",
                   "not", "or", "repeat", "return", "then", "until", "while"],
        constants: ["true", "false", "nil"], lineComments: ["--"]
    )
}
