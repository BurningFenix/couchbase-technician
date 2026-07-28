// QwenTextEmbedder.swift — on-device Qwen3-Embedding-0.6B over a static Core AI graph
// (Qwen3 backbone -> last-token pooling -> L2 normalize, all in-graph).
// Adapted from john-rocky/coreai-kit TextEmbedder (BSD-3-Clause).

import Foundation
import Tokenizers

final class QwenTextEmbedder: @unchecked Sendable {
    /// Task prefixes prepended before tokenization — Qwen3-Embedding is trained with
    /// asymmetric prompts: queries get an instruction prefix, documents none.
    struct Prompts: Sendable {
        var query: String
        var document: String

        static let qwen3Embedding = Prompts(
            query: "Instruct: Given a web search query, retrieve relevant passages that "
                + "answer the query\nQuery:",
            document: "")
    }

    private let graph: GraphModel
    private let tokenizer: any Tokenizer
    private let prompts: Prompts
    private let idsInput: String
    private let maskInput: String
    private let outputName: String
    let sequenceLength: Int
    let dimension: Int

    /// Loads a model (.aimodel or AOT-compiled .aimodelc) and its tokenizer folder.
    init(
        modelAt modelURL: URL,
        tokenizerAt tokenizerURL: URL,
        computeUnits: GraphModel.ComputeUnits = .neuralEngine,
        prompts: Prompts = .qwen3Embedding
    ) async throws {
        let graph = try await GraphModel(contentsOf: modelURL, computeUnits: computeUnits)
        self.graph = graph
        self.prompts = prompts
        self.tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerURL)

        guard
            let idsInput = graph.inputNames.first(where: { $0.contains("input_ids") }),
            let maskInput = graph.inputNames.first(where: { $0.contains("mask") }),
            let idsShape = graph.shape(ofInput: idsInput), idsShape.count == 2,
            let outputName = graph.outputNames.first,
            let outputShape = graph.shape(ofOutput: outputName)
        else {
            throw EmbedderError.bundleLayout(
                "unexpected embedding graph contract: inputs \(graph.inputNames), "
                    + "outputs \(graph.outputNames)")
        }
        self.idsInput = idsInput
        self.maskInput = maskInput
        self.sequenceLength = idsShape[1]
        self.outputName = outputName
        self.dimension = outputShape[outputShape.count - 1]
    }

    // MARK: - Embedding

    /// Embeds a search query (query prompt applied). L2-normalized.
    func embed(query: String) async throws -> [Float] {
        try await embed(text: prompts.query + query)
    }

    /// Embeds a document/passage (document prompt applied). L2-normalized.
    func embed(document: String) async throws -> [Float] {
        try await embed(text: prompts.document + document)
    }

    /// Embeds raw text with no prompt prefix. L2-normalized.
    func embed(text: String) async throws -> [Float] {
        var ids = tokenizer.encode(text: text).map(Int32.init)
        if ids.count > sequenceLength {
            ids = Array(ids.prefix(sequenceLength))
        }
        var mask = [Int32](repeating: 1, count: ids.count)
        let pad = Int32(0)
        while ids.count < sequenceLength {
            ids.append(pad)
            mask.append(0)
        }
        let outputs = try await graph.run([
            idsInput: .int32(ids, shape: [1, sequenceLength]),
            maskInput: .int32(mask, shape: [1, sequenceLength]),
        ])
        guard let embedding = outputs[outputName] else {
            throw EmbedderError.missingOutput(outputName)
        }
        return Array(embedding.floats().prefix(dimension))
    }
}
