import Foundation
import AVFoundation

// Confined to the audio writer queue; AVAudioConverter preserves resampling state across buffers.
final class PCMEncoder {
 private var converter: AVAudioConverter?
 private var inputFormat: AVAudioFormat?
 private let outputFormat = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
 func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
  if inputFormat != buffer.format {
   guard let converter = AVAudioConverter(from:buffer.format,to:outputFormat) else { throw AppFailure(message:"无法转换音频格式") }
   converter.primeMethod = .none
   converter.downmix = true
   self.converter = converter; inputFormat = buffer.format
  }
  let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength)*16000/buffer.format.sampleRate)+64)
  let output = AVAudioPCMBuffer(pcmFormat:outputFormat,frameCapacity:capacity)!
  var supplied = false
  var error: NSError?
  let status = converter!.convert(to:output,error:&error) { _, inputStatus in
   if supplied { inputStatus.pointee = .noDataNow; return nil }
   supplied = true; inputStatus.pointee = .haveData; return buffer
  }
  guard status != .error, error == nil else { throw AppFailure(message:"音频重采样失败") }
  return Self.encode(output.floatChannelData![0],count:Int(output.frameLength))
 }
 func flush() throws -> Data {
  guard let converter else { return Data() }
  var result = Data()
  for _ in 0..<8 {
   let output = AVAudioPCMBuffer(pcmFormat:outputFormat,frameCapacity:4096)!
   var error: NSError?
   let status = converter.convert(to:output,error:&error) { _, state in state.pointee = .endOfStream; return nil }
   guard status != .error, error == nil else { throw AppFailure(message:"音频尾帧转换失败") }
   result.append(Self.encode(output.floatChannelData![0],count:Int(output.frameLength)))
   if status == .endOfStream || output.frameLength == 0 { break }
  }
  return result
 }
 static func encode(_ samples: UnsafePointer<Float>,count: Int) -> Data {
  var values = [Int16](); values.reserveCapacity(count)
  for index in 0..<count {
   let sample = samples[index].isFinite ? samples[index] : 0
   let clipped = min(Float(1),max(Float(-1),sample))
   values.append(Int16((clipped < 0 ? clipped*32768 : clipped*32767).rounded()).littleEndian)
  }
  return values.withUnsafeBytes { Data($0) }
 }
}
