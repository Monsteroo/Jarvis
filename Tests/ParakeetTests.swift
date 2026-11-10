import Foundation
import AVFoundation
@main struct ParakeetTests {
 static func check(_ condition: @autoclosure () -> Bool) { if !condition() { fatalError("Parakeet check failed") } }
 static func main() throws {
   check(ParakeetASR.alphabetAllows("▁Перемкнися", language:"uk"))
   check(ParakeetASR.alphabetAllows("▁Telegram", language:"uk"))
   check(!ParakeetASR.alphabetAllows("ы", language:"uk"))
   check(!ParakeetASR.alphabetAllows("ї", language:"en"))
   check(!ParakeetASR.alphabetAllows("hello", language:"auto"))
   check(ParakeetASR.alphabetAllows("30%", language:"en"))
   if CommandLine.arguments.count == 3 {
     let model=try ParakeetASR(root:URL(fileURLWithPath:CommandLine.arguments[1]))
     let file=try AVAudioFile(forReading:URL(fileURLWithPath:CommandLine.arguments[2]))
     let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!
     try file.read(into:buffer)
     let samples=Array(UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength)))
     let start=ProcessInfo.processInfo.systemUptime
     let text=try model.transcribe(samples,language:"uk")
     print("Parakeet regression:",text,"seconds:",ProcessInfo.processInfo.systemUptime-start)
     let normalized=text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
     check(normalized == "перемкнись на термінал" || normalized == "перемкнися на термінал")
     model.cancel()
     do { _ = try model.transcribe(samples,language:"uk"); fatalError("Cancellation must be sticky") } catch {}
     model.resetCancellation()
     do { _ = try model.transcribe([.nan],language:"uk"); fatalError("NaN must fail") } catch {}
   }
   print("ParakeetTests: passed")
 }
}
