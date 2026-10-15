import Foundation
import AVFoundation

enum MediaImport {
 static func read(_ source: URL, root: URL) async throws -> Meeting {
  let asset = AVURLAsset(url:source)
  guard !(try await asset.loadTracks(withMediaType:.audio)).isEmpty else { throw AppFailure(message:"文件中没有可用音轨") }
  let seconds = try await asset.load(.duration).seconds
  guard seconds.isFinite, seconds > 0 else { throw AppFailure(message:"无法读取有效音频时长") }
  var meeting = Meeting(title:source.deletingPathExtension().lastPathComponent)
  let folder = root.appendingPathComponent("Recordings").appendingPathComponent(meeting.id)
  let fm = FileManager.default
  try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  var completed = false
  defer { if !completed { try? fm.removeItem(at:folder) } }
  try await Task.detached { try FileManager.default.copyItem(at:source,to:folder.appendingPathComponent("original." + source.pathExtension)) }.value
  guard let export = AVAssetExportSession(asset:asset,presetName:AVAssetExportPresetAppleM4A) else { throw AppFailure(message:"此格式无法提取音轨") }
  export.outputURL = folder.appendingPathComponent("imported.m4a"); export.outputFileType = .m4a
  await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
   export.exportAsynchronously { continuation.resume() }
  }
  guard export.status == .completed else { throw AppFailure(message:export.error?.localizedDescription ?? "音轨导入失败") }
  meeting.duration = seconds; meeting.status = "媒体已导入 · 待生成转写"
  meeting.mediaFile = "Recordings/\(meeting.id)/imported.m4a"
  completed = true
  return meeting
 }
}
