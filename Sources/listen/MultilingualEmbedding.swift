import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import Tokenizers

extension Settings {
    static var multilingualSearch: Bool {
        get { defaults.bool(forKey: "multilingualSearch") }
        set { defaults.set(newValue, forKey: "multilingualSearch") }
    }
}

/// Only download() accesses the network. Inference loads a pinned local folder.
enum MultilingualEmbedding {
    static let revision = "614241f622f53c4eeff9890bdc4f31cfecc418b3"
    static let namespace = "mlx:e5-small:" + revision + ":tokenizer-v1:mean:l2:384:query-passage:chunks440"
    static var directory: URL { Library.root.appendingPathComponent("models/text-e5-small/" + revision) }
    static var available: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) }
    static let files = ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json",
                        "special_tokens_map.json", "sentencepiece.bpe.model", "1_Pooling/config.json"]

    static func download(progress: @escaping @Sendable (String) -> Void) async throws {
        if available { return }
        let staging = directory.deletingLastPathComponent().appendingPathComponent("download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (i, file) in files.enumerated() {
            try Task.checkCancellation()
            progress("Downloading multilingual search (\(i + 1) of \(files.count))")
            let url = URL(string: "https://huggingface.co/intfloat/multilingual-e5-small/resolve/" + revision + "/" + file)!
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ContextProblem.message("The search model download failed. Try again.") }
            let target = staging.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        // Validate the model and tokenizer before publishing a ready directory.
        _ = try await EmbedderModelFactory.shared.loadContainer(from: staging, using: LocalTokenizerLoader())
        try Data(revision.utf8).write(to: staging.appendingPathComponent("ready"), options: .atomic)
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !available {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            try FileManager.default.moveItem(at: staging, to: directory)
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: [Float]?
        func put(_ value: [Float]?) { lock.lock(); result = value; lock.unlock() }
        func get() -> [Float]? { lock.lock(); defer { lock.unlock() }; return result }
    }
    /// Synchronous MCP callers run off the main thread. The encoder owns its
    /// actor and transfers only evaluated Float arrays across that boundary.
    static func vector(_ text: String, query: Bool) -> LocalTextEmbedding.Vector? {
        guard available, !Thread.isMainThread else { return nil }
        let box = ResultBox(), done = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .utility) {
            defer { done.signal() }
            box.put(try? await Encoder.shared.vector(text, query: query))
        }
        guard done.wait(timeout: .now() + 30) == .success else { task.cancel(); return nil }
        guard let values = box.get() else { return nil }
        return LocalTextEmbedding.Vector(model: namespace, language: "multilingual", values: values)
    }

    private actor Encoder {
        static let shared = Encoder()
        private var loading: Task<EmbedderModelContainer, Error>?
        func vector(_ text: String, query: Bool) async throws -> [Float]? {
            if loading == nil {
                loading = Task { try await EmbedderModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader()) }
            }
            let container: EmbedderModelContainer
            do { container = try await loading!.value }
            catch { loading = nil; throw error }
            return try await container.perform { context -> [Float]? in
                let prefix = query ? "query: " : "passage: "
                let tokens = context.tokenizer.encode(text: prefix + text, addSpecialTokens: true)
                guard !tokens.isEmpty else { return nil }
                // Long inputs are covered by bounded windows, never silently
                // truncated. E5 gets its prefix and special tokens per window.
                var chunks: [[Int]] = []
                if tokens.count <= 512 { chunks = [tokens] }
                else {
                    let raw = context.tokenizer.encode(text: text, addSpecialTokens: false)
                    for start in stride(from: 0, to: raw.count, by: 440) {
                        let end = min(start + 440, raw.count)
                        let part = context.tokenizer.decode(tokenIds: Array(raw[start..<end]))
                        let encoded = context.tokenizer.encode(text: prefix + part, addSpecialTokens: true)
                        guard encoded.count <= 512 else { return nil }
                        chunks.append(encoded)
                    }
                }
                var vectors: [[Float]] = []
                for chunk in chunks {
                    try Task.checkCancellation()
                    let input = MLXArray(chunk).reshaped([1, chunk.count])
                    let mask = MLXArray.ones([1, chunk.count])
                    let output = context.model(input, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: input), attentionMask: mask)
                    let result = Pooling(strategy: .mean)(output, mask: mask, normalize: true, applyLayerNorm: false)
                    result.eval()
                    vectors.append(result.asArray(Float.self))
                }
                guard vectors.allSatisfy({ $0.count == 384 && $0.allSatisfy(\.isFinite) }) else { return nil }
                var mean = [Float](repeating: 0, count: 384)
                for vector in vectors { for i in mean.indices { mean[i] += vector[i] } }
                let norm = sqrt(mean.reduce(Float(0)) { $0 + $1 * $1 })
                guard norm > 0 else { return nil }
                return mean.map { $0 / norm }
            }
        }
    }
    private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
        func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
            LocalTokenizer(upstream: try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
        }
    }

    /// A reproducible local retrieval benchmark. The small public examples are
    /// synthetic and contain no library content; no provider request is made.
    static func evaluate() throws -> String {
        guard available else { throw ContextProblem.message("Download multilingual search before evaluating it.") }
        let passages = [
            "We are hiring a software developer for the Atlas project.",
            "Alice prefers short written follow-ups instead of phone calls.",
            "O lançamento foi adiado porque o fornecedor ainda não entregou as peças.",
            "Ben werkt sinds januari als ontwerper bij Northstar.",
            "We cannot hire anyone until the budget is approved.",
            "The cat is sleeping on the sofa next to the window.",
            "A reunião com a equipa de vendas será na sexta-feira.",
            "De klant heeft de factuur nog niet betaald.",
            "The forecast predicts heavy rain throughout the weekend.",
            "I handed leadership of Atlas to Priya on 2026-02-12."
        ]
        let queries: [(String, Int)] = [
            ("finding new staff", 0), ("quem está a recrutar programadores?", 0),
            ("wie zoekt een softwareontwikkelaar?", 0), ("how should I follow up with Alice?", 1),
            ("como prefere a Alice receber mensagens?", 1), ("why was the launch delayed?", 2),
            ("waarom is de lancering uitgesteld?", 2), ("where does Ben work?", 3),
            ("o que impede novas contratações?", 4), ("when is the sales meeting?", 6),
            ("unpaid customer invoice", 7), ("who took over the project?", 9)
        ]
        let start = Date()
        var durations: [Double] = []
        func embed(_ text: String, query: Bool) throws -> LocalTextEmbedding.Vector {
            let began = Date()
            guard let result = vector(text, query: query) else { throw ContextProblem.message("The local embedding model failed to encode an evaluation example.") }
            durations.append(Date().timeIntervalSince(began) * 1000); return result
        }
        let vectors = try passages.map { try embed($0, query: false) }
        struct Row: Encodable { var query: String; var expected: Int; var rank: Int; var top: Int; var expectedCosine: Double; var bestOtherCosine: Double }
        var rows: [Row] = []
        for (query, expected) in queries {
            let queryVector = try embed(query, query: true)
            let scores = vectors.enumerated().map { ($0.offset, LocalTextEmbedding.similarity(queryVector, $0.element) ?? -1) }.sorted { $0.1 > $1.1 }
            rows.append(Row(query: query, expected: expected, rank: scores.firstIndex(where: { $0.0 == expected })! + 1,
                top: scores[0].0, expectedCosine: scores.first(where: { $0.0 == expected })!.1, bestOtherCosine: scores.first(where: { $0.0 != expected })!.1))
        }
        let ordered = durations.dropFirst().sorted()
        let scanStart = Date()
        var checksum = 0.0
        for i in 0..<10_000 { checksum += LocalTextEmbedding.similarity(vectors[i % vectors.count], vectors[0]) ?? 0 }
        struct Report: Encodable {
            var model: String; var examples: Int; var top1: Double; var recallAt3: Double
            var coldEncodeMS: Double; var medianEncodeMS: Double; var p95EncodeMS: Double
            var exactScan10000MS: Double; var elapsedSeconds: Double; var checksum: Double; var rows: [Row]
        }
        return try ContextCLI.json(Report(model: namespace, examples: rows.count,
            top1: Double(rows.filter { $0.rank == 1 }.count) / Double(rows.count),
            recallAt3: Double(rows.filter { $0.rank <= 3 }.count) / Double(rows.count),
            coldEncodeMS: durations[0], medianEncodeMS: ordered[ordered.count / 2], p95EncodeMS: ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))],
            exactScan10000MS: Date().timeIntervalSince(scanStart) * 1000, elapsedSeconds: Date().timeIntervalSince(start), checksum: checksum, rows: rows))
    }
    private struct LocalTokenizer: MLXLMCommon.Tokenizer {
        let upstream: any Tokenizers.Tokenizer
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
