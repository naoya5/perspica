import Foundation

/// The parts a PFML3 prompt is built from, kept with the request so the
/// budget can drop optional sections and build the prompt again.
public struct PromptParts: Sendable, Equatable {
    public var source: String
    public var sourceLanguage: String?
    public var targetLanguage: String
    public var form: TranslationForm?
    public var context: String?
    public var history: [HistoryPair]
    public var glossary: [GlossaryPair]

    public init(
        source: String,
        sourceLanguage: String?,
        targetLanguage: String,
        form: TranslationForm?,
        context: String?,
        history: [HistoryPair],
        glossary: [GlossaryPair]
    ) {
        self.source = source
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.form = form
        self.context = context
        self.history = history
        self.glossary = glossary
    }

    public var prompt: String {
        PFML3.prompt(
            source: source,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            form: form,
            context: context,
            history: history,
            glossary: glossary
        )
    }
}

extension PFML3 {
    /// The request for one source chunk: the PFML3 prompt and SPEC 7.2's
    /// `max_tokens`. Every caller builds its request here, so `RequestBudget`
    /// can fit it into one slot before it is sent.
    public static func request(
        source: String,
        sourceLanguage: String? = nil,
        targetLanguage: String,
        form: TranslationForm? = nil,
        context: String? = nil,
        history: [HistoryPair] = [],
        glossary: [GlossaryPair] = []
    ) -> CompletionRequest {
        let parts = PromptParts(
            source: source,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            form: form,
            context: context,
            history: Array(history.suffix(historyLimit)),
            glossary: glossary
        )
        var request = CompletionRequest(prompt: parts.prompt, source: source)
        request.parts = parts
        return request
    }
}

/// SPEC 7.1: `-c 16384 --parallel 4` gives each request 4,096 tokens for the
/// prompt (source, context, history, glossary) and the output together.
///
/// The prompt is measured with an upper bound first: a byte-level tokenizer
/// never makes more tokens than the text has UTF-8 bytes (plus the BOS the
/// server adds), so a prompt under the bound needs no round trip. Only a
/// prompt that might not fit is counted exactly, by the engine's own
/// tokenizer, and then trimmed: the oldest history pair first, then glossary
/// entries from the end, then the context from its end. The source itself is
/// never cut; if it still does not fit, `max_tokens` is lowered (never below
/// SPEC 7.2's minimum of 256) and otherwise the request is refused.
public enum RequestBudget {
    public static let slotTokens = 4096

    public static func upperBound(_ prompt: String) -> Int {
        prompt.utf8.count + 1
    }

    public static func fitsWithoutCounting(_ request: CompletionRequest) -> Bool {
        upperBound(request.prompt) + request.maxTokens <= slotTokens
    }

    /// Fits `request` into one slot. `countTokens` returns the exact token
    /// count of a prompt; when it throws, the upper bound is used instead.
    public static func fit(
        _ request: CompletionRequest,
        countTokens: (String) async throws -> Int
    ) async throws -> CompletionRequest {
        if fitsWithoutCounting(request) { return request }

        func count(_ prompt: String) async -> Int {
            (try? await countTokens(prompt)) ?? upperBound(prompt)
        }

        var current = request
        var tokens = await count(current.prompt)
        if tokens + current.maxTokens <= slotTokens { return current }

        if var parts = current.parts {
            // Each exact count is a round trip, so the prompt is trimmed by
            // the bytes the overflow needs at the prompt's own tokens-per-byte
            // rate before it is counted again, and a prompt whose byte bound
            // already fits is not counted at all.
            while tokens + current.maxTokens > slotTokens {
                let overflow = tokens + current.maxTokens - slotTokens
                let bytes = max(1, current.prompt.utf8.count)
                let rate = min(1.0, Double(tokens) / Double(bytes))
                let target = max(1, Int((Double(overflow) / max(rate, 0.05)).rounded(.up)))
                var removed = 0
                var trimmedAny = false
                while removed < target, let trimmed = trimOnce(parts) {
                    removed += parts.prompt.utf8.count - trimmed.prompt.utf8.count
                    parts = trimmed
                    trimmedAny = true
                }
                guard trimmedAny else { break }
                current.prompt = parts.prompt
                current.parts = parts
                tokens = fitsWithoutCounting(current) ? upperBound(current.prompt) : await count(current.prompt)
            }
        }
        if tokens + current.maxTokens <= slotTokens { return current }

        let room = slotTokens - tokens
        guard room >= CompletionRequest.minimumMaxTokens else {
            throw EngineStreamError.requestTooLarge
        }
        current.maxTokens = room
        return current
    }

    /// One step of trimming, or nil when only the source is left.
    static func trimOnce(_ parts: PromptParts) -> PromptParts? {
        var next = parts
        if !next.history.isEmpty {
            next.history.removeFirst()
            return next
        }
        if !next.glossary.isEmpty {
            next.glossary.removeLast()
            return next
        }
        if let context = next.context, !context.isEmpty {
            let keep = context.count / 2
            next.context = keep < 16 ? nil : String(context.prefix(keep))
            return next
        }
        return nil
    }
}
