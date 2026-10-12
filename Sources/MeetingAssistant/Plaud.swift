import Foundation
import CryptoKit
import AVFoundation

struct PlaudOrigin: Codable {
 var fileID: String
 var directory: String
 var importedAt = Date()
}
struct PlaudImportReport {
 var added = 0; var skipped = 0; var failed = 0
 var message: String { "新增 \(added) 场 · 已有 \(skipped) 场 · 未完成/无效 \(failed) 场" }
}
enum PlaudImport {
 static var defaultDirectory: String { NSHomeDirectory()+"/Desktop/Plaud纪要" }
 static var defaultTool: String { NSHomeDirectory()+"/Documents/amap_tour_guide_mcp_server/plaud_meeting_notes" }
 static func meetingID(_ source: String) -> String {
  let h = SHA256.hash(data:Data(("plaud:"+source).utf8)).prefix(16).map{String(format:"%02x",$0)}.joined()
  let a = Array(h)
  return [String(a[0..<8]),String(a[8..<12]),String(a[12..<16]),String(a[16..<20]),String(a[20..<32])].joined(separator:"-").uppercased()
 }
 static func read(_ directory: URL) throws -> Meeting {
  let meta = try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("meta.json"))) as? [String:Any] ?? [:]
  guard let file = meta["plaud_file"] as? [String:Any], let id = file["id"] as? String, !id.isEmpty,
        let name = file["name"] as? String else { throw AppFailure(message:"Plaud 元数据缺少文件编号或标题") }
  let date = DateFormatter(); date.locale = Locale(identifier:"en_US_POSIX"); date.timeZone = TimeZone(identifier:"Asia/Shanghai"); date.dateFormat = "yyyy-MM-dd HH:mm:ss"
  guard let started = date.date(from:file["created_at"] as? String ?? "") else { throw AppFailure(message:"Plaud 录制时间无效") }
  var meeting = Meeting(id:meetingID(id),title:name,started:started)
  meeting.plaud = PlaudOrigin(fileID:id,directory:directory.resolvingSymlinksInPath().path)
  meeting.duration = (meta["duration_ms"] as? Double ?? 0)/1000
  var post = PostRecord(); post.speakerNumberOffset = 0
  let summary = directory.appendingPathComponent("summary.md")
  if FileManager.default.fileExists(atPath:summary.path) { post.minutes = try String(contentsOf:summary,encoding:.utf8) }
  let asr = directory.appendingPathComponent("asr.json")
  if FileManager.default.fileExists(atPath:asr.path) {
   let data = try JSONSerialization.jsonObject(with:Data(contentsOf:asr)) as? [String:Any] ?? [:]
   for channel in data["transcripts"] as? [[String:Any]] ?? [] {
    for row in channel["sentences"] as? [[String:Any]] ?? [] {
     guard let text = row["text"] as? String, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
           let begin = row["begin_time"] as? Double, let end = row["end_time"] as? Double,
           begin.isFinite, end.isFinite, begin >= 0, end >= begin else { throw AppFailure(message:"Plaud 转写包含无效句子") }
     post.sentences.append(FinalSentence(id:"S\(post.sentences.count+1)",begin:begin/1000,end:end/1000,speaker:row["speaker_id"] as? Int,text:text))
    }
   }
   guard !post.sentences.isEmpty else { throw AppFailure(message:"Plaud 转写未包含带时间点句子") }
  }
  guard !post.minutes.isEmpty || audio(in:directory) != nil else { throw AppFailure(message:"Plaud 资料尚未生成完成") }
  if meeting.duration <= 0, let url = audio(in:directory), let audioFile = try? AVAudioFile(forReading:url) { meeting.duration = Double(audioFile.length)/audioFile.processingFormat.sampleRate }
  post.status = post.minutes.isEmpty ? "Plaud 录音已下载 · 待生成说话人稿与纪要" : "Plaud 纪要已导入 · 保留原稿"
  post.warning = "来自 Plaud 同步目录；原始文件保留。导入纪要未经会议助手重新生成或校验。"
  if post.sentences.isEmpty { post.warning += " 缺少带时间点的原文，暂不可基于纪要进行问答。" }
  post.minutesBasis = post.sentences.map { "\($0.id):[\($0.timeLabel)] \(post.name($0.speaker))：\($0.text)" }.joined(separator:"\n")
  meeting.post = post; meeting.status = "Plaud · " + (post.minutes.isEmpty ? "待处理录音" : "已导入")
  return meeting
 }
 static func audio(in folder: URL) -> URL? {
  ["audio.mono.mp3","audio.mp3","audio.wav","audio.m4a","audio.caf"].map{folder.appendingPathComponent($0)}.first{FileManager.default.fileExists(atPath:$0.path)}
 }
 static func sync(directory: URL, store: Store) throws -> PlaudImportReport {
  let folders = try FileManager.default.contentsOfDirectory(at:directory.resolvingSymlinksInPath(),includingPropertiesForKeys:nil).sorted{$0.path < $1.path}
  var known = Set(try store.list().compactMap{$0.plaud?.fileID}); var report = PlaudImportReport()
  for folder in folders where FileManager.default.fileExists(atPath:folder.appendingPathComponent("meta.json").path) {
   do {
    let meeting = try read(folder)
    guard let origin = meeting.plaud else { continue }
    if known.contains(origin.fileID) { report.skipped += 1; continue }
    try store.save(meeting); known.insert(origin.fileID); report.added += 1
   } catch { report.failed += 1 }
  }
  return report
 }
 static func download(tool: URL, destination: URL, known: [String], login: Bool = false) throws {
  guard let bridge = Bundle.main.url(forResource:"plaud_download",withExtension:"py") else { throw AppFailure(message:"Plaud 下载组件缺失，请重新构建") }
  let python = tool.appendingPathComponent(".venv/bin/python")
  guard FileManager.default.isExecutableFile(atPath:python.path) else { throw AppFailure(message:"找不到原 Plaud 工具的 Python 环境，请检查设置") }
  try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
  let exclusion = destination.appendingPathComponent(".imported.json")
  try JSONEncoder().encode(known).write(to:exclusion,options:.atomic)
  let p = Process(); p.executableURL = python; p.currentDirectoryURL = tool
  p.arguments = [bridge.path,tool.path,destination.path,exclusion.path] + (login ? ["login"] : [])
  p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
  var env = ProcessInfo.processInfo.environment; env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"; p.environment = env
  try p.run(); p.waitUntilExit()
  guard p.terminationStatus == 0 else { throw AppFailure(message:"Plaud 下载未全部完成（退出码 \(p.terminationStatus)）。请确认原工具登录态、网络及 ffmpeg；已下载资料保留，可重试。登录请使用下方“Plaud 登录”。") }
 }
}
