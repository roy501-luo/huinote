import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor final class Model: ObservableObject {
 var noteSaveTask: Task<Void,Never>?
 var notesDirty = false
 var didStartKeywordBackfill = false
 var keywordBackfillTask: Task<Void,Never>?
 @Published var keywordBackfillRunning = false
 @Published var batchJob: BatchJob?
 @Published var batchRunning = false
 @Published var batchProgress = ""
 @Published var batchFailures: [String] = []
 private var batchTask: Task<Void,Never>?
 @Published var plaudProgress = ""
 @Published var plaudSyncRunning = false
 @Published var searchHits: [String:MeetingSearchHit] = [:]
 @Published var question = ""
 @Published var speakerPanelVisible = false
 @Published var notesVisible = false
 @Published var summarySourcesVisible = false
 @Published var summaryReferenceIDs: [String] = []
 @Published var summaryReferenceText = ""
 @Published var summaryReferenceIndex = 0
 @Published var showingGeneration = false
 @Published var summaryAfterSpeakerReview = false
 @Published var qaBusy = false
 @Published var qaProgress = ""
 @Published var showingQA = false
 @Published var detailPage = "转写"
 @Published var summarySearchTerm = ""
 @Published var showingLibrary = false
 @Published var showingLibraryQA = false
 @Published var returningToLibraryQA = false
 @Published var showingSearch = false
 @Published var libraryScope = "recent"
 @Published var folders: [MeetingFolder] = []
 @Published var memberships: [String:String] = [:]
 var libraryTitle: String { libraryScope == "recent" ? "最近会议" : libraryScope == "all" ? "全部会议" : libraryScope == "unfiled" ? "未分类" : folders.first(where:{$0.id == libraryScope})?.name ?? "全部会议" }
 var libraryMeetings: [Meeting] {
  if libraryScope == "unfiled" { return meetings.filter { memberships[$0.id] == nil } }
  if libraryScope == "recent" { return Array(meetings.prefix(20)) }
  if libraryScope == "all" { return meetings }
  return meetings.filter { memberships[$0.id] == libraryScope }
 }
 func showLibrary(_ scope: String) {
  guard !busy && !qaBusy else { return }
  libraryScope = scope; showingLibrary = true; showingLibraryQA = false; returningToLibraryQA = false
 }
 func moveMeetings(_ ids: Set<String>, to folder: String?) {
  do { try store?.moveMeetings(ids,to:folder); reload() } catch { self.error = error.localizedDescription }
 }
 func saveFolder(_ folder: MeetingFolder) {
  do { try store?.saveFolder(id:folder.id,name:folder.name); reload() } catch { self.error = error.localizedDescription }
 }
 func deleteFolder(_ folder: MeetingFolder) {
  do { try store?.deleteFolder(folder.id); if libraryScope == folder.id { libraryScope = "unfiled" }; reload() } catch { self.error = error.localizedDescription }
 }
 @Published var sourcePreview: QAReference?
 @Published var citationScrollToken = UUID()
 private var qaTask: Task<Void,Never>?
 @Published var meetings: [Meeting] = []
 @Published var current: Meeting? { willSet { if current?.id != newValue?.id { flushNotes() } } didSet { if let id = recordingMeeting?.id, current?.id == id { recordingMeeting = current } } }
 @Published var transcripts: [Transcript] = [] { didSet { if let id = recordingMeeting?.id, current?.id == id { recordingTranscripts = transcripts } } }
 @Published var query = "" { didSet {
  guard query != oldValue else { return }
  if !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { showingSearch = true }
 } }
 @Published var postMeetingID: String?
 @Published var postProcessing = false
 @Published var postProgress = ""
 @Published var showingFinal = false
 @Published var reviewQuery = ""
 @Published var reviewSpeaker = "all"
 @Published var focusedSentence: String?
 private var postTask: Task<Void,Never>?
 // The recorder owns its meeting even while another document is open.
 @Published private var recordingMeeting: Meeting?
 private var recordingTranscripts: [Transcript] = []
 var viewingRecording: Bool { recording && current?.id == recordingMeeting?.id }
 private var liveMeeting: Meeting? {
  get { recordingMeeting == nil || current?.id == recordingMeeting?.id ? current : recordingMeeting }
  set { if recordingMeeting == nil || current?.id == recordingMeeting?.id { current = newValue }; if recordingMeeting != nil { recordingMeeting = newValue } }
 }
 private var liveTranscripts: [Transcript] {
  get { recordingMeeting == nil || current?.id == recordingMeeting?.id ? transcripts : recordingTranscripts }
  set { if recordingMeeting == nil || current?.id == recordingMeeting?.id { transcripts = newValue }; recordingTranscripts = newValue }
 }
 private func saveRecording() {
  guard let meeting = liveMeeting else { return }
  recordingMeeting = meeting
  do { try store?.save(meeting); reload() } catch { self.error = error.localizedDescription }
 }
 func returnToRecording() {
  guard let meeting = liveMeeting, recording, !busy, !qaBusy else { return }
  select(meeting); notesVisible = true
 }
 @Published var recordingPaused = false { didSet { updateRecordingTimer() } }
 private var audioIncompleteBeforePause = false
 @Published var recording = false { didSet { updateRecordingTimer() } }
 @Published var busy = false
 @Published var error: String?
 @Published var system = AudioHealth()
 @Published var microphone = AudioHealth()
 @Published var now = Date()
 @Published var asrStates: [String:String] = [:]
 private(set) var store: Store?
 private let capture = Capture()
 private var timer: Timer?
 private var connections: [String:ASRConnection] = [:]
 private var ingresses: [String:AudioIngress] = [:]
 private var pumps: [Task<Void,Never>] = []
 private var networkStart: Task<Void,Never>?
 private var liveSessions: [String:LiveASRSession] = [:]
 private var repairTimer: Timer?
 private var liveGapIDs: [String:String] = [:]
 private var interimSavedAt: [String:Double] = [:]
 private var captureSessionStarted = ProcessInfo.processInfo.systemUptime
 private var origin = ProcessInfo.processInfo.systemUptime
 private var recordingEnd: Double?
 private var didLaunchVerification = false
 private var fileTask: Task<Void,Never>?
 private var filePlaybackStopping = false
 init() {
  do {
   store = try Store()

   for var meeting in try store?.list() ?? [] {
    if let status = meeting.post?.status, ["准备单声道", "上传百炼", "会后识别与", "生成纪要"].contains(where:{status.hasPrefix($0)}) {
     let hasTask = meeting.post?.taskID != nil
     meeting.post?.status = !hasTask ? "上次会后处理中断 · 可重试" : "上次会后处理中断 · 可继续查询"
     try store?.save(meeting)
    }
   }
   for var meeting in try store?.list() ?? [] {
    if let entries = meeting.questions, entries.contains(where:{$0.status == "正在检索"}) {
     meeting.questions = entries.map { var row = $0; if row.status == "正在检索" { row.status = "上次问答中断，可重试" }; return row }
     try store?.save(meeting)
    }
   }
   for var meeting in try store?.list() ?? [] where meeting.plaud != nil && meeting.post?.minutesModel == nil && meeting.post?.speakerNumberOffset == nil {
    meeting.post?.speakerNumberOffset = 0
    if let post = meeting.post, meeting.noteText.isEmpty { meeting.post?.minutesBasis = post.sentences.map { "\($0.id):[\($0.timeLabel)] \(post.name($0.speaker))：\($0.text)" }.joined(separator:"\n") }
    try store?.save(meeting)
   }
   if let store { batchJob = try BatchJob.load(root:store.root)
    if let job = batchJob { batchProgress = "上次批量：已完成 \(job.completed.count)，待继续 \(job.pending.count)，失败 \(job.failures.count)"; batchFailures = Array(job.failures.values).sorted() }
   }
   for var meeting in try store?.list() ?? [] where (meeting.plaud != nil || meeting.mediaFile != nil) && meeting.post?.status == "会后处理完成 · 纪要待核对" && meeting.status.contains("待") {
    meeting.status = meeting.plaud != nil ? "Plaud · 已完成" : "媒体 · 已完成"
    try store?.save(meeting)
   }
   reload()
   try store?.cleanDeletedRecordings()
  } catch { self.error = error.localizedDescription }
  capture.writer.update = { [weak self] source, health in Task { @MainActor in
   guard let self else { return }
   if source == "system" { self.system = health } else { self.microphone = health }
   if let error = health.error { Task { await self.connections[source]?.fail(error); await self.liveSessions[source]?.failAudio(error) } }
  } }
 }
 private func updateRepairTimer() {
  guard meetings.contains(where:{ $0.automaticRepair == true }) else {
   repairTimer?.invalidate(); repairTimer = nil; return
  }
  guard repairTimer == nil else { return }
  repairTimer = Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in
   Task { @MainActor in self?.resumeAutomaticRepair() }
  }
  repairTimer?.tolerance = 3
 }
 private func updateRecordingTimer() {
  timer?.invalidate(); timer = nil
  guard recording && !recordingPaused else { return }
  now = Date()
  timer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
   Task { @MainActor in
    guard let self, self.recording else { return }
    self.now = Date(); self.checkAudioLiveness()
   }
  }
  timer?.tolerance = 0.1
 }
 private func checkAudioLiveness() {
  guard recording && !recordingPaused && !busy && recordingEnd == nil && ProcessInfo.processInfo.systemUptime-captureSessionStarted > 5 else { return }
  for (source,health) in [("system",system),("microphone",microphone)] {
   if health.lastReceived == nil || now.timeIntervalSince(health.lastReceived!) > 3 {
    if liveMeeting?.audioCaptureIncomplete != true { liveMeeting?.audioCaptureIncomplete = true; saveRecording() }
    if source == "microphone", capture.recoverMicrophone() { continue }
    let connection = connections[source]
    let live = liveSessions[source]
    Task { await connection?.fail("超过 3 秒未收到该音源的音频帧，设备可能中断；后续实时转写缺失。"); await live?.failAudio("超过3秒未收到音频帧，设备可能中断；请检查音源。") }
   }
  }
 }
 func importMedia() {
  guard !recording && !busy && !postProcessing && !qaBusy && !batchRunning, let store else { return }
  let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio,.movie]; panel.allowsMultipleSelection = true
  panel.message = "选择音频或视频录像，原文件将复制到资料库。"; panel.prompt = "导入"
  guard panel.runModal() == .OK else { return }
  let urls = panel.urls; busy = true; plaudProgress = "正在导入媒体…"
  Task {
   defer { busy = false; reload() }
   var added = 0; var failures: [String] = []
   for url in urls {
    do {
     let meeting = try await MediaImport.read(url,root:store.root)
     try store.save(meeting); added += 1
    } catch { failures.append(url.lastPathComponent + "：" + error.localizedDescription) }
   }
   plaudProgress = "媒体导入完成：成功 \(added)，失败 \(failures.count)"
   if !failures.isEmpty { self.error = failures.joined(separator:"\n") }
  }
 }
 func choosePlaudDirectory() {
  let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
  panel.message = "选择含各场 Plaud 纪要子目录的资料目录"; panel.prompt = "选择并导入"
  panel.directoryURL = URL(fileURLWithPath:PlaudImport.defaultDirectory).resolvingSymlinksInPath()
  guard panel.runModal() == .OK, let url = panel.url else { return }
  UserDefaults.standard.set(url.path,forKey:"plaudDirectory"); syncPlaud()
 }
 func syncPlaud(download: Bool = false, login: Bool = false) {
  guard !busy && !recording && !postProcessing && !qaBusy, let root = store?.root else { return }
  busy = true; plaudSyncRunning = true; plaudProgress = login ? "等待 Plaud 登录…" : download ? "从 Plaud 下载录音…" : "正在导入本地 Plaud 纪要…"
  let local = URL(fileURLWithPath:UserDefaults.standard.string(forKey:"plaudDirectory") ?? PlaudImport.defaultDirectory)
  let tool = URL(fileURLWithPath:UserDefaults.standard.string(forKey:"plaudTool") ?? PlaudImport.defaultTool)
  Task {
   defer { busy = false; plaudSyncRunning = false; reload() }
   do {
    let message = try await Task.detached { () throws -> String in
     let database = try Store(root:root)
     if login {
      try PlaudImport.download(tool:tool,destination:root.appendingPathComponent("PlaudDownloads"),known:[],login:true)
      return "Plaud 登录完成，可下载录音"
     }
     let first: PlaudImportReport
     if download && !FileManager.default.fileExists(atPath:local.path) { first = PlaudImportReport() }
     else { first = try PlaudImport.sync(directory:local,store:database) }
     if !download { return first.message }
     let known = try database.list().compactMap{$0.plaud?.fileID}
     let downloads = root.appendingPathComponent("PlaudDownloads")
     var failure: Error?
     do { try PlaudImport.download(tool:tool,destination:downloads,known:known) } catch { failure = error }
     let second = try PlaudImport.sync(directory:downloads,store:database)
     if let failure { throw failure }
     return "本地：\(first.message)；下载：\(second.message)。选择待处理录音，生成说话人稿与纪要。"
    }.value
    plaudProgress = message
   } catch { plaudProgress = "同步未全部完成，已导入资料保留"; self.error = error.localizedDescription }
   if let id = current?.id, let latest = try? store?.list().first(where:{$0.id == id}) { current = latest }
  }
 }
 func chooseLibraryDirectory() {
  guard !recording && !busy && !postProcessing && !qaBusy && !batchRunning, let store else { return }
  let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
  panel.canCreateDirectories = true; panel.message = "选择空文件夹。迁移全部会议资料，原目录保留备份。"; panel.prompt = "迁移到此目录"
  guard panel.runModal() == .OK, let destination = panel.url else { return }
  busy = true
  do {
   self.store = try store.migrate(to:destination)
   if let path = UserDefaults.standard.string(forKey:"plaudDirectory"), path.hasPrefix(store.root.path + "/") { UserDefaults.standard.set(destination.path + path.dropFirst(store.root.path.count),forKey:"plaudDirectory") }
   if let id = current?.id { current = try self.store?.list().first(where:{$0.id == id}) }
   reload()
  } catch { self.error = error.localizedDescription }
  busy = false
 }
 func reload() {
  do {
   folders = try store?.folders() ?? []; memberships = try store?.memberships() ?? [:]
   meetings = try store?.list() ?? []; searchHits = [:]
   updateRepairTimer()
  } catch { self.error = error.localizedDescription }
 }
 var canCreateMeeting: Bool { !recording && !busy && !qaBusy && store != nil }
 var currentSummaryLocked: Bool { guard let id = current?.id else { return false }; return id == postMeetingID || (batchRunning && batchJob?.pending.contains(id) == true) }
 var canDelete: Bool { !recording && !busy && !postProcessing && !batchRunning && !qaBusy && store != nil }
 func deleteMeetings(_ selected: [Meeting]) {
  guard canDelete, let store else { return }
  do { try store.deleteMeetings(selected.map(\.id)) } catch { self.error = error.localizedDescription }
  let remaining = Set((try? store.list().map(\.id)) ?? [])
  reload()
  if let id = current?.id, selected.contains(where:{$0.id == id}),
     let all = try? store.list(), !all.contains(where:{$0.id == id}) {
   current = nil; transcripts = []; sourcePreview = nil; focusedSentence = nil
   question = ""; showingQA = false; showingFinal = false; asrStates = [:]
   system = AudioHealth(); microphone = AudioHealth(); recordingEnd = nil
  }
 }
 func new(persist: Bool = true) {
  guard canCreateMeeting else { return }
  showingLibrary = false; showingLibraryQA = false; returningToLibraryQA = false
  current = Meeting(title:"会议 " + Date().formatted(date:.abbreviated,time:.shortened))
  detailPage = "转写"; showingFinal = false; focusedSentence = nil; question = ""; showingQA = false
  transcripts = []; asrStates = [:]; system = AudioHealth(); microphone = AudioHealth(); recordingEnd = nil
  if persist { save() }
 }
 func select(_ meeting: Meeting) {
  guard !busy && !qaBusy else { return }
  if current?.id == meeting.id && showingLibrary { showingLibrary = false; showingLibraryQA = false; return }
  showingLibrary = false; showingLibraryQA = false; returningToLibraryQA = false
  showingGeneration = false
  summarySearchTerm = ""
  summarySourcesVisible = false; summaryReferenceIDs = []; summaryAfterSpeakerReview = false
  reviewQuery = ""; reviewSpeaker = "all"
  if recording, current?.id == recordingMeeting?.id { recordingMeeting = current; recordingTranscripts = transcripts }
  detailPage = "转写"; current = meeting; showingFinal = !(meeting.post?.sentences.isEmpty ?? true); focusedSentence = nil; if !recording { asrStates = [:]; system = AudioHealth(); microphone = AudioHealth() }
  do { transcripts = try store?.transcripts(meeting.id) ?? [] } catch { self.error = error.localizedDescription }
  question = ""
  if let hit = searchHits[meeting.id] {
   if hit.kind == "final" || hit.kind == "realtime" { showingFinal = hit.kind == "final"; focusedSentence = hit.target; citationScrollToken = UUID() }
   if hit.kind == "minutes" || hit.kind == "keywords" { detailPage = "总结" }
   if hit.kind == "notes", let source = qaSources().first(where:{$0.kind == "notes"}) { sourcePreview = QAReference(source:source,quote:hit.excerpt) }
  }
 }
 func save() {
  guard let current else { return }
  do { try store?.save(current); reload() } catch { self.error = error.localizedDescription }
 }
 private func accept(_ transcript: Transcript, meetingID: String) {
  guard liveMeeting?.id == meetingID else { return }
  TranscriptReducer.merge(transcript,into:&liveTranscripts)
  guard let accepted = liveTranscripts.first(where:{$0.id == transcript.id}) else { return }
  let clock = ProcessInfo.processInfo.systemUptime
  guard accepted.final || clock-interimSavedAt[accepted.id,default:0] >= 2 else { return }
  interimSavedAt[accepted.id] = clock
  do { try store?.saveTranscript(accepted,meetingID:meetingID,updateIndex:accepted.final) } catch { self.error = "转写保存失败：\(error.localizedDescription)" }
 }
 private func updateASRState(_ state: ASRState, message: String?, lastFinalEnd: Double, source: String, taskID: String, meetingID: String) {
  guard liveMeeting?.id == meetingID else { return }
  asrStates[source] = message ?? state.rawValue
  if state == .failed {
   accept(Transcript(id:"\(source):\(taskID):gap",source:source,begin:lastFinalEnd,end:nil,text:message ?? "转写缺失",final:true,gap:true),meetingID:meetingID)
  }
 }
 private func prepareASR(_ configuration: ASRConfiguration, sources: [String], background: Bool = false) async {
  connections = [:]; ingresses = [:]; pumps = []
  guard let meetingID = liveMeeting?.id else { return }
  for source in sources {
   let connection = ASRConnection(source:source)
   let taskID = connection.taskID
   await connection.configure(onSentence: { [weak self] sentence in
    await self?.accept(sentence,meetingID:meetingID)
   }, onState: { [weak self] state, message, lastFinalEnd in
    await self?.updateASRState(state,message:message,lastFinalEnd:lastFinalEnd,source:source,taskID:taskID,meetingID:meetingID)
   })
   connections[source] = connection
   let ingress = AudioIngress(); ingresses[source] = ingress
   pumps.append(Task.detached { for await packet in ingress.stream { await connection.send(packet) } })
  }
  let inputs = ingresses
  let sockets = connections
  capture.writer.onPCM = { source, packet in
   if inputs[source]?.offer(packet) == .overflow {
    Task { await sockets[source]?.fail("网络发送积压超过 10 秒，实时转写中断；原始录音继续保存。") }
   }
  }
  capture.writer.onPCMError = { source, message in Task { await sockets[source]?.fail(message) } }
  let task = Task {
   await withTaskGroup(of:Void.self) { group in
    for connection in sockets.values { group.addTask { do { try await connection.start(configuration) } catch { /* State callback records the failure. */ } } }
   }
  }
  networkStart = task
  if !background { await task.value }
 }
 private func prepareLiveASR() async throws {
  interimSavedAt = [:]; liveGapIDs = [:]
  connections = [:]; ingresses = [:]; pumps = []; liveSessions = [:]
  guard let id = liveMeeting?.id else { return }
  if UserDefaults.standard.object(forKey:"liveTranscription") as? Bool ?? true {
   // The Keychain helper uses blocking pipe reads/process waits. Never run it on the UI actor.
   let config = try await Task.detached(priority:.userInitiated) { try ASRConfiguration.load() }.value
   let offset = recordingPaused ? liveMeeting?.duration ?? 0 : 0
   for source in ["system","microphone"] {
    let session = LiveASRSession(configuration:config,source:source,offset:offset,
     sentence: { [weak self] item in await self?.accept(item,meetingID:id) },
     status: { [weak self] value in await self?.setLiveStatus(value,source:source,meetingID:id) },
     missing: { [weak self] task,begin,message in await self?.markLiveGap(source:source,task:task,begin:begin,message:message,meetingID:id) },
     recovered: { [weak self] offset in await self?.closeLiveGap(source:source,offset:offset,meetingID:id) })
    liveSessions[source] = session
   }
   let sessions = liveSessions
   capture.writer.onPCM = { source,packet in sessions[source]?.route.push(packet) }
   capture.writer.onPCMError = { source,message in Task { await sessions[source]?.failAudio(message) } }
   // Network workers start only after local capture succeeds.
  } else {
   capture.writer.onPCM = nil; capture.writer.onPCMError = nil
   asrStates = ["system":"仅本地录音","microphone":"仅本地录音"]
  }
 }
 private func setLiveStatus(_ value: String, source: String, meetingID: String) {
  guard liveMeeting?.id == meetingID else { return }; asrStates[source] = value
 }
 private func markLiveGap(source: String,task: String,begin: Double,message: String,meetingID: String) {
  guard liveMeeting?.id == meetingID else { return }
  if liveGapIDs[source] == nil {
   let gap = source+":"+task+":gap"; liveGapIDs[source] = gap
   accept(Transcript(id:gap,source:source,begin:begin,end:nil,text:message+(message.contains("设备") || message.contains("音频帧") ? " 其他可用音源继续保存；未采集到的声音无法补齐。" : " 本段已保留录音，等待会后补齐。"),final:true,gap:true),meetingID:meetingID)
  }
  liveMeeting?.automaticRepair = true; saveRecording()
 }
 private func closeLiveGap(source: String,offset: Double,meetingID: String) {
  guard liveMeeting?.id == meetingID, let id = liveGapIDs.removeValue(forKey:source), var gap = liveTranscripts.first(where:{$0.id == id}) else { return }
  gap.end = max(gap.begin,offset); accept(gap,meetingID:meetingID)
 }
 private func resumeAutomaticRepair() {
  guard !recording && !busy && !postProcessing && !batchRunning && !qaBusy, store != nil,
        let target = meetings.first(where:{ $0.automaticRepair == true && ($0.repairAfter ?? .distantPast) <= Date() && $0.duration > 0 }) else { return }
  postProcessing = true; postMeetingID = target.id
  postTask = Task { await processMeeting(meeting:target,onlyMinutes:false,forceNew:false) }
 }
 func startNewMeeting() async {
  guard canCreateMeeting else { return }
  if current?.status != "未开始" { new(persist:false) }
  await start()
 }
 func resumeRecording() async {
  guard recording && recordingPaused && !busy, let store, let id = liveMeeting?.id else { return }
  busy = true; defer { busy = false }
  let offset = liveMeeting?.duration ?? 0
  connections = [:]; system = AudioHealth(); microphone = AudioHealth()
  do {
   do { try await prepareLiveASR() }
   catch { capture.writer.onPCM = nil; capture.writer.onPCMError = nil; asrStates = ["system":"未连接","microphone":"未连接"]; accept(Transcript(id:"resume-no-asr:"+UUID().uuidString,source:"system",begin:offset,end:nil,text:error.localizedDescription+" 本段仅保存录音。",final:true,gap:true),meetingID:id) }
   origin = ProcessInfo.processInfo.systemUptime-offset
   try await capture.start(folder:store.folder(id),origin:origin,appendExisting:true)
   captureSessionStarted = ProcessInfo.processInfo.systemUptime
   recordingEnd = nil; recordingPaused = false; liveMeeting?.status = "录音中"; saveRecording()
   for session in liveSessions.values { await session.start() }
  } catch { await finishASR(); liveMeeting?.status = "已暂停"; saveRecording(); self.error = error.localizedDescription }
 }
 func start() async {
  guard !busy && !recording && !qaBusy && !currentSummaryLocked, let store else { return }
  if current == nil || current?.status != "未开始" { new() }
  recordingMeeting = current; recordingTranscripts = []
  busy = true; recordingPaused = false; audioIncompleteBeforePause = false; system = AudioHealth(); microphone = AudioHealth(); recordingEnd = nil
  defer { busy = false }
  guard let id = liveMeeting?.id else { return }
  var configurationFailure: String?
  do {
   liveMeeting?.status = "正在启动录音"
   do { try await prepareLiveASR() }
   catch {
    asrStates = ["system":"未连接","microphone":"未连接"]
    capture.writer.onPCM = nil; capture.writer.onPCMError = nil
    configurationFailure = error.localizedDescription
   }
   origin = ProcessInfo.processInfo.systemUptime; liveMeeting?.started = Date()
   try await capture.start(folder:store.folder(id),origin:origin)
   captureSessionStarted = ProcessInfo.processInfo.systemUptime
   liveMeeting?.status = "录音中"; recording = true; notesVisible = true; saveRecording()
   if let configurationFailure { accept(Transcript(id:"no-asr:"+id,source:"system",begin:0,end:nil,text:configurationFailure + " 本次仅保存本地录音。",final:true,gap:true),meetingID:id) }
   for session in liveSessions.values { await session.start() }
  } catch {
   await finishASR()
   current?.status = "未开始"; recordingMeeting = nil; self.error = error.localizedDescription
  }
 }
 private func finishASR() async {
  if !liveSessions.isEmpty {
   var stats = liveMeeting?.asrRuns ?? [:]
   await withTaskGroup(of:(String,[String:ASRRunStatistics]).self) { group in
    for (source,session) in liveSessions { group.addTask { (source,await session.finish()) } }
    for await (source,runs) in group { for (id,run) in runs { stats[source+":"+id] = run } }
   }
   liveMeeting?.asrRuns = stats; liveSessions = [:]
  }
  for input in ingresses.values { input.finish() }
  let sockets = connections
  let drainDeadline = Task {
   do { try await Task.sleep(nanoseconds:3_000_000_000) } catch { return }
   for connection in sockets.values { await connection.fail("弱网下发送积压未能及时收齐，实时稿可能缺失；完整本地录音可用于会后转写。") }
  }
  for pump in pumps { await pump.value }
  drainDeadline.cancel()
  networkStart?.cancel(); networkStart = nil
  await withTaskGroup(of:Void.self) { group in
   for connection in connections.values { group.addTask { await connection.finish() } }
  }
  for connection in connections.values { await connection.cancel() }
  pumps = []; ingresses = [:]
  if let id = liveMeeting?.id {
   for item in liveTranscripts where !item.final { do { try store?.saveTranscript(item,meetingID:id) } catch { self.error = "转写保存失败：\(error.localizedDescription)" } }
  }
  capture.writer.onPCM = nil; capture.writer.onPCMError = nil
 }
 func stop(runPostProcessing: Bool = true, pauseOnly: Bool = false) async {
  guard recording && !busy && !(pauseOnly && recordingPaused) else { return }
  busy = true; filePlaybackStopping = true
  if !recordingPaused {
  recordingEnd = ProcessInfo.processInfo.systemUptime-origin
  await capture.stop() // Flush resampler and packet tail before closing the bounded streams.
  liveMeeting?.duration = recordingEnd ?? 0
  liveMeeting?.status = "收齐转写尾部"; saveRecording()
  await finishASR()
  if let id = liveMeeting?.id {
   for var item in liveTranscripts where item.gap && item.end == nil {
    item.end = max(item.begin,liveMeeting?.duration ?? 0); accept(item,meetingID:id)
   }
   for connection in connections.values where await connection.state == .finished {
    let unfinished = liveTranscripts.filter { !$0.final && $0.id.contains(connection.taskID) }
    if !unfinished.isEmpty {
     accept(Transcript(id:connection.taskID+":unfinished",source:connection.source,begin:unfinished.map(\.begin).min() ?? 0,end:liveMeeting?.duration,text:"服务已结束，但存在未经最终确认的临时句子。",final:true,gap:true),meetingID:id)
    }
   }
  }
  var statistics = liveMeeting?.asrRuns ?? [:]
  for (source,connection) in connections { statistics[source+":"+connection.taskID] = await connection.statistics() }
  liveMeeting?.asrRuns = statistics
  audioIncompleteBeforePause = audioIncompleteBeforePause || system.error != nil || microphone.error != nil || system.frames == 0 || microphone.frames == 0
  }
  if pauseOnly { recordingPaused = true; liveMeeting?.status = "已暂停"; busy = false; saveRecording(); return }
  let audioIncomplete = audioIncompleteBeforePause || liveMeeting?.audioCaptureIncomplete == true
  if audioIncomplete { liveMeeting?.audioCaptureIncomplete = true }
  liveMeeting?.status = liveTranscripts.contains(where:{$0.gap}) ? "已结束 · 转写不完整" : audioIncomplete ? "已结束 · 音源不完整" : liveTranscripts.isEmpty ? "已结束 · 待会后转写" : "已结束 · 转写已收齐"
  saveRecording()
  let finished = liveMeeting
  recording = false; recordingPaused = false; busy = false
  recordingMeeting = nil; recordingTranscripts = []
  if let finished {
   current = finished; transcripts = (try? store?.transcripts(finished.id)) ?? []
   showingLibrary = false; showingLibraryQA = false; returningToLibraryQA = false
   showingQA = false; showingFinal = !(finished.post?.sentences.isEmpty ?? true); detailPage = "转写"
   sourcePreview = nil; focusedSentence = nil; reviewQuery = ""; reviewSpeaker = "all"
  }
  if runPostProcessing && (!didLaunchVerification || !CommandLine.arguments.contains("--verify-asr-file") || CommandLine.arguments.contains("--verify-recovery") || CommandLine.arguments.contains("--verify-network")) {
   if finished?.automaticRepair == true || (UserDefaults.standard.object(forKey:"autoPostMeeting") as? Bool ?? true) {
    if var finished {
     if postProcessing || qaBusy { if finished.post == nil { finished.post = PostRecord() }; finished.post?.status = "等待后台会后处理"; try? store?.save(finished); reload() }
     else { postProcessing = true; postMeetingID = finished.id; postTask = Task { await processMeeting(meeting:finished,onlyMinutes:false,forceNew:false) } }
    }
   }
  }
 }
 var elapsed: TimeInterval { viewingRecording ? recordingEnd ?? (ProcessInfo.processInfo.systemUptime-origin) : current?.duration ?? 0 }
 var recordingElapsed: TimeInterval { recording ? recordingEnd ?? max(0,ProcessInfo.processInfo.systemUptime-origin) : 0 }
 var asrSummary: String {
  if asrStates.isEmpty { return "百炼实时 ASR · 北京" }
  return ["system","microphone"].map { "\($0 == "system" ? "系统" : "麦克风")：\(asrStates[$0] ?? "未连接")" }.joined(separator:"  ·  ")
 }
 func showFiles() {
  guard let id = current?.id, let store else { return }
  do { NSWorkspace.shared.open(try current?.plaud.map { URL(fileURLWithPath:$0.directory) } ?? store.folder(id)) } catch { self.error = error.localizedDescription }
 }
 func export() {
  guard current != nil else { return }
  let panel = NSSavePanel(); panel.nameFieldStringValue = "会议记录.md"
  guard panel.runModal() == .OK, let url = panel.url else { return }
  do { try exportText().write(to:url,atomically:true,encoding:.utf8) }
  catch { self.error = error.localizedDescription }
 }
 func qaSources() -> [QASource] {
  guard let current else { return [] }; return QAEvidence.sources(meeting:current,realtime:transcripts)
 }
 func askQuestion(_ retry: String? = nil, replacing retryID: String? = nil) {
  let value = (retry ?? question).trimmingCharacters(in:.whitespacesAndNewlines)
  guard !qaBusy && !busy && !postProcessing, current != nil else { return }
  guard !value.isEmpty, value.count <= 1000 else { error = "问题需为1至1000个字符"; return }
  qaBusy = true; if retry == nil { question = "" }; showingQA = true
  let sources = qaSources()
  var entry = QAEntry(question:value,status:"正在检索",sourceDigest:QAEvidence.digest(sources),coverage:"仅本场会议原文和笔记；不使用AI纪要或其他会议。")
  if transcripts.contains(where:{$0.gap || !$0.final}) { entry.coverage += " 实时稿存在缺失或未确认片段，答案可能不完整。" }
  if let retryID, let index = current?.questions?.firstIndex(where:{$0.id == retryID && !$0.supported}) {
   entry.id = retryID
   current?.questions?[index] = entry
  } else { current?.questions = (current?.questions ?? []) + [entry] }
  save()
  let entryID = entry.id
  qaTask = Task {
   let service = MeetingQAService()
   defer { qaBusy = false; qaProgress = ""; save() }
   do {
    let answer: QAAnswer
    if sources.isEmpty { answer = QAAnswer() }
    else { answer = try await service.answer(question:value,sources:sources,configuration:LLMConfiguration.load(),progress:{ [weak self] message in await self?.updateQAProgress(message) }) }
    try Task.checkCancellation()
    if let index = current?.questions?.firstIndex(where:{$0.id == entryID}) {
     current?.questions?[index].references = answer.references; current?.questions?[index].supported = !answer.references.isEmpty
     current?.questions?[index].points = answer.points
     current?.questions?[index].status = answer.references.isEmpty ? "本场资料不足以回答这个问题。可以换个问法，或补充笔记后再问。" : "根据本场原文归纳"
    }
   } catch {
    if let index = current?.questions?.firstIndex(where:{$0.id == entryID}) { current?.questions?[index].status = Task.isCancelled ? "已取消，可重试" : "问答失败：" + error.localizedDescription }
   }
   await service.close()
  }
 }
 private func updateQAProgress(_ message: String) { qaProgress = message }
 func cancelQA() { qaTask?.cancel() }
 func citationChanged(_ entry: QAEntry) -> Bool { entry.sourceDigest != QAEvidence.digest(qaSources()) }
 func openCitation(_ ref: QAReference) {
  reviewQuery = ""; reviewSpeaker = "all"
  guard qaSources().contains(where:{$0.id == ref.source.id}) else { sourcePreview = ref; return }
  if ref.source.kind == "notes" { sourcePreview = ref }
  else { detailPage = "转写"; showingFinal = ref.source.kind == "final"; focusedSentence = ref.source.target; citationScrollToken = UUID() }
 }
 func startBatchMinutes(_ selected: [Meeting], template: MinutesTemplate) {
  guard canDelete, !selected.isEmpty, let store else { return }
  if let existing = batchJob, !existing.pending.isEmpty || !existing.failures.isEmpty { error = "已有未完成的批量任务，请先继续任务或重试失败项。"; return }
  let job = BatchJob(template:template,pending:selected.map(\.id))
  do { try job.save(root:store.root); batchJob = job; resumeBatchMinutes() }
  catch { self.error = error.localizedDescription }
 }
 func retryBatchFailures() {
  guard canDelete, var job = batchJob, let store else { return }
  job.retryFailures()
  do { try job.save(root:store.root); batchJob = job; resumeBatchMinutes() } catch { self.error = error.localizedDescription }
 }
 func resumeBatchMinutes() {
  guard canDelete, let initial = batchJob, !initial.pending.isEmpty, let store else { return }
  batchRunning = true; batchFailures = Array(initial.failures.values).sorted(); batchProgress = "准备继续批量总结…"
  batchTask = Task {
   defer { batchRunning = false; reload() }
   var job = initial
   do {
    let configuration = try LLMConfiguration.load()
    let backup = store.root.appendingPathComponent("SummaryBackups").appendingPathComponent(job.id)
    try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:true)
    while let id = job.pending.first {
     try Task.checkCancellation()
     guard let original = try store.list().first(where:{$0.id == id}), let post = original.post, !post.sentences.isEmpty else {
      job.pending.removeFirst(); job.skipped.append(id); try job.save(root:store.root); batchJob = job; continue
     }
     // Meeting and marker commit in one SQLite transaction; a crash before checkpoint never regenerates it.
     if original.summaryBatchID == job.id {
      job.pending.removeFirst(); job.completed.append(id); try job.save(root:store.root); batchJob = job; continue
     }
     let service = MinutesService()
     do {
      let file = backup.appendingPathComponent(id+".json")
      if !FileManager.default.fileExists(atPath:file.path) { try JSONEncoder().encode(original).write(to:file,options:.atomic) }
      let prefix = "批量总结 · 已完成 \(job.completed.count)，剩余 \(job.pending.count) · \(original.title)"
      batchProgress = prefix
      var lines = post.sentences.map { EvidenceLine(id:$0.id,text:"[\($0.timeLabel)] \(post.name($0.speaker))：\($0.text)") }
      if !original.noteText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { lines.append(EvidenceLine(id:"N1",text:"用户笔记（可能含建议，不能自动视为决策）："+original.noteText)) }
      let result = try await service.generate(lines:lines,configuration:configuration,template:job.template,progress:{ [weak self] message in await self?.setBatchProgress(prefix+" · "+message) })
      try Task.checkCancellation()
      var updated = original
      updated.summaryBatchID = job.id
      updated.keywords = await service.generatedKeywords; updated.keywordsGeneratedAt = Date()
      updated.post?.minutes = result; updated.post?.minutesTemplate = job.template; updated.post?.minutesModel = configuration.model
      updated.post?.minutesBasis = lines.map { $0.id+":"+$0.text }.joined(separator:"\n")
      if let title = await service.generatedTitle { updated.title = title }
      updated.post?.status = "会后处理完成 · 纪要待核对"
      try store.save(updated)
      if current?.id == updated.id { current = updated }
      job.completed.append(id); reload()
     } catch is CancellationError { await service.close(); throw CancellationError() }
     catch { job.failures[id] = original.title+"："+error.localizedDescription }
     await service.close()
     job.pending.removeFirst(); try job.save(root:store.root); batchJob = job; batchFailures = Array(job.failures.values).sorted()
    }
    batchProgress = "批量完成：成功 \(job.completed.count)，失败 \(job.failures.count)，跳过 \(job.skipped.count)"
   } catch is CancellationError { batchProgress = "已暂停：完成 \(job.completed.count)，剩余 \(job.pending.count)；可继续任务" }
   catch { batchProgress = "批量中断，可继续："+error.localizedDescription }
  }
 }
 private func setBatchProgress(_ message: String) { batchProgress = message }
 func cancelBatchMinutes() { batchTask?.cancel() }
 var meetingTemplate: MinutesTemplate { current?.preferredMinutesTemplate ?? current?.post?.minutesTemplate ?? MinutesTemplate.selected() }
 func chooseMeetingTemplate(_ template: MinutesTemplate) {
  guard !recording && !postProcessing && !currentSummaryLocked else { return }
  current?.preferredMinutesTemplate = template; save()
 }
 var generateLabel: String {
  if postProcessing && postMeetingID == current?.id { return "生成中…" }
  if currentSummaryLocked { return "等待生成…" }
  let status = current?.post?.status ?? ""
  if status.hasPrefix("处理失败") || status.contains("可重试") { return "重试生成" }
  if current?.post?.sentences.isEmpty ?? true { return "转写并生成总结" }
  return current?.post?.minutes.isEmpty == false ? "更新总结" : "生成总结"
 }
 func openSpeakerReview() {
  detailPage = "转写"; showingFinal = true; speakerPanelVisible = true; showingQA = false
 }
 func openSummarySources(_ ids: [String], text: String, selected: String? = nil) {
  summaryReferenceIDs = ids.filter { id in id == "N1" || current?.post?.sentences.contains(where:{$0.id == id}) == true }
  guard !summaryReferenceIDs.isEmpty else { error = "原文片段已不可用"; return }
  summaryReferenceText = text; summaryReferenceIndex = selected.flatMap { summaryReferenceIDs.firstIndex(of:$0) } ?? 0
  summarySourcesVisible = true; showingQA = false; detailPage = "总结"; focusSummarySource()
 }
 func focusSummarySource() {
  guard summaryReferenceIDs.indices.contains(summaryReferenceIndex) else { return }
  reviewQuery = ""; reviewSpeaker = "all"; showingFinal = true
  focusedSentence = summaryReferenceIDs[summaryReferenceIndex]; citationScrollToken = UUID()
 }
 func requestSummary() {
  guard !recording && !busy && !postProcessing && !qaBusy && !currentSummaryLocked, current != nil else { return }
  showingGeneration = true
 }
 func startPostMeeting(onlyMinutes: Bool = false, forceNew: Bool = false, reviewBeforeSummary: Bool = false) {
  if postProcessing, current?.id != postMeetingID, !onlyMinutes, !recording {
   if current?.post == nil { current?.post = PostRecord() }; current?.post?.status = "等待后台会后处理"; save(); return
  }
  guard !recording && !busy && !postProcessing && !qaBusy && !currentSummaryLocked, current != nil else { return }
  flushNotes()
  showingGeneration = false
  postProcessing = true
  postMeetingID = current?.id
  let target = current!
  postTask = Task { await processMeeting(meeting:target,onlyMinutes:onlyMinutes,forceNew:forceNew,reviewBeforeSummary:reviewBeforeSummary) }
 }
 func cancelPostMeeting() { postTask?.cancel(); keywordBackfillTask?.cancel() }
 func updateMinutes(_ text: String) {
  if current?.post == nil { current?.post = PostRecord() }
  current?.post?.minutes = text; save()
 }
 func correctSentence(meetingID: String, id: String, text: String) throws {
  guard var updated = current, updated.id == meetingID, !recording, !postProcessing, !currentSummaryLocked, !qaBusy,
        let index = updated.post?.sentences.firstIndex(where:{$0.id == id}), let store else { throw AppFailure(message:"会议正在处理中，请稍后再编辑") }
  let clean = text.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !clean.isEmpty else { throw AppFailure(message:"转写内容不能为空") }
  try updated.post?.sentences[index].correct(clean)
  try store.save(updated); current = updated; reload()
 }
 func renameSpeaker(_ speaker: Int, to name: String) {
  guard !recording, !postProcessing, !currentSummaryLocked, !qaBusy else { return }
  let clean = name.trimmingCharacters(in:.whitespacesAndNewlines)
  if clean.isEmpty { current?.post?.speakerNames.removeValue(forKey:String(speaker)) }
  else { current?.post?.speakerNames[String(speaker)] = clean }
  save()
 }
 private func processMeeting(meeting: Meeting, onlyMinutes: Bool, forceNew: Bool, reviewBeforeSummary: Bool = false) async {
  guard let store else { return }
  var working = meeting
  func persist() { do { try store.save(working); if current?.id == working.id { current = working }; reload() } catch { self.error = error.localizedDescription } }
  postProcessing = true
  if working.post == nil { working.post = PostRecord() }
  defer {
   persist(); postProcessing = false; postMeetingID = nil; postProgress = ""
   if !recording && !busy, let queued = (try? store.list())?.first(where:{$0.post?.status == "等待后台会后处理"}) {
    postProcessing = true; postMeetingID = queued.id
    postTask = Task { await processMeeting(meeting:queued,onlyMinutes:false,forceNew:false) }
   }
  }
  let asr = OfflineASR(); let llm = MinutesService()
  let template = working.preferredMinutesTemplate ?? working.post?.minutesTemplate ?? MinutesTemplate.selected()
  let repairWithoutMinutes = working.automaticRepair == true && !(UserDefaults.standard.object(forKey:"autoPostMeeting") as? Bool ?? true)
  do {
   if !onlyMinutes && (forceNew || working.post?.sentences.isEmpty != false) {
    let c = try OfflineConfiguration.load()
    let canResume = !forceNew && working.post?.taskID != nil && working.post?.submitted.map { Date().timeIntervalSince($0) < 86400 } == true
    let task: String; let base: URL
    if canResume {
     task = working.post!.taskID!; base = try PrivateHTTP.endpoint(working.post?.taskBase ?? c.base.absoluteString)
    } else {
     postProgress = "准备单声道录音…"; working.post?.status = postProgress; persist()
     let folder = try store.folder(meeting.id)
     let imported = store.importedAudio(for:meeting)
     if meeting.plaud != nil && imported == nil { throw AppFailure(message:"Plaud 原始录音已移动或缺失；仍可基于已导入转写重生成纪要") }
     let mix = try await Task.detached { try MeetingMix.make(folder:folder,imported:imported) }.value
     try Task.checkCancellation()
     working.post?.warning = mix.warning + (meeting.plaud == nil ? " 混音中的重叠人声可能造成漏字或编号错误；请结合实时保留稿核对。" : " 重叠人声可能造成漏字或编号错误，请结合原录音核对；Plaud 来源文件保留。")
     postProgress = "上传百炼临时 OSS…"; working.post?.status = postProgress; persist()
     task = try await asr.submit(file:mix.url,configuration:c); base = c.base
     working.post?.taskID = task; working.post?.taskBase = base.absoluteString
     working.post?.submitted = Date(); working.post?.uploaded = Date(); persist()
    }
    postProgress = "会后识别与说话人分离中…"; working.post?.status = postProgress; persist()
    let sentences = try await asr.result(task:task,base:base,key:c.key)
    try Task.checkCancellation()
    // Commit the complete final draft only after a successful result. Realtime rows never change.
    working.post?.sentences = sentences; working.post?.taskID = nil; working.post?.completed = Date()
    working.post?.speakerNumberOffset = 1
    working.post?.speakerNames = [:] // New clustering numbers cannot inherit old human identities.
    working.post?.status = "说话人稿已保存"
    if working.automaticRepair == true { working.automaticRepair = false; working.repairAfter = nil; working.repairAttempts = nil; working.status = working.audioCaptureIncomplete == true ? "已结束 · 音源有缺失，已转写现有录音" : "已结束 · 会后转写已补齐" }
    if working.audioCaptureIncomplete == true { working.post?.warning += " 采集期间存在音源缺失；会后仅转写已保存的录音，未采集到的声音无法恢复。" }
    if !sentences.contains(where:{$0.speaker != nil}) { working.post?.warning += " 服务未返回说话人编号，不能据此区分说话人。" }
    if current?.id == working.id { showingFinal = true }; persist()
   }
   if reviewBeforeSummary {
    working.post?.status = "转写完成 · 待核对发言人"
    if current?.id == working.id { summaryAfterSpeakerReview = true; openSpeakerReview() }
    await asr.close(); await llm.close(); return
   }
   if repairWithoutMinutes { await asr.close(); await llm.close(); return }
   guard let post = working.post, !post.sentences.isEmpty else { throw AppFailure(message:"请先完成会后识别，再生成纪要") }
   let lines = evidenceLines(for:working)
   let c = try LLMConfiguration.load()
   let result = try await llm.generate(lines:lines,configuration:c,template:template,progress: { [weak self] message in await self?.setPostProgress(message) })
   try Task.checkCancellation()
   working.post?.minutesTemplate = template; working.post?.minutesModel = c.model
   if let title = await llm.generatedTitle { working.title = title }
   working.keywords = await llm.generatedKeywords; working.keywordsGeneratedAt = Date()
   working.post?.minutes = result; working.post?.minutesBasis = lines.map { $0.id+":"+$0.text }.joined(separator:"\n")
   working.post?.status = "会后处理完成 · 纪要待核对"
   if working.plaud != nil { working.status = "Plaud · 已完成" }
   else if working.mediaFile != nil { working.status = "媒体 · 已完成" }
   persist()
  } catch is CancellationError {
   working.automaticRepair = false; working.repairAfter = nil
   working.post?.status = "已停止等待 · 可重试" // Server task may continue; ID remains resumable.
  } catch {
   if working.automaticRepair == true && RepairRetryPolicy.isTransient(error) {
    working.repairAttempts = (working.repairAttempts ?? 0)+1
    working.repairAfter = Date().addingTimeInterval(RepairRetryPolicy.delay(working.repairAttempts ?? 1))
    working.post?.status = "等待网络恢复 · 将自动补齐转写"
   } else {
    working.automaticRepair = false
    working.post?.status = "处理失败 · " + error.localizedDescription
    self.error = error.localizedDescription
   }
  }
  await asr.close(); await llm.close()
 }
 private func setPostProgress(_ message: String) { postProgress = message }
 func evidenceLines() -> [EvidenceLine] { evidenceLines(for:current) }
 private func evidenceLines(for meeting: Meeting?) -> [EvidenceLine] {
  var lines = (meeting?.post?.sentences ?? []).map { EvidenceLine(id:$0.id,text:"[\($0.timeLabel)] \(meeting?.post?.name($0.speaker) ?? "")：\($0.text)") }
  if let notes = meeting?.noteText, !notes.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { lines.append(EvidenceLine(id:"N1",text:"用户笔记（可能含建议，不能自动视为决策）："+notes)) }
  return lines
 }
 private func evidenceBasis() -> String { evidenceLines().map { $0.id+":"+$0.text }.joined(separator:"\n") }
 var minutesStale: Bool { guard let p = current?.post, !p.minutes.isEmpty else { return false }; return p.minutesBasis != evidenceBasis() }
 func exportText() -> String {
  guard let current else { return "" }
  let realtime = transcripts.map { "[\($0.timeLabel)] \($0.sourceLabel)\($0.gap ? "【缺失警告】" : $0.final ? "" : "【未确认】")：\($0.text)" }.joined(separator:"\n\n")
  let post = current.post ?? PostRecord()
  let final = post.sentences.map { "<a id=\"\($0.id)\"></a>\n[\($0.id) · \($0.timeLabel)] \(post.name($0.speaker))：\($0.text)" }.joined(separator:"\n\n")
  return "# \(current.title)\n\n\(current.started.formatted())\n\n## 笔记\n\n<a id=\"N1\"></a>\n\(current.noteText)\n\n## 会后处理\n\n\(post.status)\n\n\(post.warning)\n\n\(minutesStale ? "注意：原文或笔记已更新，纪要需要重新核对。" : "")\n\n\(post.minutes)\n\n## 说话人稿\n\n\(final)\n\n## 实时转写（保留稿）\n\n\(realtime)\n"
 }
 // Explicit development verification entrypoint, using the same resampler, stream and persistence.
 func runLaunchVerificationIfRequested() {
  guard !didLaunchVerification else { return }; didLaunchVerification = true
  let args = CommandLine.arguments
  if let index = args.firstIndex(of:"--verify-post-meeting"), args.indices.contains(index+1), let meeting = meetings.first(where:{$0.id == args[index+1]}) {
   select(meeting); startPostMeeting(); return
  }
  guard let index = args.firstIndex(of:"--verify-asr-file"), args.indices.contains(index+1) else { return }
  let url = URL(fileURLWithPath:args[index+1])
  fileTask = Task { await verifyFile(url) }
 }
 private func verifyFile(_ url: URL) async {
  guard !recording && !busy, let store else { return }
  new(); current?.title = "真实 API 验证 · " + url.lastPathComponent
  busy = true
  do {
   let file = try AVAudioFile(forReading:url)
   guard file.length > 0, Double(file.length)/file.processingFormat.sampleRate <= 120 else { throw AppFailure(message:"验证文件必须含有效音频，且不超过 120 秒") }
   if CommandLine.arguments.contains("--verify-recovery") || CommandLine.arguments.contains("--verify-network") { try await prepareLiveASR() } else { try await prepareASR(ASRConfiguration.load(),sources:["system","microphone"]) }
   origin = ProcessInfo.processInfo.systemUptime; current?.started = Date(); current?.status = "录音中"
   try capture.writer.begin(folder:try store.folder(current!.id),origin:origin)
   recordingMeeting = current; recordingTranscripts = transcripts
   save(); recording = true; busy = false; filePlaybackStopping = false
   for session in liveSessions.values { await session.start() }
   var interrupted = false
   let capacity = AVAudioFrameCount(file.processingFormat.sampleRate/10)
   while file.framePosition < file.length && !Task.isCancelled && recording && !filePlaybackStopping {
    let position = file.framePosition
    if CommandLine.arguments.contains("--verify-recovery"), !interrupted, Double(position)/file.processingFormat.sampleRate >= 4 { interrupted = true; await liveSessions["system"]?.interruptForVerification() }
    let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:capacity)!
    try file.read(into:buffer)
    // Send identical known test material through both independent pipelines, clearly labeled.
    for source in ["system","microphone"] { capture.writer.append(buffer,source:source,hostSeconds:origin+Double(position)/file.processingFormat.sampleRate) }
    try await Task.sleep(nanoseconds:UInt64(Double(buffer.frameLength)/file.processingFormat.sampleRate*1_000_000_000))
   }
   if recording && !busy { await stop() }
  } catch {
   self.error = error.localizedDescription; busy = false
   if recording { await stop() } else { await finishASR(); current?.status = "验证失败"; save() }
  }
 }
}
