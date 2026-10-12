import Foundation
import AVFoundation
@main struct InspectRecording {
 static func main() throws {
  guard CommandLine.arguments.count == 2 else { print("Usage: inspect-recording <folder>"); return }
  let folder = URL(fileURLWithPath:CommandLine.arguments[1])
  let files = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { $0.pathExtension == "caf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  for url in files {
   let file = try AVAudioFile(forReading:url)
   let format = file.processingFormat
   guard let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:8192) else { continue }
   var peak: Float = 0; var nonzero: Int64 = 0; var samples: Int64 = 0; var sum: Double = 0
   while file.framePosition < file.length {
    try file.read(into:buffer)
    guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
    for channel in 0..<Int(format.channelCount) {
     for i in 0..<Int(buffer.frameLength) {
      let value = channels[channel][i]; peak = max(peak,abs(value)); samples += 1
      if abs(value) > 0.0001 { nonzero += 1 }
      sum += Double(value)*Double(value)
     }
    }
   }
   print("\(url.lastPathComponent): seconds=\(Double(file.length)/format.sampleRate), channels=\(format.channelCount), sampleRate=\(format.sampleRate), peak=\(peak), rms=\(sqrt(sum/Double(max(1,samples)))), audibleSamples=\(nonzero), decodedFrames=\(file.framePosition)")
  }
 }
}
