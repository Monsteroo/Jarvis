import Foundation
import CoreML
let root=URL(fileURLWithPath:CommandLine.arguments[1])
for name in ["Preprocessor.mlmodelc","Encoder.mlmodelc","Decoder.mlmodelc","JointDecisionv3.mlmodelc"] {
 let t=Date()
 do {let config=MLModelConfiguration();config.computeUnits = .cpuOnly
 let m=try MLModel(contentsOf:root.appendingPathComponent(name),configuration:config)
 print("\(name) load_seconds=\(Date().timeIntervalSince(t)) inputs=\(m.modelDescription.inputDescriptionsByName.keys.sorted()) outputs=\(m.modelDescription.outputDescriptionsByName.keys.sorted())")
 } catch {print("\(name) ERROR \(error)")}
}
