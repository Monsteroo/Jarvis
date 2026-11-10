import Foundation
import AVFoundation

@main struct Benchmark {
 static func main() {
    do { try run() } catch {
        fputs("Benchmark failed: \(error)\n",stderr)
        exit(1)
    }
 }
 static func run() throws {
    guard CommandLine.arguments.count >= 3 else {
        fputs("Usage: jarvis-benchmark MODEL_OR_PARAKEET_FOLDER WAV [language=uk] [runs=3]\nInput: mono 16kHz WAV; <=15s Parakeet, <=30s Whisper.\n", stderr); exit(2)
    }
    let args=CommandLine.arguments
    let file=try AVAudioFile(forReading: URL(fileURLWithPath:args[2]))
    guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
          file.length >= 1600, file.length <= 480000,
          let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)) else {
        fputs("Expected mono 16kHz input between 0.1 and 30 seconds.\n",stderr); exit(2)
    }
    try file.read(into:buffer)
    guard let samples=buffer.floatChannelData?[0] else { exit(2) }
    let start=ProcessInfo.processInfo.systemUptime
    let isParakeet = !args[1].hasSuffix(".bin")
    let parakeet = isParakeet ? try ParakeetASR(root:URL(fileURLWithPath:args[1])) : nil
    let ctx = isParakeet ? nil : jv_create(args[1])
    guard ctx != nil || parakeet != nil else { fputs("Cannot load model\n",stderr); exit(1) }
    defer { if let ctx { jv_free(ctx) } }
    let loadMS=(ProcessInfo.processInfo.systemUptime-start)*1000
    let language=args.count>3 ? args[3] : "uk"
    let runs=args.count>4 ? min(50,max(1,Int(args[4]) ?? 3)) : 3
    for i in 0..<runs {
        var out=[CChar](repeating:0,count:16384)
        let t=ProcessInfo.processInfo.systemUptime
        let code: Int32
        let text: String
        if let parakeet {
            text = try parakeet.transcribe(Array(UnsafeBufferPointer(start:samples,count:Int(buffer.frameLength))),language:language)
            code = text.isEmpty ? 1 : 0
        } else {
            code = jv_transcribe(ctx,samples,Int32(buffer.frameLength),language,&out,Int32(out.count))
            text = String(cString:out)
        }
        let ms=(ProcessInfo.processInfo.systemUptime-t)*1000
        let row:[String:Any] = ["run":i+1,"model":URL(fileURLWithPath:args[1]).lastPathComponent,"audio_seconds":Double(buffer.frameLength)/16000,"language":language,"model_load_ms":loadMS,"inference_ms":ms,"status":Int(code),"text":text,"measurement":"file inference; not speech-end-to-action"]
        let json=try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])
        print(String(decoding:json,as:UTF8.self))
        if code < 0 { exit(1) }
    }
 }
}
