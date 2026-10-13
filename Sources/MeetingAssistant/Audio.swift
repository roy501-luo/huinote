import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

struct AudioHealth {
 var frames: Int64 = 0
 var peak: Float = 0
 var lastReceived: Date?
 var error: String?
}
// All recording state is confined to queue; update is configured before capture starts.
final class AudioWriter: @unchecked Sendable {
 private let queue = DispatchQueue(label:"meeting.audio.disk")
 private var files: [String: AVAudioFile] = [:]
 private var formats: [String: AVAudioFormat] = [:]
 private var counts: [String:Int] = [:]
 private var health: [String:AudioHealth] = [:]
 private var folder: URL?
 private var enabled = false
 private var lastUpdate: [String:Double] = [:]
 var update: ((String,AudioHealth)->Void)?
 var onPCM: ((String,AudioPacket)->Void)?
 var onPCMError: ((String,String)->Void)?
 private var encoders: [String:PCMEncoder] = [:]
 private var pending: [String:Data] = [:]
 private var origins: [String:Double] = [:]
 private var sentBytes: [String:Int] = [:]
 private var expectedInput: [String:Double] = [:]
 private var encodingFailed = Set<String>()
 private var segments: [AudioSegment] = []
 private var diskExpected: [String:Double] = [:]
 private var meetingOrigin = ProcessInfo.processInfo.systemUptime

