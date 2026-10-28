import Foundation

/// The models folder, `~/Library/Application Support/Heed/models`: checkpoints, a download in progress, and what heed
/// learned from you. Everything Hunch keeps is here, and nothing here leaves the Mac.
///
///     convaiinnovations--laya/<revision>/…          a checkpoint, once every file matched its sha256
///     .partial/convaiinnovations--laya--<revision>/  a download in progress (verified.json: files checked)
///     learning/examples.jsonl                        the training set
///     learning/record.json                           the last training run
///     learning/heads/<checkpoint>-<time>.safetensors the trained head in use
public struct HunchFolder: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func checkpoint(_ checkpoint: HunchCheckpoint) -> URL {
        root.appending(path: checkpoint.directoryName, directoryHint: .isDirectory)
    }

    public func staging(_ checkpoint: HunchCheckpoint) -> URL {
        root.appending(path: ".partial", directoryHint: .isDirectory)
            .appending(
                path: checkpoint.directoryName.replacingOccurrences(of: "/", with: "--"),
                directoryHint: .isDirectory
            )
    }

    /// The files of a download in progress that matched their sha256.
    public func verified(_ checkpoint: HunchCheckpoint) -> URL {
        staging(checkpoint).appending(path: "verified.json")
    }

    public var learning: URL { root.appending(path: "learning", directoryHint: .isDirectory) }
    public var examples: URL { learning.appending(path: "examples.jsonl") }
    public var record: URL { learning.appending(path: "record.json") }
    public var heads: URL { learning.appending(path: "heads", directoryHint: .isDirectory) }

    public func head(_ name: String) -> URL { heads.appending(path: name) }

    /// A new head's file name: the checkpoint and when it was trained, so names sort by age.
    public static func headName(checkpoint: String, at date: Date) -> String {
        "\(checkpoint)-\(Int(date.timeIntervalSince1970)).safetensors"
    }

    /// Head files to delete: every one but the head in use. A head is tens of megabytes; only one is kept.
    public static func headsToDelete(_ files: [String], inUse: String?) -> [String] {
        files.filter { $0 != inUse && $0.hasSuffix(".safetensors") }.sorted()
    }
}

/// What the models folder holds, for the pane.
public struct HunchDiskUsage: Equatable, Sendable {
    /// Per checkpoint id, downloaded.
    public var checkpoints: [String: Int64]
    /// Downloads in progress.
    public var partial: Int64
    public var examples: Int64
    public var heads: Int64

    public init(checkpoints: [String: Int64] = [:], partial: Int64 = 0, examples: Int64 = 0, heads: Int64 = 0) {
        self.checkpoints = checkpoints
        self.partial = partial
        self.examples = examples
        self.heads = heads
    }

    public var total: Int64 { checkpoints.values.reduce(0, +) + partial + examples + heads }

    /// "1.1 GiB: Laya English 807 MiB, training set 2 MiB, trained head 52 MiB".
    public func summary(titles: [String: String]) -> String {
        var parts = checkpoints.sorted { $0.key < $1.key }.map {
            "\(titles[$0.key] ?? $0.key) \(HunchCatalogue.size($0.value))"
        }
        if partial > 0 { parts.append("partial download \(HunchCatalogue.size(partial))") }
        if examples > 0 { parts.append("training set \(HunchCatalogue.size(examples))") }
        if heads > 0 { parts.append("trained head \(HunchCatalogue.size(heads))") }
        guard !parts.isEmpty else { return "Nothing yet." }
        return "\(HunchCatalogue.size(total)): " + parts.joined(separator: ", ")
    }
}
