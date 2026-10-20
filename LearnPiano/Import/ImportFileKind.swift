import Foundation
import UniformTypeIdentifiers

/// What an imported file (or downloaded link) contains, decided by content first, then MIME type, then extension.
enum ImportFileKind: String, Hashable, Sendable, CaseIterable {
    /// Uncompressed MusicXML (`.musicxml`, `.xml`).
    case musicXML
    /// Compressed MusicXML (`.mxl`, a ZIP container).
    case compressedMusicXML
    /// Standard MIDI File.
    case midi
    /// LearnPiano compact score JSON (`lpc-1`).
    case compactScore
    /// A PDF of sheet music (transcribed page by page).
    case pdf
    /// A picture of sheet music (PNG, JPEG, HEIC, …).
    case image
    /// An HTML page: the link pointed at a web page, not at a file.
    case webPage

    /// Needs optical music recognition (the Claude transcription provider).
    var isSheet: Bool { self == .pdf || self == .image }

    /// Imported exactly by a Parsers importer.
    var isSymbolic: Bool { self == .musicXML || self == .compressedMusicXML || self == .midi || self == .compactScore }

    var displayName: String {
        switch self {
        case .musicXML: return "MusicXML"
        case .compressedMusicXML: return "Compressed MusicXML"
        case .midi: return "MIDI"
        case .compactScore: return "LearnPiano score"
        case .pdf: return "PDF"
        case .image: return "Image"
        case .webPage: return "Web page"
        }
    }

    /// Extension used when a downloaded file has none.
    var preferredExtension: String {
        switch self {
        case .musicXML: return "musicxml"
        case .compressedMusicXML: return "mxl"
        case .midi: return "mid"
        case .compactScore: return "lpc"
        case .pdf: return "pdf"
        case .image: return "png"
        case .webPage: return "html"
        }
    }

    var systemImage: String {
        switch self {
        case .musicXML, .compressedMusicXML, .compactScore: return "music.note.list"
        case .midi: return "pianokeys"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .webPage: return "globe"
        }
    }
}

/// Decides the `ImportFileKind` of some bytes. Content sniffing wins because servers and file names lie
/// (an `.mxl` that is plain XML, a `.pdf` link that returns an HTML error page).
enum ImportFileSniffer {
    /// Content → MIME type → extension. Returns nil when nothing matches.
    static func kind(data: Data, fileName: String?, mimeType: String?) -> ImportFileKind? {
        if let k = kind(forContent: data) { return k }
        if let mime = mimeType, let k = kind(forMIMEType: mime) { return k }
        if let name = fileName {
            let ext = (name as NSString).pathExtension
            if let k = kind(forExtension: ext) { return k }
        }
        return nil
    }

