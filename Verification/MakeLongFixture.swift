import Foundation
import AVFoundation
@main struct MakeLongFixture {
 static func main() throws {
  let input = try AVAudioFile(forReading:URL(fileURLWithPath:CommandLine.arguments[1]))
  let output = try AVAudioFile(forWriting:URL(fileURLWithPath:CommandLine.arguments[2]),settings:input.processingFormat.settings)
  for _ in 0..<4 {
   input.framePosition = 0
   while input.framePosition < input.length {
    let buffer = AVAudioPCMBuffer(pcmFormat:input.processingFormat,frameCapacity:8192)!
    try input.read(into:buffer); try output.write(from:buffer)
   }
   let silence = AVAudioPCMBuffer(pcmFormat:input.processingFormat,frameCapacity:AVAudioFrameCount(input.processingFormat.sampleRate*2))!
   silence.frameLength = silence.frameCapacity
   for c in 0..<Int(silence.format.channelCount) { memset(silence.floatChannelData![c],0,Int(silence.frameLength)*4) }
   try output.write(from:silence)
  }
  print("Generated known test material: 4 repetitions with 2-second silence between segments")
 }
}
