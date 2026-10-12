import Foundation
import AVFoundation

struct AudioSegment: Codable {
 var file: String
 var start: Double
}
struct MixResult { var url: URL; var warning: String; var seconds: Double }
enum MeetingMix {
 // Files are resampled sequentially to disk; the mixing buffer is bounded to one second.
 static func make(folder: URL, imported: URL? = nil) throws -> MixResult {
  let manager = FileManager.default
  let manifest = folder.appendingPathComponent("segments.json")
  let files = try imported.map { [$0] } ?? manager.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { $0.pathExtension == "caf" && ($0.lastPathComponent.hasPrefix("system-") || $0.lastPathComponent.hasPrefix("microphone-")) }
  guard !files.isEmpty else { throw AppFailure(message:"没有本地录音文件") }
  var warning = imported == nil ? "" : "Plaud 单路录音。"
  let segments: [AudioSegment]
  if let imported {
   segments = [AudioSegment(file:imported.lastPathComponent,start:0)]
  } else if manager.fileExists(atPath:manifest.path) {
   segments = try JSONDecoder().decode([AudioSegment].self,from:Data(contentsOf:manifest))
  } else {
   guard files.filter({$0.lastPathComponent.hasPrefix("system-")}).count <= 1, files.filter({$0.lastPathComponent.hasPrefix("microphone-")}).count <= 1 else { throw AppFailure(message:"旧版多段录音没有时间线，无法可靠混音；请使用新版重新录制") }
   segments = files.map { AudioSegment(file:$0.lastPathComponent,start:0) }
   warning = "旧版录音无起始偏移元数据，两路按文件起点对齐；时间点可能有小幅偏差。"
  }
  guard !segments.isEmpty else { throw AppFailure(message:"录音时间线为空") }
  if imported == nil && (!files.contains(where:{$0.lastPathComponent.hasPrefix("system-")}) || !files.contains(where:{$0.lastPathComponent.hasPrefix("microphone-")})) { warning += " 只有一路录音，另一音源内容可能缺失。" }
  let work = folder.appendingPathComponent("mix-"+UUID().uuidString,isDirectory:true)
  try manager.createDirectory(at:work,withIntermediateDirectories:true)
  defer { try? manager.removeItem(at:work) }
  var parts: [(URL,Int64,Int64)] = []
  var total: Int64 = 0
  for (index,segment) in segments.enumerated() {
   try Task.checkCancellation()
   guard !segment.file.contains("/"), files.contains(where:{$0.lastPathComponent == segment.file}), segment.start.isFinite, segment.start >= 0 else { throw AppFailure(message:"录音时间线包含无效文件或时间") }
   let file = try AVAudioFile(forReading:imported ?? folder.appendingPathComponent(segment.file))
   let duration = Double(file.length)/file.processingFormat.sampleRate
   guard duration > 0, segment.start + duration <= 7200 else { throw AppFailure(message:"说话人分离当前支持两小时以内的有效录音；原始录音仍完整保留") }
   let url = work.appendingPathComponent("\(index).pcm")
   manager.createFile(atPath:url.path,contents:nil)
   let handle = try FileHandle(forWritingTo:url)
   let encoder = PCMEncoder()
   var size: Int64 = 0
   do {
    let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:8192)!
    var consumed: AVAudioFramePosition = 0
    while consumed < file.length {
     try Task.checkCancellation(); try file.read(into:buffer,frameCount:AVAudioFrameCount(min(Int64(buffer.frameCapacity),file.length-consumed)))
     if buffer.frameLength == 0 { break }
     consumed += Int64(buffer.frameLength)
     let bytes = try encoder.convert(buffer); try handle.write(contentsOf:bytes); size += Int64(bytes.count)
    }
    let tail = try encoder.flush(); try handle.write(contentsOf:tail); size += Int64(tail.count)
    try handle.close()
   } catch { try? handle.close(); throw error }
   let start = Int64((segment.start*16000).rounded())
   parts.append((url,start,size/2)); total = max(total,start+size/2)
  }
  guard total > 0, total <= 7200*16000+32 else { throw AppFailure(message:"混音时长超出两小时支持范围") }
  let staged = work.appendingPathComponent("mixed.wav")
  manager.createFile(atPath:staged.path,contents:nil)
  let output = try FileHandle(forWritingTo:staged); defer { try? output.close() }
  try output.write(contentsOf:wavHeader(samples:UInt32(total)))
  let handles = try parts.map { try FileHandle(forReadingFrom:$0.0) }
  defer { handles.forEach { try? $0.close() } }
  var cursor: Int64 = 0
  while cursor < total {
   try Task.checkCancellation()
   let count = Int(min(16000,total-cursor)); var sums = [Int32](repeating:0,count:count)
   for (index,part) in parts.enumerated() {
    let left = max(cursor,part.1); let right = min(cursor+Int64(count),part.1+part.2)
    if right <= left { continue }
    try handles[index].seek(toOffset:UInt64((left-part.1)*2))
    let data = try handles[index].read(upToCount:Int((right-left)*2)) ?? Data()
    guard data.count == Int((right-left)*2) else { throw AppFailure(message:"录音读取不完整") }
    data.withUnsafeBytes { raw in
     for j in 0..<data.count/2 { sums[Int(left-cursor)+j] += Int32(Int16(littleEndian:raw.loadUnaligned(fromByteOffset:j*2,as:Int16.self))) }
    }
   }
   // Fixed 0.5 gain prevents clipping when two full-scale sources overlap; no echo removal.
   let pcm = sums.map { Int16(clamping:$0/2).littleEndian }
   try output.write(contentsOf:pcm.withUnsafeBytes { Data($0) }); cursor += Int64(count)
  }
  try output.close()
  let result = folder.appendingPathComponent("meeting-mono.wav")
  if manager.fileExists(atPath:result.path) { _ = try manager.replaceItemAt(result,withItemAt:staged) }
  else { try manager.moveItem(at:staged,to:result) }
  return MixResult(url:result,warning:warning,seconds:Double(total)/16000)
 }
 static func wavHeader(samples: UInt32) -> Data {
  var data = Data()
  func text(_ s: String) { data.append(Data(s.utf8)) }
  func u32(_ v: UInt32) { var n = v.littleEndian; withUnsafeBytes(of:&n) { data.append(contentsOf:$0) } }
  func u16(_ v: UInt16) { var n = v.littleEndian; withUnsafeBytes(of:&n) { data.append(contentsOf:$0) } }
  text("RIFF"); u32(36+samples*2); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16); text("data"); u32(samples*2)
  return data
 }
}
