import Foundation

/// One downloadable PLaMo 3 Translate model (SPEC 7.5).
///
/// The numbers come from the Hugging Face API, not from the specification:
/// `https://huggingface.co/api/models/<repository>/tree/main` lists the file
/// `size` and the LFS `oid`, and the `oid` is the file's SHA-256. The local
/// 0.8B file was hashed as well and matched its `oid`.
public struct TranslationModel: Sendable, Identifiable, Equatable {
    /// Short id used in settings and in the demo options: `0.8b`, `2b`, `8b`.
    public let id: String
    public let displayName: String
    /// Hugging Face repository, e.g. `pfnet/plamo-3-translate-0.8b-GGUF`.
    public let repository: String
    public let fileName: String
    public let bytes: Int64
    public let sha256: String

    public init(
        id: String,
        displayName: String,
        repository: String,
        fileName: String,
        bytes: Int64,
        sha256: String
    ) {
        self.id = id
        self.displayName = displayName
        self.repository = repository
        self.fileName = fileName
        self.bytes = bytes
        self.sha256 = sha256
    }

    /// Where the file is fetched from (Hugging Face follows this on to its CDN).
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/main/\(fileName)")!
    }

    /// File size in GB, in the units the model cards use (two decimals).
    public var sizeInGigabytes: String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }

    /// The short form used in the panel's status line, e.g. `PLaMo 0.8B`.
    public var shortName: String {
        "PLaMo \(id.uppercased())"
    }

    /// Rough working-set estimate: the weights plus about half a gigabyte for
    /// the KV cache at 16k context and llama.cpp's own buffers.
    public var memoryEstimateBytes: Int64 { bytes + 540_000_000 }

    public var memoryHint: String {
        String(format: "約 %.1f GB", Double(memoryEstimateBytes) / 1_000_000_000)
    }

    /// The model card has accuracy tables but no throughput for these sizes, so
    /// the speed is described qualitatively rather than with a made-up number.
    public var speedHint: String {
        switch id {
        case "0.8b": "速い"
        case "2b": "標準"
        default: "おそい"
        }
    }

    /// A warning shown under the card when the working set is large (SPEC 7.5).
    public var memoryNote: String? {
        switch id {
        case "8b": "16GB の Mac ではほかのアプリを閉じて使う"
        default: nil
        }
    }
}

/// The three models the manager offers (SPEC 7.5). All are Q4_K_M GGUF, which
/// is what llama.cpp runs well on this Mac and what the model card recommends.
public enum ModelCatalog {
    public static let models: [TranslationModel] = [
        TranslationModel(
            id: "0.8b",
            displayName: "PLaMo 3 Translate 0.8B",
            repository: "pfnet/plamo-3-translate-0.8b-GGUF",
            fileName: "plamo-3-translate-0.8b-Q4_K_M.gguf",
            bytes: 573_123_200,
            sha256: "923b2f28a9856de1b8b3b610a7e59ded0b14d007466fd5dd526e6a9ecaadafdd"
        ),
        TranslationModel(
            id: "2b",
            displayName: "PLaMo 3 Translate 2B",
            repository: "pfnet/plamo-3-translate-2b-GGUF",
            fileName: "plamo-3-translate-2b-Q4_K_M.gguf",
            bytes: 1_807_199_392,
            sha256: "f36d0813dd95573a852ab5d76e374c543632d9e292929e922bcdbf7e53b494e0"
        ),
        TranslationModel(
            id: "8b",
            displayName: "PLaMo 3 Translate 8B",
            repository: "pfnet/plamo-3-translate-8b-GGUF",
            fileName: "plamo-3-translate-8b-Q4_K_M.gguf",
            bytes: 5_280_442_080,
            sha256: "47a04e86a67bcc352fa186f01159060aae594b73993e1d49dbfc0ef0081d01ad"
        ),
    ]

    public static func model(id: String?) -> TranslationModel? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    /// The default model (SPEC 7.5: 0.8B is the default).
    public static let defaultModelID = "0.8b"
}
