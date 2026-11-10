import Foundation
import AVFoundation

@main struct Benchmark {
 static func main() throws {
    guard CommandLine.arguments.count >= 3 else {
        fputs("Usage: jarvis-benchmark MODEL WAV [language=uk] [runs=3]\nInput: mono 16kHz WAV, <=30s.\n", stderr); exit(2)
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
    guard let ctx=jv_create(args[1]) else { fputs("Cannot load model\n",stderr); exit(1) }
    defer { jv_free(ctx) }
    let loadMS=(ProcessInfo.processInfo.systemUptime-start)*1000
    let language=args.count>3 ? args[3] : "uk"
    let runs=args.count>4 ? min(50,max(1,Int(args[4]) ?? 3)) : 3
    for i in 0..<runs {
        var out=[CChar](repeating:0,count:16384)
        let t=ProcessInfo.processInfo.systemUptime
        let code=jv_transcribe(ctx,samples,Int32(buffer.frameLength),language,&out,Int32(out.count))
        let ms=(ProcessInfo.processInfo.systemUptime-t)*1000
        let row:[String:Any] = ["run":i+1,"model":URL(fileURLWithPath:args[1]).lastPathComponent,"audio_seconds":Double(buffer.frameLength)/16000,"language":language,"model_load_ms":loadMS,"inference_ms":ms,"status":Int(code),"text":String(cString:out),"measurement":"file inference; not speech-end-to-action"]
        let json=try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])
        print(String(decoding:json,as:UTF8.self))
        if code < 0 { exit(1) }
    }
 }
}