 func begin(folder: URL, origin: Double = ProcessInfo.processInfo.systemUptime) { queue.sync {
  self.folder = folder; files = [:]; formats = [:]; counts = [:]; health = [:]; lastUpdate = [:]; enabled = true
  segments = []; diskExpected = [:]
  encoders = [:]; pending = [:]; origins = [:]; sentBytes = [:]; expectedInput = [:]; encodingFailed = []; meetingOrigin = origin
 } }
 func append(_ buffer: AVAudioPCMBuffer, source: String, hostSeconds: Double? = nil) {
  let time = hostSeconds ?? (ProcessInfo.processInfo.systemUptime-Double(buffer.frameLength)/buffer.format.sampleRate)
  queue.async { [self] in
   guard enabled, let folder else { return }
   do {
    if files[source] == nil || formats[source] != buffer.format || diskExpected[source].map({abs(time-$0)>0.35}) == true {
     let index = (counts[source] ?? 0) + 1; counts[source] = index
     files[source] = try AVAudioFile(forWriting:folder.appendingPathComponent("\(source)-\(index).caf"),settings:buffer.format.settings,commonFormat:buffer.format.commonFormat,interleaved:buffer.format.isInterleaved)
     formats[source] = buffer.format
     segments.append(AudioSegment(file:"\(source)-\(index).caf",start:max(0,time-meetingOrigin)))
     try JSONEncoder().encode(segments).write(to:folder.appendingPathComponent("segments.json"),options:.atomic)
    }
    try files[source]!.write(from:buffer)
    diskExpected[source] = time+Double(buffer.frameLength)/buffer.format.sampleRate
    var value = health[source] ?? AudioHealth()
    value.frames += Int64(buffer.frameLength); value.lastReceived = Date(); value.error = nil
    if let channels = buffer.floatChannelData {
     var peak: Float = 0
     for channel in 0..<Int(buffer.format.channelCount) {
      for i in 0..<Int(buffer.frameLength) { peak = max(peak,abs(channels[channel][i])) }
     }
     value.peak = peak
    }
    health[source] = value
    let uptime = ProcessInfo.processInfo.systemUptime
    if uptime-lastUpdate[source,default:0] >= 0.25 {
     lastUpdate[source] = uptime; update?(source,value)
    }
    if onPCM != nil && !encodingFailed.contains(source) {
     do {
      if let expected = expectedInput[source], abs(time-expected) > 0.35 { throw AppFailure(message:"采集设备时间线中断；实时转写已停止，本地录音继续。") }
      expectedInput[source] = time + Double(buffer.frameLength)/buffer.format.sampleRate
      if encoders[source] == nil { encoders[source] = PCMEncoder(); origins[source] = max(0,time-meetingOrigin) }
      let data = try encoders[source]!.convert(buffer)
      emit(data,source:source)
     } catch { encodingFailed.insert(source); onPCMError?(source,error.localizedDescription) }
    }
   } catch { fail(source, error.localizedDescription) }
  }
 }
 func fail(_ source: String, _ message: String) {
  // Called on the writer queue, or forwarded through report().
  var value = health[source] ?? AudioHealth(); value.error = message
  health[source] = value; update?(source,value)
 }
 func report(_ source: String, _ message: String) { queue.async { self.fail(source,message) } }
 private func emit(_ data: Data, source: String, flush: Bool = false) {
  pending[source,default:Data()].append(data)
  while let buffer = pending[source], buffer.count >= 3200 || (flush && !buffer.isEmpty) {
   let count = min(3200,buffer.count)
   let packet = AudioPacket(data:Data(buffer.prefix(count)),offset:(origins[source] ?? 0)+Double(sentBytes[source,default:0])/32000)
   pending[source]?.removeFirst(count); sentBytes[source,default:0] += count
   onPCM?(source,packet)
  }
 }
 func finish() async { await withCheckedContinuation { continuation in queue.async {
  for (source,encoder) in self.encoders where !self.encodingFailed.contains(source) {
   do { self.emit(try encoder.flush(),source:source,flush:true) }
   catch { self.onPCMError?(source,error.localizedDescription) }
  }
  for (source,value) in self.health { self.update?(source,value) }
  self.enabled = false; self.files = [:]; continuation.resume()
 } } }
 static func copy(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
  guard let output = AVAudioPCMBuffer(pcmFormat: input.format,frameCapacity:input.frameLength) else { return nil }
  output.frameLength = input.frameLength
  let src = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
  let dst = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
  for i in 0..<src.count {
   guard let a = src[i].mData, let b = dst[i].mData else { return nil }
   memcpy(b,a,Int(src[i].mDataByteSize))
  }
  return output
 }
}
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
 let writer = AudioWriter()
 private var engine: AVAudioEngine?
 private var stream: SCStream?
 private let captureQueue = DispatchQueue(label:"meeting.system.audio")
 func start(folder: URL, origin: Double = ProcessInfo.processInfo.systemUptime) async throws {
  guard await AVCaptureDevice.requestAccess(for:.audio) else { throw AppFailure(message:"麦克风权限被拒绝。请在系统设置 → 隐私与安全性 → 麦克风中允许 HuiNote · 会记。") }
  let content: SCShareableContent
  do { content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true) }
  catch { throw AppFailure(message:"无法获取系统音频采集权限：\(error.localizedDescription)。请检查系统设置 → 隐私与安全性 → 屏幕与系统音频录制。") }
  guard let display = content.displays.first else { throw AppFailure(message:"没有可用显示器，无法启动系统音频采集。") }
  writer.begin(folder:folder,origin:origin)
  do {
   let engine = AVAudioEngine()
   let input = engine.inputNode
   let format = input.outputFormat(forBus:0)
   guard format.sampleRate > 0, format.channelCount > 0 else { throw AppFailure(message:"麦克风设备不可用") }
   input.installTap(onBus:0,bufferSize:2048,format:format) { [weak self] buffer, time in
    guard let self else { return }
    guard let copy = AudioWriter.copy(buffer) else { self.writer.report("microphone","无法复制麦克风音频帧"); return }
    self.writer.append(copy,source:"microphone",hostSeconds:time.isHostTimeValid ? AVAudioTime.seconds(forHostTime:time.hostTime) : nil)
   }
   self.engine = engine
   try engine.start()
   let config = SCStreamConfiguration()
   config.capturesAudio = true; config.excludesCurrentProcessAudio = true
   config.sampleRate = 48000; config.channelCount = 2
   config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(seconds:1,preferredTimescale:1)
   let stream = SCStream(filter:SCContentFilter(display:display,excludingApplications:[],exceptingWindows:[]),configuration:config,delegate:self)
   try stream.addStreamOutput(self,type:.audio,sampleHandlerQueue:captureQueue)
   self.stream = stream
   try await stream.startCapture()
  } catch { await stop(); throw error }
 }
 func stop() async {
  engine?.inputNode.removeTap(onBus:0); engine?.stop(); engine = nil
  if let stream {
   do { try await stream.stopCapture() } catch { writer.report("system","停止系统采集失败：\(error.localizedDescription)") }
  }
  stream = nil
  await withCheckedContinuation { c in captureQueue.async { c.resume() } }
  await writer.finish()
 }
 func stream(_ stream: SCStream, didStopWithError error: Error) { writer.report("system","采集中断：\(error.localizedDescription)") }
 func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
  guard type == .audio, sampleBuffer.isValid,
   let description = sampleBuffer.formatDescription else { return }
  let format = AVAudioFormat(cmAudioFormatDescription:description)
  let count = CMSampleBufferGetNumSamples(sampleBuffer)
  guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(count)) else { return }
  pcm.frameLength = AVAudioFrameCount(count)
  let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer,at:0,frameCount:Int32(count),into:pcm.mutableAudioBufferList)
  guard status == noErr else { writer.report("system","系统音频格式转换失败（\(status)）"); return }
  writer.append(pcm,source:"system",hostSeconds:CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
 }
}
