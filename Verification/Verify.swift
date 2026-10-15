import Foundation
import AVFoundation
@main struct Verify {
 static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw AppFailure(message:message) }
 }
 static func requireThrowing(_ condition: Bool, _ message: String) throws { try require(condition,message) }
 static func main() async throws {
  try await verifyLiveRecovery()
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
  let folderStore = try Store(root:root.appendingPathComponent("folders"))
  let fa = Meeting(title:"分类甲"), fb = Meeting(title:"分类乙")
  try folderStore.save(fa); try folderStore.save(fb)
  try folderStore.saveFolder(id:"f1",name:"项目")
  try folderStore.moveMeetings([fa.id,fb.id],to:"f1")
  try requireThrowing(try Store(root:folderStore.root).memberships().count == 2,"批量分类需重开保留")
  try folderStore.save(fa)
  try requireThrowing(try folderStore.memberships()[fa.id] == "f1","后台保存不得覆盖分类")
  try folderStore.saveFolder(id:"f1",name:"项目改名")
  do { try folderStore.moveMeetings([fa.id,"missing"],to:nil); throw AppFailure(message:"无效批量移动应拒绝") } catch { try requireThrowing(try folderStore.memberships().count == 2,"失败移动不得部分提交") }
  try folderStore.deleteFolder("f1")
  try requireThrowing(try folderStore.memberships().isEmpty && folderStore.list().count == 2,"删除文件夹必须保留会议")
  print("PASS 文件夹批量移动、重开、后台保存隔离、事务失败和删除保留会议")
  let noteStore = try Store(root:root.appendingPathComponent("note-cards"))
  var noteMeeting = Meeting(title:"笔记兼容")
  noteMeeting.notes = "原有笔记不变"
  noteMeeting.noteCards = [MeetingNote(time:12,kind:"重点",text:"笔记关键词火星"),MeetingNote(time:nil,kind:"图片",image:"Recordings/test/Notes/example.png")]
  noteMeeting.noteDraft = MeetingNote(time:15,text:"未提交草稿")
  try noteStore.save(noteMeeting)
  let restoredNotes = try Store(root:noteStore.root).list().first!
  try require(restoredNotes.notes == "原有笔记不变" && restoredNotes.noteCards == noteMeeting.noteCards && restoredNotes.noteDraft == noteMeeting.noteDraft,"笔记卡片、草稿及旧笔记必须重启恢复")
  try requireThrowing(try noteStore.search("笔记关键词火星").count == 1,"笔记卡片必须进入搜索")
  try require(!restoredNotes.noteText.contains("未提交草稿") && !restoredNotes.noteText.contains("example.png"),"草稿和图片路径不应发送给模型")
  try require(QAEvidence.sources(meeting:restoredNotes,realtime:[]).contains(where:{$0.text.contains("笔记关键词火星")}),"问答应包含笔记卡片")
  noteMeeting.noteCards?[0].deleted = true; try noteStore.save(noteMeeting)
  try requireThrowing(try noteStore.search("笔记关键词火星").isEmpty,"删除笔记应同步移除索引")
  noteMeeting.noteCards?[0].deleted = nil; try noteStore.save(noteMeeting)
  try requireThrowing(try noteStore.search("笔记关键词火星").count == 1,"撤销删除应恢复索引")
  try require(MeetingNote.timestamp(recording:true,elapsed:42,hasPlayback:true,position:7) == 42,"录音时间应优先")
  try require(MeetingNote.timestamp(recording:false,elapsed:42,hasPlayback:true,position:7) == 7,"回听时间应跟随播放器")
  try require(MeetingNote.timestamp(recording:false,elapsed:42,hasPlayback:false,position:0) == nil,"会后补充不应制造时间戳")
  print("PASS 笔记卡片：旧数据、草稿恢复、软删除恢复、搜索问答、图片路径隔离及自动时间关联")
  let repairStore = try Store(root:root.appendingPathComponent("repair-state"))
  var pendingRepair = Meeting(); pendingRepair.automaticRepair = true; pendingRepair.repairAttempts = 2; pendingRepair.repairAfter = Date().addingTimeInterval(60); pendingRepair.duration = 10; pendingRepair.status = "已结束 · 转写不完整"
  try repairStore.save(pendingRepair)
  let recoveredRepair = try Store(root:repairStore.root).list().first!
  try require(recoveredRepair.automaticRepair == true && recoveredRepair.repairAttempts == 2 && recoveredRepair.repairAfter != nil,"补齐任务和退避时间必须重启后保留")
  let words = MeetingKeyword.grounded([.init(category:"人",text:"王老师"),.init(category:"人",text:"老板"),.init(category:"项目",text:"源图谱"),.init(category:"项目",text:"源图谱")],in:[EvidenceLine(id:"S1",text:"王老师讨论源图谱")])
  try require(words.count == 2 && !words.contains(where:{$0.text == "老板"}),"检索词不得猜身份，重复词需合并")
  let keywordRoot = root.appendingPathComponent("keywords")
  var tagged = Meeting(title:"标签验证")
  tagged.post = PostRecord(); tagged.post?.minutes = "原总结保留"
  tagged.customKeywords = [.init(category:"项目",text:"独有检索词"),.init(category:"人",text:"小王")]
  do { let db = try Store(root:keywordRoot); try db.save(tagged); try requireThrowing(try db.search("独有检索词").count == 1,"检索词必须进入全文搜索"); try requireThrowing(try db.search("小王").count == 1,"两字检索词匹配失败") }
  let reopenedTags = try Store(root:keywordRoot)
  try requireThrowing(try reopenedTags.list().first?.customKeywords == tagged.customKeywords,"检索词重启恢复失败")
  tagged.customKeywords = []; try reopenedTags.save(tagged)
  try requireThrowing(try reopenedTags.search("独有检索词").isEmpty,"删除检索词后索引不得残留")
  try requireThrowing(try reopenedTags.list().first?.post?.minutes == "原总结保留","编辑标签不得改总结")
  let legacyJSON: [String:Any] = ["folders":[["id":"legacy","name":"人工项目"]],"locations":[tagged.id:"legacy"]]
  try JSONSerialization.data(withJSONObject:legacyJSON).write(to:keywordRoot.appendingPathComponent("folders.json"))
  try reopenedTags.migrateLegacyKeywords(); try reopenedTags.migrateLegacyKeywords()
  try requireThrowing(try reopenedTags.search("人工项目").count == 1,"旧归类迁移后应可检索且不能重复")
  try requireThrowing(try reopenedTags.list().first?.customKeywords?.count == 1,"旧归类迁移幂等失败")
  try requireThrowing(try reopenedTags.list().first?.post?.minutes == "原总结保留","旧归类迁移不得改写总结")
  print("PASS 检索词事实约束/去重/长短词搜索/删除索引/重开/总结保留")
  let mediaInput = root.appendingPathComponent("import-test.wav")
  let mediaFormat = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
  let mediaBuffer = AVAudioPCMBuffer(pcmFormat:mediaFormat,frameCapacity:16000)!
  mediaBuffer.frameLength = 16000
  for i in 0..<16000 { mediaBuffer.floatChannelData![0][i] = sin(Float(i)*0.1)*0.1 }
  do { let output = try AVAudioFile(forWriting:mediaInput,settings:mediaFormat.settings); try output.write(from:mediaBuffer) }
  let mediaRoot = root.appendingPathComponent("media")
  let mediaMeeting = try await MediaImport.read(mediaInput,root:mediaRoot)
  let mediaStore = try Store(root:mediaRoot); try mediaStore.save(mediaMeeting)
  let mediaURL = mediaStore.importedAudio(for:mediaMeeting)!
  let decodedMedia = try AVAudioFile(forReading:mediaURL)
  try require(decodedMedia.length > 0 && abs(mediaMeeting.duration-1)<0.1,"媒体导入音轨与时长失败")
  try require(FileManager.default.fileExists(atPath:mediaURL.deletingLastPathComponent().appendingPathComponent("original.wav").path),"必须保留原文件")
  if let video = ProcessInfo.processInfo.environment["VERIFY_MEDIA_VIDEO"] {
   let movie = try await MediaImport.read(URL(fileURLWithPath:video),root:mediaRoot)
   let movieAudio = try AVAudioFile(forReading:mediaStore.importedAudio(for:movie)!)
   try require(movieAudio.length > 0 && abs(movie.duration-2)<0.1,"视频音轨提取失败")
   print("PASS 视频录像提取音轨/解码与时长")
  }
  print("PASS 原生音频导入/音轨可解码/原件保留/数据库音轨定位")
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
  let ownedDirectory = URL(fileURLWithPath:reopenedPlaudRows[0].plaud!.directory)
  try require(ownedDirectory.path.hasPrefix(reopenedPlaud.root.path + "/"),"Plaud必须归档到资料库内")
  let migratedRoot = root.appendingPathComponent("migrated")
  try FileManager.default.createDirectory(at:migratedRoot,withIntermediateDirectories:true)
  let migratedStore = try reopenedPlaud.migrate(to:migratedRoot,activate:false)
  let migratedRows = try migratedStore.list()
  try require(migratedRows.count == 1 && migratedRows[0].plaud!.directory.hasPrefix(migratedRoot.path + "/"),"迁移必须重映射归档路径")
  try require(FileManager.default.fileExists(atPath:ownedDirectory.path),"迁移必须保留原资料")
  do { _ = try reopenedPlaud.migrate(to:migratedRoot,activate:false); throw AppFailure(message:"不应覆盖非空目录") }
  catch let error as AppFailure { try require(error.message.contains("空文件夹"),"迁移应拒绝非空目标") }
  print("PASS Plaud独立归档/目录迁移/路径重映射/非空保护/重复去重/全文搜索/重启")
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
  try MinutesTemplate.save(customTemplate,selectAsDefault:false,defaults:templateDefaults)
  try require(MinutesTemplate.selected(templateDefaults).id == "general","本场新增模板不应改全局默认")
  var scopedMeeting = Meeting(); scopedMeeting.preferredMinutesTemplate = customTemplate
  try repairStore.save(scopedMeeting)
  let scopedLoaded = try repairStore.list().first { $0.id == scopedMeeting.id }
  try require(scopedLoaded?.preferredMinutesTemplate == customTemplate,"本场模板必须持久化且保留快照")
  try require(SearchExcerpt.clean("原文 [S82](#S82) 术语 [N1](#N1)") == "原文 术语","搜索摘要不应泄漏内部引用标记")
  var correction = FinalSentence(id:"S1",begin:1,end:2,speaker:0,text:"原识别")
  try correction.correct("第一次校对"); try correction.correct("第二次校对")
  try require(correction.originalText == "原识别" && correction.id == "S1" && correction.begin == 1 && correction.speaker == 0,"校对不可覆盖原始识别及引用锚点")
  scopedMeeting.post = PostRecord(); scopedMeeting.post?.sentences = [correction]
  try repairStore.save(scopedMeeting)
  let corrected = try repairStore.list().first{$0.id == scopedMeeting.id}!
  try require(corrected.post?.sentences.first?.originalText == "原识别","校对历史应重开保留")
  let correctedHits = try repairStore.search("第二次校对")
  try require(!correctedHits.isEmpty,"校对后搜索必须刷新")
  print("PASS 模板默认/本场范围、校对原文与引用锚点、搜索更新和重开")
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
  var gate = TranscriptUpdateGate()
  var delivered = 0
  for n in 0..<1000 { if gate.accepts(final:false,now:Double(n)/1000) { delivered += 1 } }
  try require(delivered <= 5 && gate.accepts(final:true,now:1),"临时结果节流不得丢弃最终稿")
  let waiting = ASRConnection(source:"slow-start")
  let sender = Task { await waiting.send(AudioPacket(data:Data(repeating:0,count:3200),offset:0)) }
  try await Task.sleep(nanoseconds:50_000_000)
  await waiting.fail("模拟启动网络失败")
  await sender.value
  let waitingState = await waiting.state
  try require(waitingState == .failed,"启动失败必须释放等待发送的任务")
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
  for _ in 0..<1000 { try require(ingress.offer(AudioPacket(data:Data(),offset:0)) == .closed,"积压后不得重复产生失败任务") }
  ingress.finish()
  print("PASS 弱网模拟：临时结果1000次/秒限制至最多5次刷新，最终稿不节流；启动失败释放等待；溢出只报告一次")
  print("PASS 44.1/48 kHz 双声道 → 16 kHz 单声道 PCM16、限幅、尾帧和有界队列")
  let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
  let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800)!
  buffer.frameLength = 4800
  for i in 0..<4800 { buffer.floatChannelData![0][i] = Float(sin(Double(i)*2 * .pi * 440 / 48000))*0.25 }
  guard let copy = AudioWriter.copy(buffer) else { throw AppFailure(message:"复制失败") }
  buffer.floatChannelData![0][100] = 0
  try require(copy.floatChannelData![0][100] != 0,"音频内存未独立")
  let writer = AudioWriter(); try writer.begin(folder:root)
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
  let resumeRoot = root.appendingPathComponent("resume-test")
  try FileManager.default.createDirectory(at:resumeRoot,withIntermediateDirectories:true)
  let resumeWriter = AudioWriter()
  try resumeWriter.begin(folder:resumeRoot,origin:100)
  for source in ["system","microphone"] { resumeWriter.append(copy,source:source,hostSeconds:100) }
  await resumeWriter.finish()
  let originalSegment = try Data(contentsOf:resumeRoot.appendingPathComponent("system-1.caf"))
  // Pause lasts 10 seconds in wall time; the recorded timeline remains contiguous at 0.1 sec.
  try resumeWriter.begin(folder:resumeRoot,origin:110,appendExisting:true)
  for source in ["system","microphone"] { resumeWriter.append(copy,source:source,hostSeconds:110.1) }
  await resumeWriter.finish()
  let unchangedSegment = try Data(contentsOf:resumeRoot.appendingPathComponent("system-1.caf"))
  try require(originalSegment == unchangedSegment,"继续录音覆盖了暂停前文件")
  let resumedManifest = try JSONDecoder().decode([AudioSegment].self,from:Data(contentsOf:resumeRoot.appendingPathComponent("segments.json")))
  try require(resumedManifest.count == 4 && abs(resumedManifest.last!.start-0.1)<0.001,"继续录音丢失分段或包含暂停时长")
  let resumedMix = try MeetingMix.make(folder:resumeRoot)
  try require(abs(resumedMix.seconds-0.2)<0.005,"暂停后混音时间轴错误")
  print("PASS 暂停/继续分段追加、旧文件不变、双路时间轴与最终混音")
  // Delayed second source must not be collapsed to time zero during offline mixing.
  let mixRoot = root.appendingPathComponent("mix-test")
  try FileManager.default.createDirectory(at:mixRoot,withIntermediateDirectories:true)
  let mixWriter = AudioWriter(); try mixWriter.begin(folder:mixRoot,origin:100)
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
  try require(abs(importedMix.seconds-mixed.seconds)<0.005 && importedMix.warning.contains("导入"),"导入音频转换失败")
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
  for refs in [["S1","S999"],["S1,S2"],["[S1]"],["S1-S2"],[" S1"],["N1"],[]] as [[String]] {
   var refused = false
   do { _ = try MinutesService.validate(MinuteResponse(items:[MinuteItem(kind:"summary",text:"测试",refs:refs)]),evidence:evidence) } catch { refused = true }
   try require(refused,"非法引用格式或越界编号不得被自动修正/删除后接受")
  }
  let exactRefs = try MinutesService.validate(MinuteResponse(items:[MinuteItem(kind:"summary",text:"测试",refs:["S1"])]),evidence:evidence)
  try require(exactRefs[0].refs == ["S1"],"有效引用必须原样保留")

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
  try store.saveTranscript(transient,meetingID:library.id,updateIndex:false)
  let pendingSearch = try store.search("临时专用")
  let pendingStored = try store.transcripts(library.id)
  try require(pendingSearch.isEmpty && pendingStored.contains(transient),"临时稿检查点应保留但不刷新全文索引")
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
  let attributed = QAEvidence.attributed([EvidenceLine(id:evidenceSource.id,text:evidenceSource.text)],sources:sources)
  try require(attributed.contains(evidenceSource.label) && attributed.contains(evidenceSource.timeLabel),"问答丢失来源或时间")
  let grounded = QASelection(supported:true,quotes:[],points:[QAPoint(text:"归纳观点",sourceIDs:[evidenceSource.id])])
  let checkedPoints = try QAEvidence.checkedPoints(grounded,references:refs)
  try require(checkedPoints.count == 1,"有据观点校验失败")
  for points in [[],[QAPoint(text:"无引用",sourceIDs:[])],[QAPoint(text:"跨会议",sourceIDs:["other"])]] as [[QAPoint]] {
   var refused = false
   do { _ = try QAEvidence.checkedPoints(QASelection(supported:true,quotes:[],points:points),references:refs) } catch { refused = true }
   try require(refused,"无依据的观点未拒绝")
  }
  let extraSource = QASource.make(kind:"final",target:"real-local-source",text:"必须有足够数据才可验证",time:120,label:"测试发言人")
  let omittedExcerpt = QASelection(supported:true,quotes:[QAQuote(id:evidenceSource.id,quote:evidenceSource.text)],points:[QAPoint(text:"需要数据验证",sourceIDs:[extraSource.id])])
  let completedReferences = try QAEvidence.completeReferences(omittedExcerpt,sources:sources+[extraSource])
  let completedPoints = try QAEvidence.checkedPoints(omittedExcerpt,references:completedReferences)
  try require(completedPoints.count == 1 && completedReferences.last?.quote == extraSource.text,"合法来源未补足原句")
  var unknownSourceRejected = false
  do { _ = try QAEvidence.completeReferences(omittedExcerpt,sources:sources) } catch { unknownSourceRejected = true }
  try require(unknownSourceRejected,"未知观点来源未拒绝")
  let unknown = try QAEvidence.checked(QASelection(supported:false,quotes:[]),sources:sources)
  try require(unknown.isEmpty,"无依据回答没有拒答")
  let exactSelection = try QAEvidence.materialize(QASourceSelection(supported:true,sourceIDs:[evidenceSource.id],points:[QAPoint(text:"归纳",sourceIDs:[evidenceSource.id])]),lines:[EvidenceLine(id:evidenceSource.id,text:evidenceSource.text)])
  try require(exactSelection.quotes.first?.quote == evidenceSource.text,"本地引用必须逐字保留原文")
  var badSelectionRejected = false
  do { _ = try QAEvidence.materialize(QASourceSelection(supported:true,sourceIDs:["unknown"],points:[]),lines:[EvidenceLine(id:evidenceSource.id,text:evidenceSource.text)]) } catch { badSelectionRejected = true }
  try require(badSelectionRejected,"未知引用ID必须拒绝")
  var otherMeeting = library; otherMeeting.id = UUID().uuidString
  let scopedA = QAEvidence.librarySources(meeting:library,realtime:[])
  let scopedB = QAEvidence.librarySources(meeting:otherMeeting,realtime:[])
  try require(Set(scopedA.map(\.id)).isDisjoint(with:Set(scopedB.map(\.id))),"跨会议同句ID必须隔离")
  try require(scopedA.allSatisfy { $0.meetingID == library.id && $0.originalSourceID != nil },"引用必须保留会议及原句身份")
  let scopeMeetings = [library,otherMeeting]
  try require(QAEvidence.scopedMeetings(scopeMeetings,scope:"all",selected:[],memberships:[:]).count == 2,"全部范围")
  try require(QAEvidence.scopedMeetings(scopeMeetings,scope:"selected",selected:[otherMeeting.id],memberships:[:]).map(\.id) == [otherMeeting.id],"指定范围")
  try require(QAEvidence.scopedMeetings(scopeMeetings,scope:"folder",selected:[],memberships:[library.id:"folder"]).map(\.id) == [library.id],"文件夹范围")
  try require(QAEvidence.scopedMeetings(scopeMeetings,scope:"deleted",selected:[],memberships:[:]).isEmpty,"已删除文件夹不可回退全部")
  var outsideRejected = false
  if let outside = scopedB.first { do { _ = try QAEvidence.checked(QASelection(supported:true,quotes:[QAQuote(id:outside.id,quote:outside.text)]),sources:scopedA) } catch { outsideRejected = true } }
  try require(outsideRejected,"必须拒绝范围外会议引用")
  print("PASS 跨会议范围隔离、同句ID隔离、引用定位元数据与越界拒绝")
  let digest = QAEvidence.digest(sources); library.notes += "发生变化"
  try require(digest != QAEvidence.digest(QAEvidence.sources(meeting:library,realtime:[transient])),"问答版本变化未检测")
  library.questions = [QAEntry(question:"验证问题",status:"依据原文回答",references:refs,sourceDigest:digest,coverage:"测试",supported:true)]
  library.questions?[0].points = checkedPoints
  try store.save(library)
  let restoredQA = try Store(root:root).list().first(where:{$0.id == library.id})?.questions?.first
  try require(restoredQA?.references.first?.quote == "最终确认内容","问答或引用快照重启丢失")
  try require(restoredQA?.points == checkedPoints,"观点及引用映射重启丢失")
  let oldEntry = try JSONDecoder().decode(QAEntry.self,from:Data(#"{"question":"旧问题","id":"old","created":0,"status":"旧答案","references":[],"sourceDigest":"old","coverage":"旧资料","supported":false}"#.utf8))
  try require(oldEntry.points == nil,"旧问答兼容失败")
  print("PASS FTS5中文/短词/日期/多来源/索引更新/恶意查询/重开；问答仅原文、引用逐字校验、跨会议拒绝、资料不足与版本快照")

  var partialNoteMeeting = Meeting(title:"笔记保存独立验证")
  try store.save(partialNoteMeeting)
  partialNoteMeeting.noteDraft = MeetingNote(time:12)
  partialNoteMeeting.noteDraft?.text = "草稿保留"
  partialNoteMeeting.noteCards = [MeetingNote(time:12,text:"连续输入后的完整中文笔记")]
  try store.saveNotes(partialNoteMeeting)
  try requireThrowing(try store.search("完整中文").contains(where:{$0.meeting.id == partialNoteMeeting.id}),"笔记索引缺失")
  partialNoteMeeting.noteCards?[0].text = "修改后的内容"
  try store.saveNotes(partialNoteMeeting)
  try requireThrowing(try store.search("完整中文").allSatisfy({$0.meeting.id != partialNoteMeeting.id}),"笔记旧索引残留")
  print("PASS 笔记局部保存与搜索索引更新")

 }
}
