import Foundation
import AVFoundation
@main struct Verify {
 static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw AppFailure(message:message) }
 }
 static func main() async throws {
  let cues = [PlaybackCue(id:"a",begin:1,end:3),PlaybackCue(id:"b",begin:3,end:5),PlaybackCue(id:"overlap",begin:4,end:6)]
  try require(PlaybackTimeline.active(cues,at:0).isEmpty,"句前静音不应高亮")
  try require(PlaybackTimeline.active(cues,at:3) == ["b"],"句子交界不得同时高亮前句")
  try require(PlaybackTimeline.active(cues,at:4.5) == ["b","overlap"],"重叠发言应保留两句高亮")
  try require(PlaybackTimeline.active(cues,at:6).isEmpty,"句后静音不得延续高亮")
  try require(PlaybackTimeline.active(cues,at:1.2) == ["a"],"向前拖动应重新定位")
  try require(PlaybackTimeline.active(cues,at:.nan).isEmpty,"无效进度应安全忽略")
  try require(PlaybackTimeline.anchor(cues,at:7) == "overlap","静音时恢复跟随应定位最近一句")
  print("PASS 播放定位：静音、边界、重叠、回退与无效进度")
  try require(MinutesService.cleanTitle("  页面设计与人才培养内容整合  ") == "页面设计与人才培养内容整合","会议标题清理失败")
  for bad in ["", "第一行\n第二行", "# 不合法", String(repeating:"字",count:61)] { try require(MinutesService.cleanTitle(bad) == nil,"无效标题不应覆盖旧名") }
  let oldMinutes = try JSONDecoder().decode(MinuteResponse.self,from:Data("{\"items\":[]}".utf8))
  try require(oldMinutes.title == nil,"旧纪要响应兼容失败")
  print("PASS 自动标题验证与旧响应兼容")
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-verification-" + UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:root) }
  var job = BatchJob(template:MinutesTemplate.builtins[0],pending:["one","two"])
  job.failures["three"] = "模拟网络失败"
  try job.save(root:root)
  let reopenedJob = try BatchJob.load(root:root)
  try require(reopenedJob?.pending == ["one","two"] && reopenedJob?.failures["three"] != nil,"批量断点与失败状态恢复失败")
  var committed = Meeting(title:"批量提交验证"); committed.summaryBatchID = job.id
  do { let isolated = try Store(root:root.appendingPathComponent("batch")); try isolated.save(committed) }
  let reopenedStore = try Store(root:root.appendingPathComponent("batch"))
  let savedBatchMeeting = try reopenedStore.list().first
  try require(savedBatchMeeting?.summaryBatchID == job.id,"完成标记必须与会议一起持久化")
  job.pending.removeFirst(); job.completed.append("one"); try job.save(root:root)
  let savedJob = try BatchJob.load(root:root)
  try require(savedJob?.completed == ["one"],"成功任务断点丢失")
  job.failures["two"] = "重复失败ID"; job.retryFailures()
  try require(job.pending == ["two","three"] && job.failures.isEmpty && job.completed == ["one"],"重试仅应加入失败项，不能重跑成功项或重复入队")
  try job.save(root:root)
  let retryJob = try BatchJob.load(root:root)
  try require(retryJob?.pending == ["two","three"],"失败重试队列未持久化")
  print("PASS 批量任务重开、待办与失败恢复、原子完成标记")
  var meeting = Meeting(title:"产品评审"); meeting.notes = "负责人未明确"; meeting.status = "录音中"
  do { let store = try Store(root:root); try store.save(meeting); meeting.notes += "；补充记录"; try store.save(meeting) }
  let store = try Store(root:root)
  let rows = try store.list(query:"负责人")
  try require(rows.count == 1,"搜索或持久化失败")
  try require(rows[0].status == "异常中断 · 已保留录音","恢复状态失败")
  try require(rows[0].notes.contains("补充记录"),"更新内容丢失")
  let missing = try store.list(query:"不存在")
  try require(missing.isEmpty,"空搜索结果失败")
  print("PASS SQLite 保存、更新、中文搜索、重开与中断恢复")
  let plaudRoot = root.appendingPathComponent("plaud-fixture")
  let source = plaudRoot.appendingPathComponent("one")
  try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
  try Data(#"{"plaud_file":{"id":"test-plaud-id","name":"Plaud同步唯一测试","created_at":"2026-10-12 10:00:00"},"duration_ms":12000}"#.utf8).write(to:source.appendingPathComponent("meta.json"))
  try Data("# 测试纪要\n不能把这段AI总结当问答证据".utf8).write(to:source.appendingPathComponent("summary.md"))
  try Data(#"{"transcripts":[{"sentences":[{"text":"我们决定周五演示同步功能。","begin_time":1000,"end_time":4000,"speaker_id":0}]}]}"#.utf8).write(to:source.appendingPathComponent("asr.json"))
  let ps = try Store(root:root.appendingPathComponent("plaud-db"))
  let firstImport = try PlaudImport.sync(directory:plaudRoot,store:ps)
  var imported = try ps.list()[0]; imported.notes = "用户编辑保留"; try ps.save(imported)
  let secondImport = try PlaudImport.sync(directory:plaudRoot,store:ps)
  let persisted = try ps.list()
  try require(firstImport.added == 1 && secondImport.added == 0 && secondImport.skipped == 1 && persisted.count == 1 && persisted[0].notes == "用户编辑保留","Plaud重复同步去重/保留编辑失败")
  let importedHits = try ps.search("演示同步")
  try require(importedHits.count == 1 && importedHits[0].meeting.id == imported.id,"Plaud全文索引失败")
  let plaudSources = QAEvidence.sources(meeting:imported,realtime:[])
  try require(plaudSources.contains(where:{$0.kind == "final" && $0.target == "S1" && $0.time == 1}) && !plaudSources.contains(where:{$0.text.contains("AI总结")}),"Plaud问答证据/时间点错误")
  let reopenedPlaud = try Store(root:root.appendingPathComponent("plaud-db"))
  let reopenedPlaudRows = try reopenedPlaud.list()
  try require(reopenedPlaudRows.count == 1,"Plaud重启恢复失败")
  print("PASS Plaud导入/重复去重/保留编辑/全文搜索/原文时间点/纪要排除/重启")
  let deletionRoot = root.appendingPathComponent("deletion")
  let deletionStore = try Store(root:deletionRoot)
  let disposable = Meeting(title:"删除验证唯一词")
  let survivor = Meeting(title:"保留的会议")
  try deletionStore.save(disposable); try deletionStore.save(survivor)
  try deletionStore.saveTranscript(Transcript(id:"delete-test",source:"system",begin:0,text:"待删除转写索引",final:true),meetingID:disposable.id)
  let audioFolder = try deletionStore.folder(disposable.id)
  try Data([1,2,3]).write(to:audioFolder.appendingPathComponent("test.caf"))
  try deletionStore.deleteMeeting(disposable.id)
  let remaining = try deletionStore.list()
  let deletedText = try deletionStore.transcripts(disposable.id)
  let deletedHits = try deletionStore.search("待删除")
  try require(remaining.map(\.id) == [survivor.id] && deletedText.isEmpty && deletedHits.isEmpty,"删除必须清理会议、转写、索引且保留其他会议")
  try require(!FileManager.default.fileExists(atPath:audioFolder.path),"删除必须清理本地录音")
  try deletionStore.deleteMeeting(disposable.id)
  let reopenedDeletion = try Store(root:deletionRoot)
  let reopenedRows = try reopenedDeletion.list()
  try require(reopenedRows.count == 1,"重启不应恢复已删除会议")
  do { try deletionStore.deleteMeeting("../invalid"); throw AppFailure(message:"不应允许无效删除路径") } catch let error as AppFailure { try require(error.message.contains("编号无效"),"删除路径校验失败") }
  let batchA = Meeting(title:"批量甲"); let batchB = Meeting(title:"批量乙")
  try deletionStore.save(batchA); try deletionStore.save(batchB)
  for item in [batchA,batchB] {
   let directory = try deletionStore.folder(item.id)
   try Data([4,5]).write(to:directory.appendingPathComponent("audio.caf"))
   try deletionStore.saveTranscript(Transcript(id:"batch",source:"microphone",begin:0,text:"批量转写正文",final:true),meetingID:item.id)
  }
  do { try deletionStore.deleteMeetings([batchA.id,"../bad"]); throw AppFailure(message:"批量非法路径未拒绝") } catch let error as AppFailure { try require(error.message.contains("编号无效"),"批量校验失败") }
  let unchanged = try deletionStore.list()
  try require(unchanged.count == 3,"批量校验失败不能部分删除")
  try deletionStore.deleteMeetings([batchA.id,batchB.id,batchA.id])
  let batchRemaining = try deletionStore.list(); let batchHits = try deletionStore.search("批量")
  try require(batchRemaining.map(\.id) == [survivor.id] && batchHits.isEmpty,"批量删除范围或索引错误")
  for item in [batchA,batchB] { try require(!FileManager.default.fileExists(atPath:deletionRoot.appendingPathComponent("Recordings").appendingPathComponent(item.id).path),"批量录音未删除") }
  print("PASS 删除会议、转写、全文索引与录音；保留其他会议、幂等重试、重开与路径校验")
  let templateSuite = "meeting-template-test-" + UUID().uuidString
  let templateDefaults = UserDefaults(suiteName:templateSuite)!
  defer { templateDefaults.removePersistentDomain(forName:templateSuite) }
  try require(MinutesTemplate.selected(templateDefaults).id == "general","模板默认值错误")
  let customTemplate = MinutesTemplate(id:UUID().uuidString,name:"验收模板",instructions:"优先列出阻碍，使用简洁语句。")
  try MinutesTemplate.save(customTemplate,defaults:templateDefaults)
  try require(MinutesTemplate.selected(templateDefaults) == customTemplate,"自定义模板选用或持久化失败")
  var changedTemplate = customTemplate; changedTemplate.instructions = "按主题详细整理。"
  try MinutesTemplate.save(changedTemplate,defaults:templateDefaults)
  try require(MinutesTemplate.all(templateDefaults).count == 4 && MinutesTemplate.selected(templateDefaults) == changedTemplate,"模板编辑产生重复")
  templateDefaults.set("missing",forKey:"minutesTemplateID")
  try require(MinutesTemplate.selected(templateDefaults).id == "general","丢失模板未回退")
  try MinutesTemplate.save(changedTemplate,defaults:templateDefaults)
  try MinutesTemplate.delete(changedTemplate.id,defaults:templateDefaults)
  try require(MinutesTemplate.all(templateDefaults).count == 3 && MinutesTemplate.selected(templateDefaults).id == "general","模板删除或选中回退失败")
  var builtinRejected = false
  do { try MinutesTemplate.delete("general",defaults:templateDefaults) } catch { builtinRejected = true }
  try require(builtinRejected && MinutesTemplate.all(templateDefaults).count == 3,"错误允许删除内置模板")
  print("PASS 模板默认/新增/编辑/选择/持久化/回退")
  let taskID = "test-task"
  func event(_ text: String, final: Bool, end: Any = NSNull()) throws -> Transcript {
   let body: [String:Any] = ["header":["event":"result-generated","task_id":taskID],"payload":["output":["sentence":["sentence_id":1,"begin_time":500,"end_time":end,"text":text,"sentence_end":final]]]]
   return try ASREvent.parse(JSONSerialization.data(withJSONObject:body),task:taskID,source:"system",offset:2).sentence!
  }
  var items: [Transcript] = []
  let a = try event("今天",final:false)
  let b = try event("今天讨论",final:false)
  let c = try event("今天讨论三个问题。",final:true,end:2000)
  for item in [a,b,c,c,a] { TranscriptReducer.merge(item,into:&items) }
  try require(items.count == 1 && items[0].text == c.text && items[0].final,"临时/最终结果去重失败")
  try require(items[0].begin == 2.5 && items[0].end == 4,"会议时间偏移错误")
  try store.saveTranscript(items[0],meetingID:meeting.id)
  let loaded = try store.transcripts(meeting.id)
  try require(loaded.contains(c),"转写持久化失败")
  let matches = try store.list(query:"三个问题")
  try require(matches.count == 1,"转写正文搜索失败")
  let heartbeat: [String:Any] = ["header":["event":"result-generated","task_id":taskID],"payload":["output":["sentence":["heartbeat":true]]]]
  let ignored = try ASREvent.parse(JSONSerialization.data(withJSONObject:heartbeat),task:taskID,source:"system",offset:0)
  try require(ignored.sentence == nil,"心跳不能追加文字")
  let wrongTask = try ASREvent.parse(JSONSerialization.data(withJSONObject:heartbeat),task:"different",source:"system",offset:0)
  try require(wrongTask.sentence == nil,"串任务结果未过滤")
  let connection = ASRConnection(source:"test")
  await connection.fail("模拟断线")
  await connection.finish()
  let failed = await connection.state
  try require(failed == .failed,"失败状态被收尾误判为完成")
  print("PASS ASR 临时替换、最终幂等、迟到临时稿、时间点、心跳过滤、失败状态与转写持久化")
  for rate in [44100.0,48000.0] {
   let f = AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
   let encoder = PCMEncoder(); var pcm = Data()
   for _ in 0..<10 {
    let count = AVAudioFrameCount(rate/10)
    let b = AVAudioPCMBuffer(pcmFormat:f,frameCapacity:count)!; b.frameLength = count
    for i in 0..<Int(count) { b.floatChannelData![0][i] = 1.8; b.floatChannelData![1][i] = 1.8 }
    pcm.append(try encoder.convert(b))
   }
   pcm.append(try encoder.flush())
   try require(abs(pcm.count/2-16000) <= 16,"重采样时长错误：\(rate) → \(pcm.count/2)")
   let values = pcm.withUnsafeBytes { Array($0.bindMemory(to:Int16.self)) }
   try require(values[1000] >= 32000,"PCM16 限幅或混音错误")
  }
  let extremes: [Float] = [-2,-1,0,1,2,.nan,.infinity]
  let encoded = extremes.withUnsafeBufferPointer { PCMEncoder.encode($0.baseAddress!,count:$0.count) }
  let clipped = encoded.withUnsafeBytes { Array($0.bindMemory(to:Int16.self)) }
  try require(clipped == [-32768,-32768,0,32767,32767,0,0],"负峰值/非有限值限幅失败")
  let stereo = AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
  let rightOnly = AVAudioPCMBuffer(pcmFormat:stereo,frameCapacity:4800)!; rightOnly.frameLength = 4800
  for i in 0..<4800 { rightOnly.floatChannelData![0][i] = 0; rightOnly.floatChannelData![1][i] = 0.5 }
  let downmix = try PCMEncoder().convert(rightOnly)
  let mono = downmix.withUnsafeBytes { Array($0.bindMemory(to:Int16.self)) }
  try require(mono[1000] > 4000,"右声道在混音时丢失")
  let ingress = AudioIngress()
  for _ in 0..<100 { try require(ingress.yield(AudioPacket(data:Data(repeating:0,count:3200),offset:0)),"队列过早溢出") }
  try require(!ingress.yield(AudioPacket(data:Data(repeating:0,count:3200),offset:0)),"队列没有限制内存")
  ingress.finish()
  print("PASS 44.1/48 kHz 双声道 → 16 kHz 单声道 PCM16、限幅、尾帧和有界队列")
  let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
  let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800)!
  buffer.frameLength = 4800
  for i in 0..<4800 { buffer.floatChannelData![0][i] = Float(sin(Double(i)*2 * .pi * 440 / 48000))*0.25 }
  guard let copy = AudioWriter.copy(buffer) else { throw AppFailure(message:"复制失败") }
  buffer.floatChannelData![0][100] = 0
  try require(copy.floatChannelData![0][100] != 0,"音频内存未独立")
  let writer = AudioWriter(); writer.begin(folder:root)
  for source in ["system","microphone"] { writer.append(copy,source:source) }
  await writer.finish()
  for source in ["system","microphone"] {
   let file = try AVAudioFile(forReading:root.appendingPathComponent("\(source)-1.caf"))
   try require(file.length == 4800,"帧数错误")
   let decoded = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:4800)!
   try file.read(into:decoded)
   try require(abs(decoded.floatChannelData![0][100]-copy.floatChannelData![0][100]) < 0.0001,"音频读回不一致")
  }
  print("PASS 合成音频双路落盘、关闭、解码与采样值校验（不是实际设备录音）")
  // Delayed second source must not be collapsed to time zero during offline mixing.
  let mixRoot = root.appendingPathComponent("mix-test")
  try FileManager.default.createDirectory(at:mixRoot,withIntermediateDirectories:true)
  let mixWriter = AudioWriter(); mixWriter.begin(folder:mixRoot,origin:100)
  mixWriter.append(copy,source:"system",hostSeconds:100)
  mixWriter.append(copy,source:"microphone",hostSeconds:101)
  await mixWriter.finish()
  let mixed = try MeetingMix.make(folder:mixRoot)
  let mixFile = try AVAudioFile(forReading:mixed.url)
  try require(mixFile.processingFormat.channelCount == 1 && mixFile.processingFormat.sampleRate == 16000,"混音格式错误")
  try require(abs(mixed.seconds-1.1)<0.005,"混音丢失起始偏移")
  mixFile.framePosition = 8000
  let silence = AVAudioPCMBuffer(pcmFormat:mixFile.processingFormat,frameCapacity:100)!
  try mixFile.read(into:silence)
  try require((0..<Int(silence.frameLength)).allSatisfy{abs(silence.floatChannelData![0][$0])<0.0001},"间隙未补静音")
  let secondMix = try MeetingMix.make(folder:mixRoot)
  try require(abs(secondMix.seconds-mixed.seconds)<0.001,"重试混音失败")
  let importedMixRoot = root.appendingPathComponent("imported-mix")
  try FileManager.default.createDirectory(at:importedMixRoot,withIntermediateDirectories:true)
  let importedMix = try MeetingMix.make(folder:importedMixRoot,imported:mixed.url)
  try require(abs(importedMix.seconds-mixed.seconds)<0.005 && importedMix.warning.contains("Plaud"),"导入音频转换失败")
  if let path = ProcessInfo.processInfo.environment["PLAUD_VERIFY_AUDIO"] {
   let actual = try MeetingMix.make(folder:importedMixRoot,imported:URL(fileURLWithPath:path))
   let file = try AVAudioFile(forReading:actual.url)
   try require(actual.seconds > 1 && file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 16000,"真实Plaud录音单声道转换失败")
   print("PASS 实际下载Plaud录音 → 16k单声道WAV，秒数 \(actual.seconds)")
  }
  let fakeResult: [String:Any] = ["transcripts":[["sentences":[["begin_time":1000,"end_time":2100,"speaker_id":0,"text":"确认先做测试。"],["begin_time":2300,"end_time":3300,"speaker_id":1,"text":"期限还未明确。"]]]]]
  let finalRows = try OfflineASR.parse(JSONSerialization.data(withJSONObject:fakeResult))
  try require(finalRows.count == 2 && finalRows[1].speaker == 1 && finalRows[0].begin == 1,"句子时间点或说话人解析错误")
  meeting.post = PostRecord(); meeting.post?.sentences = finalRows; meeting.post?.speakerNames["0"] = "主持人"; meeting.post?.minutes = "测试纪要"; meeting.post?.taskID = "resumable-task"
  try store.save(meeting)
  let restored = try Store(root:root).list().first(where:{$0.id == meeting.id})!
  try require(restored.post?.speakerNames["0"] == "主持人" && restored.post?.sentences == finalRows && restored.post?.taskID == "resumable-task","会后结果或任务恢复失败")
  let long = String(repeating:"中文内容",count:8000)
  let chunks = MinutesService.chunks([EvidenceLine(id:"S1",text:long)])
  try require(chunks.count>1 && chunks.flatMap{$0}.map(\.text).joined() == long,"长文本被截断")
  let evidence = [EvidenceLine(id:"S1",text:"确认安排测试，期限未明确")]
  let validated = try MinutesService.validate(MinuteResponse(items:[MinuteItem(kind:"action",text:"安排测试",refs:["S1"],owner:"张三",deadline:"周五")]),evidence:evidence)
  try require(validated[0].owner == "未明确" && validated[0].deadline == "未明确","无依据负责人或期限未阻止")
  try require(validated[0].kind == "summary","讨论被升级为已确认行动")
  let explicit = [EvidenceLine(id:"S2",text:"我们决定采用方案甲。由小王负责验证，周五完成。")]
  let acceptedDecision = try MinutesService.validate(MinuteResponse(items:[MinuteItem(kind:"decision",text:"采用方案甲",refs:["S2"],commitment:"决定采用方案甲"),MinuteItem(kind:"action",text:"验证",refs:["S2"],owner:"小王",deadline:"周五",commitment:"由小王负责验证")]),evidence:explicit)
  try require(acceptedDecision[0].kind == "decision" && acceptedDecision[1].kind == "action" && acceptedDecision[1].owner == "小王","明确承诺被丢失")
  let negated = try MinutesService.validate(MinuteResponse(items:[MinuteItem(kind:"decision",text:"采用方案乙",refs:["S3"],commitment:"没有决定采用方案乙")]),evidence:[EvidenceLine(id:"S3",text:"没有决定采用方案乙")])
  try require(negated[0].kind == "summary","否定决定被误判")
  var rejected = false
  do { _ = try MinutesService.validate(MinuteResponse(items:[MinuteItem(kind:"decision",text:"测试",refs:["missing"])]),evidence:evidence) } catch { rejected = true }
  try require(rejected,"伪造引用未拒绝")
  print("PASS 会后混音/偏移/静音间隙/重试、说话人时间点解析、任务与改名持久化、长文本无截断、引用及负责人校验（合成验证）")

  // FTS indexes every evidence type; updates remove stale tokens in the same transaction.
  var library = Meeting(title:"图谱质量评审"); library.notes = "笔记专用词稀有企鹅"; library.post = PostRecord()
  library.post?.sentences = [FinalSentence(id:"S1",begin:4,end:8,speaker:0,text:"录音原文讨论预算尚未明确")]
  library.post?.minutes = "纪要专用词紫色水杉"
  try store.save(library)
  for term in ["质量评审","企鹅","紫色水杉","预算尚未"] { let found = try store.search(term); try require(found.contains(where:{$0.meeting.id == library.id}),"FTS多来源或短中文搜索失败："+term) }
  let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "yyyy-MM-dd"
  let dateHits = try store.search(dateFormatter.string(from:library.started)); try require(dateHits.contains(where:{$0.meeting.id == library.id}),"日期搜索失败")
  _ = try store.search("\" OR *"); _ = try store.search("%_\"")
  library.notes = "更新后笔记"; library.post?.sentences = []
  try store.save(library)
  let oldNotes = try store.search("稀有企鹅"); let oldFinal = try store.search("预算尚未")
  try require(oldNotes.isEmpty && oldFinal.isEmpty,"旧全文索引没有移除")
  let reopenedSearch = try Store(root:root).search("紫色水杉"); try require(reopenedSearch.count == 1,"全文索引重启失败")
  var transient = Transcript(id:"index-update",source:"system",begin:0,end:2,text:"临时专用内容",final:false,gap:false)
  try store.saveTranscript(transient,meetingID:library.id)
  transient.text = "最终确认内容"; transient.final = true; try store.saveTranscript(transient,meetingID:library.id)
  let stale = try store.search("临时专用"); let fresh = try store.search("最终确认")
  try require(stale.isEmpty && fresh.count == 1,"临时全文结果未替换")
  let sources = QAEvidence.sources(meeting:library,realtime:[transient])
  try require(!sources.contains(where:{$0.text.contains("紫色水杉")}),"AI纪要错误地作为问答依据")
  let evidenceSource = sources.first(where:{$0.kind == "realtime"})!
  let refs = try QAEvidence.checked(QASelection(supported:true,quotes:[QAQuote(id:evidenceSource.id,quote:"最终确认内容")]),sources:sources)
  try require(refs.count == 1 && refs[0].source.target == transient.id,"原文引用无法定位")
  for bad in [QAQuote(id:"another-meeting",quote:"最终确认内容"),QAQuote(id:evidenceSource.id,quote:"预算已批准一百万元")] {
   var refused = false; do { _ = try QAEvidence.checked(QASelection(supported:true,quotes:[bad]),sources:sources) } catch { refused = true }
   try require(refused,"虚构或跨会议引用未拒绝")
  }
  let unknown = try QAEvidence.checked(QASelection(supported:false,quotes:[]),sources:sources)
  try require(unknown.isEmpty,"无依据回答没有拒答")
  let digest = QAEvidence.digest(sources); library.notes += "发生变化"
  try require(digest != QAEvidence.digest(QAEvidence.sources(meeting:library,realtime:[transient])),"问答版本变化未检测")
  library.questions = [QAEntry(question:"验证问题",status:"依据原文回答",references:refs,sourceDigest:digest,coverage:"测试",supported:true)]
  try store.save(library)
  let restoredQA = try Store(root:root).list().first(where:{$0.id == library.id})?.questions?.first
  try require(restoredQA?.references.first?.quote == "最终确认内容","问答或引用快照重启丢失")
  print("PASS FTS5中文/短词/日期/多来源/索引更新/恶意查询/重开；问答仅原文、引用逐字校验、跨会议拒绝、资料不足与版本快照")

 }
}
