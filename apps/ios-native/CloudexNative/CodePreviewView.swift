import SwiftUI
import UIKit

enum CodePreviewFile {
    private static let extensions: Set<String> = [
        "swift", "js", "jsx", "mjs", "cjs", "ts", "tsx", "json", "jsonc",
        "html", "htm", "css", "scss", "sass", "less", "xml", "svg",
        "py", "pyi", "rb", "php", "sh", "bash", "zsh", "fish",
        "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "m", "mm",
        "java", "kt", "kts", "go", "rs", "cs", "sql", "graphql",
        "yaml", "yml", "toml", "ini", "conf", "env", "properties",
        "md", "markdown", "txt", "log", "csv", "gitignore", "gitattributes",
        "dockerfile", "makefile", "gradle", "pbxproj", "plist"
    ]

    private static let names: Set<String> = [
        "dockerfile", "makefile", "gemfile", "podfile", "package.swift",
        ".gitignore", ".gitattributes", ".env", ".editorconfig"
    ]

    static func supports(fileName: String) -> Bool {
        let lowercased = fileName.lowercased()
        if names.contains(lowercased) { return true }
        return extensions.contains((lowercased as NSString).pathExtension)
    }

    static func decode(_ data: Data) -> String? {
        guard !data.prefix(8_192).contains(0) else { return nil }
        if let value = String(data: data, encoding: .utf8) { return value }
        if let value = String(data: data, encoding: .utf16) { return value }
        if let value = String(data: data, encoding: .isoLatin1) { return value }
        return nil
    }
}

struct CodePreviewView: UIViewRepresentable {
    let source: String
    let fileName: String

    func makeUIView(context: Context) -> NativeCodePreviewView {
        NativeCodePreviewView()
    }

    func updateUIView(_ view: NativeCodePreviewView, context: Context) {
        view.display(source: source, fileName: fileName)
    }
}

final class NativeCodePreviewView: UIView, UIScrollViewDelegate {
    private let verticalScrollView = UIScrollView()
    private let gutterView = UITextView()
    private let codeView = UITextView()
    private var source = ""
    private var fileName = ""
    private var lastAppearance: UIUserInterfaceStyle = .unspecified

    private let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let lineHeight: CGFloat = 19
    private let gutterWidth: CGFloat = 54
    private let horizontalPadding: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .systemBackground

        verticalScrollView.alwaysBounceVertical = true
        verticalScrollView.alwaysBounceHorizontal = true
        verticalScrollView.isDirectionalLockEnabled = true
        verticalScrollView.keyboardDismissMode = .interactive
        verticalScrollView.contentInsetAdjustmentBehavior = .automatic
        verticalScrollView.delegate = self
        addSubview(verticalScrollView)

        gutterView.isEditable = false
        gutterView.isSelectable = false
        gutterView.isScrollEnabled = false
        gutterView.textContainerInset = UIEdgeInsets(top: 12, left: 4, bottom: 18, right: 8)
        gutterView.textContainer.lineFragmentPadding = 0
        gutterView.textContainer.lineBreakMode = .byClipping
        verticalScrollView.addSubview(gutterView)