    /// Magic numbers and text markers.
    static func kind(forContent data: Data) -> ImportFileKind? {
        let head = [UInt8](data.prefix(4096))
        guard !head.isEmpty else { return nil }
        func starts(with bytes: [UInt8], at offset: Int = 0) -> Bool {
            guard head.count >= offset + bytes.count else { return false }
            return Array(head[offset..<(offset + bytes.count)]) == bytes
        }
        func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

        if starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .image } // PNG
        if starts(with: [0xFF, 0xD8, 0xFF]) { return .image } // JPEG
        if starts(with: ascii("GIF87a")) || starts(with: ascii("GIF89a")) { return .image }
        if starts(with: ascii("RIFF")) && starts(with: ascii("WEBP"), at: 8) { return .image }
        if starts(with: [0x49, 0x49, 0x2A, 0x00]) || starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .image } // TIFF
        if starts(with: ascii("ftyp"), at: 4), head.count >= 12 {
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "heim", "heis", "avif"].contains(brand) { return .image }
        }
        if starts(with: ascii("MThd")) { return .midi }
        if starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .compressedMusicXML } // ZIP container
        // PDF: "%PDF-" must appear within the first 1 KB.
        let pdfMarker = ascii("%PDF-")
        let searchLimit = min(head.count, 1024)
        if searchLimit >= pdfMarker.count {
            for i in 0...(searchLimit - pdfMarker.count) where head[i] == pdfMarker[0] {
                if Array(head[i..<(i + pdfMarker.count)]) == pdfMarker { return .pdf }
            }
        }

        // Text formats.
        var text = String(decoding: head, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.contains("<score-partwise") || trimmed.contains("<score-timewise") { return .musicXML }
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") || (trimmed.hasPrefix("<") && trimmed.contains("<html")) { return .webPage }
        if trimmed.hasPrefix("{"), trimmed.contains("\"lpc-1\"") { return .compactScore }
        return nil
    }

    /// MIME type from an HTTP response (parameters such as `; charset=` are ignored). Ambiguous types return nil.
    static func kind(forMIMEType mime: String) -> ImportFileKind? {
        let base = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch base {
        case "application/pdf", "application/x-pdf": return .pdf
        case "audio/midi", "audio/x-midi", "audio/mid", "audio/sp-midi": return .midi
        case "application/vnd.recordare.musicxml+xml": return .musicXML
        case "application/vnd.recordare.musicxml": return .compressedMusicXML
        case "text/html", "application/xhtml+xml": return .webPage
        default:
            if base.hasPrefix("image/") { return .image }
            return nil
        }
    }

    /// File-name extension (case-insensitive).
    static func kind(forExtension ext: String) -> ImportFileKind? {
        switch ext.lowercased() {
        case "musicxml", "xml": return .musicXML
        case "mxl": return .compressedMusicXML
        case "mid", "midi", "smf", "kar": return .midi
        case "lpc": return .compactScore
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff": return .image
        case "html", "htm": return .webPage
        default: return nil
        }
    }

    /// A file name with a sensible extension for a download: the server's suggestion, else the URL's last path
    /// component, else "download"; the kind's extension is appended when the name has none.
    static func fileName(suggested: String?, url: URL?, kind: ImportFileKind?) -> String {
        var name = suggested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty || name == "Unknown" {
            let last = url?.lastPathComponent ?? ""
            name = (last.isEmpty || last == "/") ? "download" : last
        }
        name = name.replacingOccurrences(of: "/", with: "-")
        if (name as NSString).pathExtension.isEmpty, let kind {
            name += "." + kind.preferredExtension
        } else if let kind, kind != .webPage, let named = ImportFileSniffer.kind(forExtension: (name as NSString).pathExtension), named != kind,
                  !(named.isSheet && kind.isSheet) {
            // Content disagrees with the extension (e.g. "score.mxl" that is plain XML): keep the base name, fix the extension.
            name = ((name as NSString).deletingPathExtension) + "." + kind.preferredExtension
        }
        return name
    }

    /// Content types offered by the Files picker.
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .png, .jpeg, .heic, .image, .midi, .xml]
        let extra = [
            UTType("com.sajadabvi.learnpiano.musicxml"),
            UTType("com.sajadabvi.learnpiano.mxl"),
            UTType(filenameExtension: "musicxml"),
            UTType(filenameExtension: "mxl"),
            UTType(filenameExtension: "mid"),
            UTType(filenameExtension: "lpc"),
        ].compactMap { $0 }
        for t in extra where !types.contains(t) { types.append(t) }
        return types
    }
}

/// Turns what the learner pasted into a downloadable URL. Adds a missing `https://`, rejects non-web schemes, and
/// rewrites share links of common hosts into direct-download links.
enum ImportLinkNormalizer {
    static func url(from text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            if s.contains("://") { return nil }
            s = "https://" + s
        }
        guard var components = URLComponents(string: s), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), host.contains(".") else { return nil }

        // Dropbox share links: ?dl=0 shows a preview page; dl=1 downloads the file.
        if host.hasSuffix("dropbox.com") {
            var items = (components.queryItems ?? []).filter { $0.name != "dl" }
            items.append(URLQueryItem(name: "dl", value: "1"))
            components.queryItems = items
        }
        // Google Drive viewer links: /file/d/<id>/view → uc?export=download&id=<id>.
        if host == "drive.google.com" {
            let parts = components.path.split(separator: "/").map(String.init)
            if let i = parts.firstIndex(of: "d"), parts.indices.contains(i + 1), parts.first == "file" {
                components.path = "/uc"
                components.queryItems = [URLQueryItem(name: "export", value: "download"), URLQueryItem(name: "id", value: parts[i + 1])]
            }
        }
        return components.url
    }
}
