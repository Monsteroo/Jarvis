import Foundation
import CoreML

/// Local Ukrainian fine-tune of Parakeet TDT v3, CC BY 4.0, by Yuri Ihnatov.
/// TDT stepping follows FluidAudio (Apache-2.0). No language autodetection.
/// Models and predictions are serialized by LocalSpeech; cancel is thread-safe.
final class ParakeetASR {
    static let maximumSamples = 240_000 // Fixed Core ML input: 15 seconds at 16 kHz.
    enum Failure: Error { case invalidAudio, cancelled, modelMismatch, decoderLimit }
    private let preprocessor: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel
    private let vocabulary: [String: String]
    private let cancellationLock = NSLock()
    private var cancelled = false

    init(root: URL) throws {
        let config = MLModelConfiguration()
        // Measured warm CPU ~0.94s, ANE ~0.92s; CPU avoids a ~31s first load.
        config.computeUnits = .cpuOnly
        func load(_ name: String) throws -> MLModel {
            try MLModel(contentsOf: root.appendingPathComponent(name + ".mlmodelc"), configuration: config)
        }
        preprocessor = try load("Preprocessor")
        encoder = try load("Encoder")
        decoder = try load("Decoder")
        joint = try load("JointDecisionv3")
        vocabulary = try JSONDecoder().decode([String:String].self,
            from: Data(contentsOf: root.appendingPathComponent("parakeet_v3_vocab.json")))
    }

    func cancel() { cancellationLock.lock(); cancelled = true; cancellationLock.unlock() }
    func resetCancellation() { cancellationLock.lock(); cancelled = false; cancellationLock.unlock() }
    private func checkCancellation() throws {
        cancellationLock.lock(); let stopped = cancelled; cancellationLock.unlock()
        if stopped { throw Failure.cancelled }
    }

    static func alphabetAllows(_ text: String, language: String) -> Bool {
        guard language == "uk" || language == "en", !text.contains("<"), !text.contains(">") else { return false }
        let uk = "АБВГҐДЕЄЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЬЮЯабвгґдеєжзиіїйклмнопрстуфхцчшщьюя"
        return text.unicodeScalars.allSatisfy { scalar in
            if !CharacterSet.letters.contains(scalar) { return true }
            let ascii = (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
            return ascii || (language == "uk" && uk.unicodeScalars.contains(scalar))
        }
    }

    private func zeros(_ shape: [Int], type: MLMultiArrayDataType = .float32) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: shape.map { NSNumber(value:$0) }, dataType: type)
        for i in 0..<result.count { result[i] = 0 }
        return result
    }
    private func predict(_ model: MLModel, _ inputs: [String:MLMultiArray]) throws -> MLFeatureProvider {
        try checkCancellation()
        let result = try model.prediction(from: MLDictionaryFeatureProvider(
            dictionary: inputs.mapValues { MLFeatureValue(multiArray:$0) }))
        try checkCancellation()
        return result
    }
    private func array(_ provider: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let result = provider.featureValue(for:name)?.multiArrayValue else { throw Failure.modelMismatch }
        return result
    }

    func transcribe(_ samples: [Float], language: String) throws -> String {
        try checkCancellation()
        guard language == "uk" || language == "en", samples.count >= 1600,
              samples.count <= Self.maximumSamples, samples.allSatisfy({ $0.isFinite }) else { throw Failure.invalidAudio }
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        if sqrt(energy) < 0.001 { return "" }
        let signal = try zeros([1,Self.maximumSamples])
        let length = try zeros([1],type:.int32)
        for i in samples.indices { signal[i] = NSNumber(value:samples[i]) }
        length[0] = NSNumber(value:samples.count)
        let mel = try predict(preprocessor,["audio_signal":signal,"audio_length":length])
        let encoded = try predict(encoder,["mel":try array(mel,"mel"),"mel_length":try array(mel,"mel_length")])
        let features = try array(encoded,"encoder")
        let frames = try array(encoded,"encoder_length")[0].intValue
        guard features.shape.count == 3, features.shape[1].intValue == 1024,
              frames > 0, frames <= features.shape[2].intValue else { throw Failure.modelMismatch }
        var h = try zeros([2,1,640]), c = try zeros([2,1,640])
        let target = try zeros([1,1],type:.int32), targetLength = try zeros([1],type:.int32)
        targetLength[0] = 1
        func decode(_ token: Int) throws -> MLMultiArray {
            target[0] = NSNumber(value:token)
            let result = try predict(decoder,["targets":target,"target_length":targetLength,"h_in":h,"c_in":c])
            h = try array(result,"h_out"); c = try array(result,"c_out")
            return try array(result,"decoder")
        }
        let blank = 8192
        var projection = try decode(blank)
        let step = try zeros([1,1024,1])
        var time = 0, loops = 0, lastTime = -1, emissions = 0
        var tokens = [String]()
        let allowed = Set(vocabulary.compactMap { key,value in
            Self.alphabetAllows(value,language:language) ? Int(key) : nil
        })
        while time < frames {
            loops += 1
            guard loops < 2000 else { throw Failure.decoderLimit }
            for k in 0..<1024 { step[k] = features[[NSNumber(value:0),NSNumber(value:k),NSNumber(value:time)]] }
            let result = try predict(joint,["encoder_step":step,"decoder_step":projection])
            var token = try array(result,"token_id")[0].intValue
            var duration = try array(result,"duration")[0].intValue
            if token != blank && !allowed.contains(token) {
                let ids = try array(result,"top_k_ids"), logits = try array(result,"top_k_logits")
                guard ids.count == logits.count else { throw Failure.modelMismatch }
                var best = -Float.infinity
                token = blank
                for i in 0..<ids.count {
                    let id = ids[i].intValue
                    if (id == blank || allowed.contains(id)) && logits[i].floatValue > best {
                        token = id; best = logits[i].floatValue
                    }
                }
            }
            guard (0...4).contains(duration) else { throw Failure.modelMismatch }
            if token != blank {
                guard let text = vocabulary[String(token)] else { throw Failure.modelMismatch }
                tokens.append(text)
                projection = try decode(token)
                emissions = time == lastTime ? emissions + 1 : 1
                lastTime = time
                if duration == 0 && emissions >= 2 { duration = 1 }
            } else if duration == 0 { duration = 1 }
            time += duration
        }
        try checkCancellation()
        return tokens.joined().replacingOccurrences(of:"▁",with:" ").trimmingCharacters(in:.whitespacesAndNewlines)
    }
}