        codeView.isEditable = false
        codeView.isSelectable = true
        codeView.isScrollEnabled = false
        codeView.backgroundColor = .clear
        codeView.textContainerInset = UIEdgeInsets(top: 12, left: horizontalPadding, bottom: 18, right: horizontalPadding)
        codeView.textContainer.lineFragmentPadding = 0
        codeView.textContainer.lineBreakMode = .byClipping
        codeView.adjustsFontForContentSizeCategory = false
        verticalScrollView.addSubview(codeView)
        verticalScrollView.bringSubviewToFront(gutterView)
    }

    func display(source: String, fileName: String) {
        let appearance = traitCollection.userInterfaceStyle
        guard self.source != source || self.fileName != fileName || lastAppearance != appearance else { return }
        self.source = source
        self.fileName = fileName
        lastAppearance = appearance

        let palette = CodeHighlightPalette(dark: appearance == .dark)
        backgroundColor = palette.background
        verticalScrollView.backgroundColor = palette.background
        gutterView.backgroundColor = palette.gutterBackground
        gutterView.attributedText = makeLineNumbers(source: source, palette: palette)
        codeView.attributedText = CodeSyntaxHighlighter.highlight(
            source,
            fileName: fileName,
            font: font,
            lineHeight: lineHeight,
            palette: palette
        )
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            lastAppearance = .unspecified
            display(source: source, fileName: fileName)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        verticalScrollView.frame = bounds

        let lineCount = max(source.components(separatedBy: "\n").count, 1)
        let contentHeight = max(
            bounds.height + 1,
            CGFloat(lineCount) * lineHeight + codeView.textContainerInset.top + codeView.textContainerInset.bottom
        )
        gutterView.frame = CGRect(x: verticalScrollView.contentOffset.x, y: 0, width: gutterWidth, height: contentHeight)

        let viewportWidth = max(bounds.width - gutterWidth, 1)
        let measuredWidth = widestLineWidth(in: source)
        let codeWidth = max(viewportWidth, measuredWidth + horizontalPadding * 2)
        codeView.frame = CGRect(x: gutterWidth, y: 0, width: codeWidth, height: contentHeight)
        verticalScrollView.contentSize = CGSize(width: gutterWidth + codeWidth, height: contentHeight)
        verticalScrollView.bringSubviewToFront(gutterView)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard gutterView.frame.origin.x != scrollView.contentOffset.x else { return }
        var frame = gutterView.frame
        frame.origin.x = scrollView.contentOffset.x
        gutterView.frame = frame
    }

    private func widestLineWidth(in source: String) -> CGFloat {
        var widest: CGFloat = 0
        source.enumerateLines { line, _ in
            widest = max(widest, (line as NSString).size(withAttributes: [.font: self.font]).width)
        }
        return ceil(widest)
    }

    private func makeLineNumbers(source: String, palette: CodeHighlightPalette) -> NSAttributedString {
        let count = max(source.components(separatedBy: "\n").count, 1)
        let width = String(count).count
        let numbers = (1...count).map { String(format: "%\(width)d", $0) }.joined(separator: "\n")
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.alignment = .right
        return NSAttributedString(string: numbers, attributes: [
            .font: font,
            .foregroundColor: palette.lineNumber,
            .paragraphStyle: style
        ])
    }
}

struct CodeHighlightPalette {
    let background: UIColor
    let gutterBackground: UIColor
    let foreground: UIColor
    let lineNumber: UIColor
    let keyword: UIColor
    let type: UIColor
    let string: UIColor
    let number: UIColor
    let comment: UIColor
    let declaration: UIColor

    init(dark: Bool) {
        if dark {
            background = UIColor(red: 0.105, green: 0.112, blue: 0.128, alpha: 1)
            gutterBackground = UIColor(red: 0.125, green: 0.132, blue: 0.148, alpha: 1)
            foreground = UIColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1)
            lineNumber = UIColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1)
            keyword = UIColor(red: 0.95, green: 0.45, blue: 0.73, alpha: 1)
            type = UIColor(red: 0.42, green: 0.82, blue: 0.78, alpha: 1)
            string = UIColor(red: 0.98, green: 0.49, blue: 0.44, alpha: 1)
            number = UIColor(red: 0.74, green: 0.58, blue: 0.98, alpha: 1)
            comment = UIColor(red: 0.45, green: 0.65, blue: 0.36, alpha: 1)
            declaration = UIColor(red: 0.49, green: 0.70, blue: 1.00, alpha: 1)
        } else {
            background = UIColor(red: 0.985, green: 0.985, blue: 0.99, alpha: 1)
            gutterBackground = UIColor(red: 0.955, green: 0.958, blue: 0.968, alpha: 1)
            foreground = UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)
            lineNumber = UIColor(red: 0.50, green: 0.51, blue: 0.55, alpha: 1)
            keyword = UIColor(red: 0.67, green: 0.06, blue: 0.58, alpha: 1)
            type = UIColor(red: 0.10, green: 0.47, blue: 0.45, alpha: 1)
            string = UIColor(red: 0.77, green: 0.10, blue: 0.08, alpha: 1)
            number = UIColor(red: 0.36, green: 0.22, blue: 0.76, alpha: 1)
            comment = UIColor(red: 0.23, green: 0.50, blue: 0.18, alpha: 1)
            declaration = UIColor(red: 0.06, green: 0.32, blue: 0.72, alpha: 1)
        }
    }
}

