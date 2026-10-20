import Foundation

/// One run of lesson text: either plain or bold.
struct CoursesTextRun: Hashable, Sendable {
    var text: String
    var isBold: Bool
}

/// The tiny markdown dialect used by lesson text blocks: paragraphs separated by blank lines, and `**bold**` spans.
/// Anything else is shown literally. An unmatched `**` is kept as literal text so a typo never swallows a paragraph.
enum CoursesMarkdown {
    /// Splits a text block into paragraphs at blank lines; single newlines stay inside a paragraph.
    static func paragraphs(in text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var result: [String] = []
        var current: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        if !current.isEmpty { result.append(current.joined(separator: "\n")) }
        return result
    }

    /// Parses `**bold**` spans into runs. Adjacent runs of the same weight are merged; empty runs are dropped.
    static func runs(in paragraph: String) -> [CoursesTextRun] {
        var runs: [CoursesTextRun] = []
        func append(_ text: String, bold: Bool) {
            guard !text.isEmpty else { return }
            if let last = runs.last, last.isBold == bold {
                runs[runs.count - 1].text += text
            } else {
                runs.append(CoursesTextRun(text: text, isBold: bold))
            }
        }

        var rest = Substring(paragraph)
        while let open = rest.range(of: "**") {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "**") else { break }
            append(String(rest[..<open.lowerBound]), bold: false)
            let inner = String(afterOpen[..<close.lowerBound])
            append(inner, bold: true)
            rest = afterOpen[close.upperBound...]
        }
        append(String(rest), bold: false)
        return runs
    }

    /// Plain text with the markers removed (used for accessibility and tests).
    static func plainText(_ paragraph: String) -> String {
        runs(in: paragraph).map(\.text).joined()
    }

    /// An attributed string for SwiftUI `Text`, with bold runs marked as strongly emphasized.
    static func attributed(_ paragraph: String) -> AttributedString {
        var result = AttributedString()
        for run in runs(in: paragraph) {
            var piece = AttributedString(run.text)
            if run.isBold { piece.inlinePresentationIntent = .stronglyEmphasized }
            result.append(piece)
        }
        return result
    }
}
