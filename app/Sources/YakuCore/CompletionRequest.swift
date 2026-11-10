import Foundation

/// Rough token count. ASCII text is about four characters per token; every
/// other scalar (CJK, accented Latin, symbols) is counted as one.
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        var ascii = 0
        var wide = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { wide += 1 }
        }
        return ascii / 4 + wide
    }
}

/// The JSON body of `POST /v1/completions` (SPEC 7.2).
public struct CompletionRequest: Sendable, Equatable {
    public static let stopSequences = ["<|plamo:tag|>", "<|plamo:bos|>"]
    public static let minimumMaxTokens = 256
    public static let maximumMaxTokens = 2048

    public var prompt: String
    public var maxTokens: Int
    public var temperature: Double
    public var stream: Bool
    public var cachePrompt: Bool
    public var stop: [String]
    /// What the prompt was built from, when it came from `PFML3.request`.
    /// Not sent; `RequestBudget` uses it to trim optional sections.
    public var parts: PromptParts?

    public init(
        prompt: String,
        maxTokens: Int,
        temperature: Double = 0,
        stream: Bool = true,
        cachePrompt: Bool = true,
        stop: [String] = CompletionRequest.stopSequences
    ) {
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stream = stream
        self.cachePrompt = cachePrompt
        self.stop = stop
    }

    /// Twice the estimated source length, clamped to 256...2048.
    public static func maxTokens(forSource source: String) -> Int {
        let doubled = TokenEstimator.estimate(source) * 2
        return min(maximumMaxTokens, max(minimumMaxTokens, doubled))
    }

    public init(prompt: String, source: String) {
        self.init(prompt: prompt, maxTokens: Self.maxTokens(forSource: source))
    }

    public func body(model: String) throws -> Data {
        let object: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stop": stop,
            "stream": stream,
            "cache_prompt": cachePrompt,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