enum CodeSyntaxHighlighter {
    private static let keywords = [
        "actor", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
        "default", "defer", "do", "else", "enum", "export", "extends", "fallthrough", "false", "final",
        "finally", "for", "from", "func", "function", "guard", "if", "import", "in", "init", "interface",
        "internal", "is", "let", "match", "mutating", "new", "nil", "null", "operator", "override", "package",
        "private", "protocol", "public", "repeat", "return", "self", "static", "struct", "subscript", "super",
        "switch", "throw", "throws", "true", "try", "typealias", "typeof", "var", "where", "while", "yield"
    ]

    private static let types = [
        "Any", "Array", "Bool", "Character", "Data", "Date", "Dictionary", "Double", "Error", "Float",
        "Int", "Int32", "Int64", "Never", "NSRange", "Optional", "Result", "Set", "String", "URL", "UUID",
        "UInt", "Void", "boolean", "byte", "char", "decimal", "double", "float", "int", "long", "number",
        "object", "short", "string", "undefined", "void"
    ]

    static func highlight(
        _ source: String,
        fileName: String,
        font: UIFont,
        lineHeight: CGFloat,
        palette: CodeHighlightPalette
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.tabStops = []
        style.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: font]).width

        let result = NSMutableAttributedString(string: source, attributes: [
            .font: font,
            .foregroundColor: palette.foreground,
            .paragraphStyle: style
        ])
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let lowercased = fileName.lowercased()
        let hashComments = ["py", "pyi", "rb", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml", "ini", "conf", "env"]
            .contains((lowercased as NSString).pathExtension)
        let markup = ["html", "htm", "xml", "svg"].contains((lowercased as NSString).pathExtension)

        let tokenPattern: String
        if markup {
            tokenPattern = "(?s:<!--.*?-->)|\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'"
        } else if hashComments {
            tokenPattern = "(?s:/\\*.*?\\*/)|(?m:#.*$)|\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`"
        } else {
            tokenPattern = "(?s:/\\*.*?\\*/)|(?m://.*$)|\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`"
        }

        var protectedRanges: [NSRange] = []
        if let regex = try? NSRegularExpression(pattern: tokenPattern) {
            regex.enumerateMatches(in: source, range: fullRange) { match, _, _ in
                guard let range = match?.range else { return }
                protectedRanges.append(range)
                let token = (source as NSString).substring(with: range)
                let isComment = token.hasPrefix("//") || token.hasPrefix("/*") || token.hasPrefix("#") || token.hasPrefix("<!--")
                result.addAttribute(.foregroundColor, value: isComment ? palette.comment : palette.string, range: range)
            }
        }

        apply(pattern: "\\b(?:\(keywords.joined(separator: "|")))\\b", color: palette.keyword, to: result, source: source, excluding: protectedRanges)
        apply(pattern: "\\b(?:\(types.joined(separator: "|")))\\b", color: palette.type, to: result, source: source, excluding: protectedRanges)
        apply(pattern: "(?<![A-Za-z_])(?:0x[0-9A-Fa-f]+|\\d+(?:\\.\\d+)?)", color: palette.number, to: result, source: source, excluding: protectedRanges)
        apply(pattern: "\\b(?:func|function|class|struct|enum|protocol|interface)\\s+([A-Za-z_][A-Za-z0-9_]*)", capture: 1, color: palette.declaration, to: result, source: source, excluding: protectedRanges)

        if markup {
            apply(pattern: "</?[A-Za-z][A-Za-z0-9:_-]*", color: palette.keyword, to: result, source: source, excluding: protectedRanges)
            apply(pattern: "\\b[A-Za-z_:][-A-Za-z0-9_:.]*(?=\\s*=)", color: palette.declaration, to: result, source: source, excluding: protectedRanges)
        }
        return result
    }

    private static func apply(
        pattern: String,
        capture: Int = 0,
        color: UIColor,
        to result: NSMutableAttributedString,
        source: String,
        excluding protectedRanges: [NSRange]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        regex.enumerateMatches(in: source, range: fullRange) { match, _, _ in
            guard let range = match?.range(at: capture), range.location != NSNotFound else { return }
            guard !protectedRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return }
            result.addAttribute(.foregroundColor, value: color, range: range)
        }
    }
}
