import Foundation

/// A Laya checkpoint Hunch can run, as Settings › Inference & decisions lists it: where it comes from (pinned to a
/// revision, every file with its size and sha256), its license, and what it is good for. The files come from Hunch's
/// own pinned list (the app passes them in), so heed never disagrees with the package about what a checkpoint is.
public struct HunchCheckpoint: Equatable, Sendable, Identifiable {
    public struct File: Equatable, Sendable, Codable {
        /// Relative to the checkpoint's directory.
        public var path: String
        public var size: Int64
        /// Lowercase hex.
        public var sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256.lowercased()
        }
    }

    /// Hunch's name for it, and `[hunch] checkpoint`: `english`, `multilingual`.
    public var id: String
    public var title: String
    /// `owner/name` on Hugging Face.
    public var repository: String
    /// A full commit hash.
    public var revision: String
    public var files: [File]
    public var encoder: String
    public var languages: String
    /// What it is good for and not, in a line.
    public var note: String
    /// SPDX id of the weights' license.
    public var license: String
    public var licenseURL: URL
    /// Settings' Set up and the pane suggest this one.
    public var recommended: Bool

    public init(
        id: String, title: String, repository: String, revision: String, files: [File], encoder: String,
        languages: String, note: String, license: String, licenseURL: URL, recommended: Bool
    ) {
        self.id = id
        self.title = title
        self.repository = repository
        self.revision = revision
        self.files = files
        self.encoder = encoder
        self.languages = languages
        self.note = note
        self.license = license
        self.licenseURL = licenseURL
        self.recommended = recommended
    }

    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    /// The repository at the pinned revision, for a person to look at.
    public var sourceURL: URL {
        URL(string: "https://huggingface.co/\(repository)/tree/\(revision)")!
    }

    /// Where `file` downloads from.
    public func url(for file: File, endpoint: URL = HunchCatalogue.huggingFace) -> URL {
        endpoint.appending(path: repository).appending(path: "resolve").appending(path: revision)
            .appending(path: file.path)
    }

    /// `<owner>--<name>/<revision>`, below the models folder: the layout Hunch's own store uses.
    public var directoryName: String {
        repository.replacingOccurrences(of: "/", with: "--") + "/" + revision
    }
}

/// The checkpoints Hunch supports, described for a person. The pinned files come from Hunch; the rest is heed's.
public enum HunchCatalogue {
    public static let huggingFace = URL(string: "https://huggingface.co")!

    /// What a checkpoint is, without its files.
    public struct Details: Equatable, Sendable {
        public var title: String
        public var encoder: String
        public var languages: String
        public var note: String
        public var license: String
        public var licenseURL: URL
        public var recommended: Bool
    }

    /// The checkpoints heed offers, by Hunch's name, in the order the pane lists them.
    public static let details: [(id: String, details: Details)] = [
        ("english", Details(
            title: "Laya English", encoder: "ModernBERT-large", languages: "English",
            note: "The one to use. On cleaned agent screens it told waiting from working 95% of the time before any "
                + "training.",
            license: "Apache-2.0", licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
            recommended: true
        )),
        ("multilingual", Details(
            title: "Laya multilingual", encoder: "mmBERT-base", languages: "Many languages",
            note: "Smaller, but answered near chance on agent screens. Its tokenizer derives from Gemma's and is "
                + "always fetched from the origin.",
            license: "Apache-2.0", licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
            recommended: false
        )),
    ]

    /// Hunch's pinned checkpoints joined with heed's details, in heed's order; ones heed has no details for are left
    /// out (a newer Hunch may know more than this heed shows).
    public static func make(
        _ pinned: [(name: String, repository: String, revision: String, files: [HunchCheckpoint.File])]
    ) -> [HunchCheckpoint] {
        details.compactMap { id, details in
            guard let checkpoint = pinned.first(where: { $0.name == id }) else { return nil }
            return HunchCheckpoint(
                id: id, title: details.title, repository: checkpoint.repository, revision: checkpoint.revision,
                files: checkpoint.files, encoder: details.encoder, languages: details.languages, note: details.note,
                license: details.license, licenseURL: details.licenseURL, recommended: details.recommended
            )
        }
    }

    /// Bytes as the pane says them: 807 MiB, 1.2 GiB, 52 MiB, 4 KiB.
    public static func size(_ bytes: Int64) -> String {
        let units = ["bytes", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(max(0, bytes))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) bytes" }
        return value >= 10 || unit < 3 ? "\(Int(value.rounded())) \(units[unit])"
            : String(format: "%.1f %@", value, units[unit])
    }
}
