import Foundation
import CoreML
import AVFoundation
func array(_ shape:[Int],_ type:MLMultiArrayDataType = .float32)throws->MLMultiArray {let a=try MLMultiArray(shape:shape.map(NSNumber.init),dataType:type);for i in 0..<a.count{a[i]=0};return a}
func predict(_ m:MLModel,_ d:[String:MLMultiArray])throws->MLFeatureProvider{try m.prediction(from:MLDictionaryFeatureProvider(dictionary:d.mapValues{MLFeatureValue(multiArray:$0)}))}
func value(_ p:MLFeatureProvider,_ name:String)->MLMultiArray{p.featureValue(for:name)!.multiArrayValue!}
let args=CommandLine.arguments
let root=URL(fileURLWithPath:args[1]);let config=MLModelConfiguration();config.computeUnits = args.contains("--ane") ? .cpuAndNeuralEngine : .cpuOnly
let load=Date()
func model(_ name:String)throws->MLModel{try MLModel(contentsOf:root.appendingPathComponent(name+".mlmodelc"),configuration:config)}
let pre=try model("Preprocessor"),enc=try model("Encoder"),dec=try model("Decoder"),joint=try model("JointDecisionv3")
print("load_seconds=\(Date().timeIntervalSince(load))")
let vocab=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:root.appendingPathComponent("parakeet_v3_vocab.json")))
let audio=try AVAudioFile(forReading:URL(fileURLWithPath:args[2]))
guard audio.processingFormat.sampleRate==16000,audio.processingFormat.channelCount==1 else{fatalError("16k mono required")}
let buffer=AVAudioPCMBuffer(pcmFormat:audio.processingFormat,frameCapacity:AVAudioFrameCount(audio.length))!;try audio.read(into:buffer)
guard buffer.frameLength<=240000 else{fatalError("diagnostic clips <=15s only")}
for run in 1...3 {
let started=Date();let signal=try array([1,240000]),length=try array([1],.int32)
for i in 0..<Int(buffer.frameLength){signal[i]=NSNumber(value:buffer.floatChannelData![0][i])};length[0]=NSNumber(value:buffer.frameLength)
let mel=try predict(pre,["audio_signal":signal,"audio_length":length]);let encoded=try predict(enc,["mel":value(mel,"mel"),"mel_length":value(mel,"mel_length")])
let features=value(encoded,"encoder"),frames=value(encoded,"encoder_length")[0].intValue
var h=try array([2,1,640]),c=try array([2,1,640]);let target=try array([1,1],.int32),targetLen=try array([1],.int32);targetLen[0]=1
func decoder(_ token:Int)throws->MLMultiArray{target[0]=NSNumber(value:token);let r=try predict(dec,["targets":target,"target_length":targetLen,"h_in":h,"c_in":c]);h=value(r,"h_out");c=value(r,"c_out");return value(r,"decoder")}
var projection=try decoder(8192);let step=try array([1,1024,1]);var t=0,loops=0,lastTime = -1,emissions=0,tokens=[String]()
while t<frames && loops<2000 {
loops+=1
for k in 0..<1024{step[k]=features[[0,k,t].map(NSNumber.init)]}
let r=try predict(joint,["encoder_step":step,"decoder_step":projection]);var token=value(r,"token_id")[0].intValue;var duration=value(r,"duration")[0].intValue
// Ukrainian alphabet constraint, explicitly selected; no language autodetection.
func allowed(_ id:Int)->Bool{guard let text=vocab[String(id)] else{return false};return text.unicodeScalars.allSatisfy{!CharacterSet.letters.contains($0) || "АБВГҐДЕЄЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЬЮЯабвгґдеєжзиіїйклмнопрстуфхцчшщьюя".unicodeScalars.contains($0)}}
if token != 8192 && !allowed(token){let ids=value(r,"top_k_ids"),logits=value(r,"top_k_logits");var best = -Float.infinity;token=8192;for i in 0..<ids.count{let id=ids[i].intValue;if (id==8192 || allowed(id)) && logits[i].floatValue>best{token=id;best=logits[i].floatValue}}}
if token != 8192 {tokens.append(vocab[String(token)] ?? "");projection=try decoder(token);if t==lastTime{emissions+=1}else{lastTime=t;emissions=1};if duration==0 && emissions>=2{duration=1}}else if duration==0{duration=1}
t+=duration
}
let text=tokens.joined().replacingOccurrences(of:"▁",with:" ").trimmingCharacters(in:.whitespaces)
print("run=\(run) seconds=\(Date().timeIntervalSince(started)) frames=\(frames) iterations=\(loops) text=\(text)")
}
