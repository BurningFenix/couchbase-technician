// GraphModel.swift — run a stateless .aimodel/.aimodelc graph with dictionary-in /
// dictionary-out tensors, built on the system CoreAI framework.
// Adapted from john-rocky/coreai-kit (CoreAIKitVision, BSD-3-Clause), which follows
// the public-API usage of apple/coreai-models (BSD-3-Clause).

import CoreAI
import Foundation

enum EmbedderError: Error, LocalizedError, Sendable {
    case functionNotFound(String)
    case statefulGraphUnsupported([String])
    case unknownInput(String)
    case shapeMismatch(input: String, expected: [Int], got: [Int])
    case dtypeMismatch(input: String, expected: String)
    case unsupportedScalarType(String)
    case missingOutput(String)
    case bundleLayout(String)

    var errorDescription: String? {
        switch self {
        case .functionNotFound(let name):
            return "Graph function '\(name)' not found in model"
        case .statefulGraphUnsupported(let states):
            return "GraphModel runs stateless graphs only; model declares states \(states)"
        case .unknownInput(let name):
            return "Model has no input named '\(name)'"
        case .shapeMismatch(let input, let expected, let got):
            return "Input '\(input)' expects shape \(expected), got \(got)"
        case .dtypeMismatch(let input, let expected):
            return "Input '\(input)' expects \(expected) scalars"
        case .unsupportedScalarType(let type):
            return "Unsupported scalar type \(type)"
        case .missingOutput(let name):
            return "Output '\(name)' missing after run"
        case .bundleLayout(let message):
            return message
        }
    }
}

/// A loaded, specialized graph function.
final class GraphModel: @unchecked Sendable {
    enum ComputeUnits: Sendable {
        case neuralEngine, gpu, cpu
    }

    private let function: InferenceFunction
    private let descriptor: InferenceFunctionDescriptor
    let inputNames: [String]
    let outputNames: [String]

    /// Loads and specializes a model (a raw .aimodel compiles on first load and is
    /// cached; an AOT-compiled .aimodelc skips the on-device compile).
    init(
        contentsOf url: URL, function name: String = "main",
        computeUnits: ComputeUnits = .gpu
    ) async throws {
        let options: SpecializationOptions
        switch computeUnits {
        case .neuralEngine:
            options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        case .gpu:
            options = SpecializationOptions(preferredComputeUnitKind: .gpu)
        case .cpu:
            options = SpecializationOptions(preferredComputeUnitKind: .cpu)
        }
        let model = try await AIModel(contentsOf: url, options: options)
        guard let descriptor = model.functionDescriptor(for: name) else {
            throw EmbedderError.functionNotFound(name)
        }
        guard descriptor.stateNames.isEmpty else {
            throw EmbedderError.statefulGraphUnsupported(descriptor.stateNames)
        }
        guard let function = try model.loadFunction(named: name) else {
            throw EmbedderError.functionNotFound(name)
        }
        self.descriptor = descriptor
        self.function = function
        self.inputNames = descriptor.inputNames
        self.outputNames = descriptor.outputNames
    }

    /// Declared input shape (dynamic dimensions are negative), or nil for unknown names.
    func shape(ofInput name: String) -> [Int]? {
        guard case .ndArray(let d) = descriptor.inputDescriptor(of: name) else { return nil }
        return d.shape
    }

    /// Declared output shape (dynamic dimensions are negative), or nil for unknown names.
    func shape(ofOutput name: String) -> [Int]? {
        guard case .ndArray(let d) = descriptor.outputDescriptor(of: name) else { return nil }
        return d.shape
    }

    /// Runs one inference. Every declared input must be provided; scalar types convert
    /// automatically between float16/float32 where needed.
    func run(_ inputs: [String: TensorValue]) async throws -> [String: TensorValue] {
        var ndInputs: [String: NDArray] = [:]
        for (name, value) in inputs {
            guard case .ndArray(let d) = descriptor.inputDescriptor(of: name) else {
                throw EmbedderError.unknownInput(name)
            }
            guard d.shape.count == value.shape.count,
                zip(d.shape, value.shape).allSatisfy({ $0 < 0 || $0 == $1 })
            else {
                throw EmbedderError.shapeMismatch(
                    input: name, expected: d.shape, got: value.shape)
            }
            let resolved = d.resolvingDynamicDimensions(value.shape)
            ndInputs[name] = try value.makeNDArray(descriptor: resolved, inputName: name)
        }

        var rawOutputs = try await function.run(inputs: ndInputs)
        var outputs: [String: TensorValue] = [:]
        for name in outputNames {
            guard let array = rawOutputs.remove(name)?.ndArray else {
                throw EmbedderError.missingOutput(name)
            }
            outputs[name] = try TensorValue(reading: array)
        }
        return outputs
    }
}
