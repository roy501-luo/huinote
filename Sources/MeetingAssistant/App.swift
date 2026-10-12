import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
 var model: Model?
 func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
 func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
  guard let model, model.recording || model.busy || model.postProcessing || model.qaBusy else { return .terminateNow }
  if model.busy || model.postProcessing || model.qaBusy { return .terminateCancel }
  Task { @MainActor in await model.stop(runPostProcessing:false); NSApp.reply(toApplicationShouldTerminate:true) }
  return .terminateLater
 }
}
@main struct MeetingAssistantApp: App {
 @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
 @StateObject private var model = Model()
 var body: some Scene {
  Window("会议助手",id:"main") {
   ContentView().environmentObject(model).frame(minWidth:1080,minHeight:640)
    .onAppear { delegate.model = model; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true); model.runLaunchVerificationIfRequested() }
  }.defaultSize(width:1180,height:780)
  Settings { SettingsView() }
 }
}
struct ContentView: View {
 @StateObject private var playback = MeetingPlayback()
 @State private var deletion: [Meeting] = []
 private var selecting: Bool { !selectedIDs.isEmpty }
 @State private var selectedIDs = Set<String>()
 @EnvironmentObject var model: Model
 var body: some View {
  NavigationSplitView {
   VStack(alignment:.leading,spacing:16) {
    HStack { Text("会议资料库").font(.headline).help("会议助手 " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")); Spacer(); Button(action:model.new) { Image(systemName:"plus") }.help("新建会议").disabled(!model.canCreateMeeting) }
    Button("全部文件",systemImage:"square.grid.2x2") { model.showingLibrary = true; playback.pause() }.buttonStyle(.plain)
    TextField("全文搜索 · 标题、日期、正文",text:$model.query).textFieldStyle(.roundedBorder)
    List(model.meetings) { meeting in
     HStack {
     Button { model.select(meeting) } label: {
      VStack(alignment:.leading,spacing:6) {
       SearchHighlight(text:meeting.title,query:model.query).fontWeight(.medium).lineLimit(1)
       Text(meeting.started.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
       Text(meeting.status).font(.caption2).foregroundStyle(.secondary)
       if let hit = model.searchHits[meeting.id] { SearchHighlight(text:"\(hit.label)：\(hit.excerpt)",query:model.query).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
      }.padding(.vertical,5).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
     }.buttonStyle(.plain).disabled(model.recording || model.busy || model.qaBusy)
     .contextMenu {
      Button(selecting ? "退出多选" : "多选") { selectedIDs = selecting ? [] : [meeting.id]; model.showingLibrary = true; playback.pause() }.disabled(!model.canDelete)
      Button("删除会议…",role:.destructive) { deletion = [meeting] }.disabled(!model.canDelete)
     }
     }
    }.listStyle(.sidebar)
     .onChange(of:model.meetings.map(\.id)) { _,ids in selectedIDs.formIntersection(Set(ids)) }
    Menu("同步 Plaud") {
     Button("导入本地 Plaud 纪要") { model.syncPlaud() }
     Button("选择本地纪要目录…") { model.choosePlaudDirectory() }
     Button("从 Plaud 下载新录音") { model.syncPlaud(download:true) }
     Button("Plaud 登录") { model.syncPlaud(login:true) }
    }.disabled(model.recording || model.busy || model.postProcessing || model.qaBusy)
    if !model.plaudProgress.isEmpty { Text(model.plaudProgress).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
    SettingsLink { Label("设置",systemImage:"gearshape") }
   }.padding().navigationSplitViewColumnWidth(240)
  } detail: {
   if model.showingLibrary {
    MeetingLibraryView(selectedIDs:$selectedIDs,deletion:$deletion)
   } else {
   VStack(spacing:0) {
    HStack(spacing:16) {
     Button { model.showingLibrary = true; playback.pause() } label: { Image(systemName:"chevron.left") }.buttonStyle(.plain).help("返回全部文件")
     VStack(alignment:.leading,spacing:5) {
      TextField("会议标题",text:Binding(get:{model.current?.title ?? "会议助手"},set:{model.current?.title = $0; model.save()})).font(.title2.bold()).textFieldStyle(.plain).disabled(model.current == nil || model.currentSummaryLocked || model.qaBusy)
      Text(model.batchRunning ? "批量总结在后台处理中" : model.busy && !model.plaudProgress.isEmpty ? model.plaudProgress : model.busy ? (model.recording ? "正在停止录音并收齐尾部结果…" : "正在连接与启动…") : model.current?.status ?? "新建会议，开始记录").font(.caption).foregroundStyle(.secondary)
     }
     Spacer()
     Text(duration(model.elapsed)).monospacedDigit().font(.title3)
     Button(model.recording ? "结束会议" : "开始会议",systemImage:model.recording ? "stop.fill" : "record.circle") {
      Task { if model.recording { await model.stop() } else { await model.start() } }
     }.buttonStyle(.borderedProminent).tint(model.recording ? .red : .accentColor).disabled(model.busy || model.qaBusy || model.store == nil || model.currentSummaryLocked)
    }.padding(24)
    if model.recording || (model.busy && !model.batchRunning) { HStack(spacing:24) {
     health("系统音频",model.system)
     health("麦克风",model.microphone)
     Spacer()
     Text(model.asrSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(model.asrSummary)
    }.padding(.horizontal,24).padding(.bottom,16) }
    Divider()
    HStack(spacing:0) {
     VStack(alignment:.leading,spacing:18) {
      HStack(spacing:24) {
       ForEach(["转写","总结","笔记"],id:\.self) { page in
        Button { model.detailPage = page } label: {
         VStack(spacing:10) { Text(page).font(.headline).foregroundStyle(model.detailPage == page ? Color.primary : Color.secondary); Rectangle().fill(model.detailPage == page ? Color.accentColor : Color.clear).frame(height:2) }
        }.buttonStyle(.plain).fixedSize(horizontal:true,vertical:false)
       }
       Spacer()
       Button { model.showingQA.toggle() } label: { Label(model.showingQA ? "收起问答" : "本场问答",systemImage:"sparkles") }.buttonStyle(.bordered)
       Menu { Button("查看录音文件",action:model.showFiles); Button("导出 Markdown",action:model.export); Divider(); Button("删除会议…",role:.destructive) { if let current = model.current { deletion = [current] } } } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(model.current == nil || !model.canDelete)
      }
      MeetingPlayerView()
      if model.detailPage == "转写" {
       HStack {
        Text(model.showingFinal ? "说话人转写" : "实时转写").font(.headline)
        Spacer()
        Picker("稿件",selection:$model.showingFinal) { Text("实时保留稿").tag(false); Text("说话人稿").tag(true) }.labelsHidden().frame(width:150)
       }
       if model.showingFinal { FinalTranscriptView() } else { TranscriptView() }
      } else if model.detailPage == "总结" { PostMeetingView() }
      else {
       HStack { Label("会议笔记",systemImage:"square.and.pencil").font(.headline); Spacer(); Text("自动保存").font(.caption).foregroundStyle(.secondary) }
       TextEditor(text:Binding(get:{model.current?.notes ?? ""},set:{model.current?.notes = $0; model.save()})).font(.body).scrollContentBackground(.hidden).padding(8).background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:10)).disabled(model.current == nil || model.currentSummaryLocked || model.qaBusy)
      }
     }.padding(24).frame(minWidth:360,maxWidth:.infinity,maxHeight:.infinity)
     if model.showingQA {
      Divider()
      VStack(alignment:.leading,spacing:18) {
       HStack { Label("本场问答",systemImage:"sparkles").font(.headline); Spacer(); Button { model.showingQA = false } label: { Image(systemName:"xmark") }.buttonStyle(.plain).help("收起问答") }
       MeetingQAView()
      }.padding(20).frame(width:320).frame(maxHeight:.infinity).background(Color(nsColor:.controlBackgroundColor))
     }
    }.environmentObject(playback)

   }
   }
  }
  .onAppear { configurePlayback() }
  .onChange(of:model.current?.id) { _,_ in configurePlayback() }
  .onChange(of:model.recording) { _,recording in configurePlayback(); if recording { model.detailPage = "转写" } }
  .onChange(of:model.postProcessing) { _,processing in if processing { playback.reset() } }
  .onDisappear { playback.reset() }
  .sheet(isPresented:Binding(get:{!deletion.isEmpty},set:{if !$0 { deletion = [] }})) {
   VStack(alignment:.leading,spacing:16) {
    Text("删除这 \(deletion.count) 场会议？").font(.title2.bold())
    Text("将永久删除以下会议的本地录音、转写、笔记、纪要、问答和搜索索引，无法撤销。已导出文件和 Plaud 来源目录保留；百炼临时文件按服务有效期清理。")
    ScrollView { VStack(alignment:.leading,spacing:8) { ForEach(deletion) { meeting in Text(meeting.title + " · " + meeting.started.formatted(date:.abbreviated,time:.shortened)) } }.frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:200)
    HStack { Spacer(); Button("取消") { deletion = [] }.keyboardShortcut(.cancelAction)
     Button("永久删除 \(deletion.count) 场",role:.destructive) { model.deleteMeetings(deletion); selectedIDs = []; deletion = [] }.disabled(!model.canDelete)
    }
   }.padding(24).frame(width:520)
  }
  .sheet(item:$model.sourcePreview) { ref in
   VStack(alignment:.leading,spacing:16) {
    HStack { Text("原文引用 · \(ref.source.label)").font(.headline); Spacer(); Button("关闭") { model.sourcePreview = nil } }
    if !model.qaSources().contains(where:{$0.id == ref.source.id}) { Text("原资料已变更，以下为回答时保存的原文快照，未跳到新的内容。").foregroundStyle(.orange) }
    Text(ref.quote).padding().background(Color.accentColor.opacity(0.12)).textSelection(.enabled)
    Divider()
    ScrollView { Text(ref.source.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
   }.padding(24).frame(width:650,height:500)
  }
  .alert("需要处理",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
 }
 func configurePlayback() {
  let folder = model.current.flatMap { try? model.store?.folder($0.id) }
  let imported = model.current?.plaud.flatMap { PlaudImport.audio(in:URL(fileURLWithPath:$0.directory)) }
  playback.configure(folder:folder,imported:imported,duration:model.current?.duration ?? 0,enabled:model.current != nil && !model.recording)
 }
 func duration(_ seconds: Double) -> String { let value = max(0,Int(seconds)); return String(format:"%02d:%02d:%02d",value/3600,(value/60)%60,value%60) }
 func health(_ title: String,_ value: AudioHealth) -> some View {
  let stale = value.lastReceived.map { model.now.timeIntervalSince($0) > 3 } ?? true
  let text = value.error != nil ? "失败" : (!model.recording ? (value.frames > 0 ? "已保存" : "未采集") : stale ? "等待音频" : value.peak < 0.001 ? "收到音频 · 静音" : "收到音频")
  return HStack(spacing:6) { Circle().fill(value.error != nil ? Color.red : model.recording && !stale ? .green : .gray).frame(width:7,height:7); Text("\(title)：\(text)").font(.caption) }.help(value.error ?? "已保存 \(value.frames) 帧")
 }
}
struct SettingsView: View {
 @AppStorage("plaudDirectory") private var plaudDirectory = PlaudImport.defaultDirectory
 @AppStorage("plaudTool") private var plaudTool = PlaudImport.defaultTool
 @AppStorage("asrEndpoint") private var asrEndpoint = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
 @AppStorage("asrModel") private var asrModel = "fun-asr-realtime"
 @AppStorage("llmBaseURL") private var llmBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
 @AppStorage("llmModel") private var llmModel = "qwen-plus"
 @AppStorage("offlineBaseURL") private var offlineBaseURL = "https://dashscope.aliyuncs.com/api/v1"
 @AppStorage("offlineModel") private var offlineModel = "fun-asr"
 @AppStorage("autoPostMeeting") private var autoPostMeeting = true
 @State private var asrKey = ""
 @State private var llmKey = ""
 @State private var status = ""
 @State private var testing = false
 var body: some View {
  Form {
   Section("百炼 · 北京") {
    Text("会后录音使用百炼临时 OSS，云端文件 48 小时后自动清理。").font(.caption).foregroundStyle(.secondary)
    SecureField("ASR API Key",text:$asrKey)
    TextField("WebSocket Endpoint",text:$asrEndpoint)
    TextField("实时模型",text:$asrModel)
   }
   Section("会后识别 · 使用 ASR Key") {
    TextField("文件识别 Base URL",text:$offlineBaseURL)
    TextField("文件识别模型",text:$offlineModel)
    Toggle("结束后自动上传录音并生成纪要",isOn:$autoPostMeeting)
    Text("仅上传单声道混音；实时稿始终保留。第一版会后处理支持两小时以内录音。临时 OSS 不提供本地可执行的提前删除入口，48 小时后由服务清理。").font(.caption).foregroundStyle(.secondary)
   }
   Section("纪要模型 · OpenAI 兼容接口") {
    SecureField("LLM API Key",text:$llmKey)
    Button("使用上方 ASR Key") { llmKey = asrKey }
    TextField("Base URL",text:$llmBaseURL)
    TextField("模型",text:$llmModel)
   }
   Section("纪要模板") { MinutesTemplateSettings() }
   Section("Plaud 同步") {
    TextField("本地纪要目录",text:$plaudDirectory)
    TextField("原 Plaud 工具目录",text:$plaudTool)
    Text("沿用原工具的 Plaud 登录，仅下载录音；后续使用会议助手的 ASR、模型与模板。现有纪要按文件编号去重导入，不覆盖本机编辑。下载后请选择待处理录音生成纪要。原目录与录音保留。").font(.caption).foregroundStyle(.secondary)
   }
   Section {
    Button("保存密钥到钥匙串") {
     do { try Secrets.save(asrKey,account:"asr"); try Secrets.save(llmKey,account:"llm"); status = "密钥已保存到钥匙串。" }
     catch { status = error.localizedDescription }
    }
    Button("检查钥匙串授权状态") { do { status = try Secrets.checkAccess() } catch { status = error.localizedDescription } }
    Text("密钥由固定签名的 MeetingAssistantKeychain 组件读取。首次迁移时请在系统弹窗选择“始终允许”；后续普通 App 更新会复用该组件。").font(.caption).foregroundStyle(.secondary)
    Button(testing ? "测试中…" : "测试已保存的 ASR 配置") {
     testing = true
     Task { @MainActor in
      let connection = ASRConnection(source:"test")
      defer { Task { await connection.cancel() }; testing = false }
      do {
       try await connection.start(ASRConfiguration.load())
       await connection.send(AudioPacket(data:Data(repeating:0,count:9600),offset:0))
       await connection.finish()
       let state = await connection.state
       let failure = await connection.failure
       status = state == .finished ? "连接、任务启动与结束成功。此测试仅发送静音，不代表中文识别验收。" : failure ?? "测试失败"
      } catch { status = error.localizedDescription }
     }
    }.disabled(testing)
    Text(status).font(.caption).textSelection(.enabled)
    Text("地址与模型自动保存；密钥仅保存到 macOS 钥匙串。开始会议后，两路音频会发送至所配置的百炼实时识别接口；原始录音仍保存在本机。").font(.caption).foregroundStyle(.secondary)
   }
  }.formStyle(.grouped).padding().frame(width:640,height:720)
  .onAppear { do { asrKey = try Secrets.read("asr"); llmKey = try Secrets.read("llm") } catch { status = error.localizedDescription } }
 }
}

struct TranscriptView: View {
 @EnvironmentObject var playback: MeetingPlayback
 @EnvironmentObject var model: Model
 @State private var follow = true
 private var cues: [PlaybackCue] { model.transcripts.filter { !$0.gap }.map { PlaybackCue(id:$0.id,begin:$0.begin,end:$0.end ?? $0.begin+3) } }
 private var active: [String] { guard playback.hasPosition else { return [] }; return PlaybackTimeline.active(cues,at:playback.position) }
 var body: some View {
  VStack(spacing:8) {
   HStack { Text("音源标签不是说话人身份").font(.caption).foregroundStyle(.secondary); Spacer(); Text(follow ? "自动跟随" : "跟随已暂停").font(.caption).foregroundStyle(.secondary) }
   ScrollViewReader { proxy in
    VStack(spacing:8) {
    if !follow { Button("恢复跟随",systemImage:"location.fill") { follow = true; if model.recording { proxy.scrollTo("bottom",anchor:.bottom) } else if let id = PlaybackTimeline.anchor(cues,at:playback.position) { proxy.scrollTo(id,anchor:.center) } } }
    ScrollView {
     LazyVStack(alignment:.leading,spacing:18) {
      if model.transcripts.isEmpty {
       VStack(spacing:14) {
        Image(systemName:"waveform").font(.system(size:36)).foregroundStyle(.tertiary)
        Text(model.recording ? "等待语音识别结果…" : "开始会议后，中文转写会出现在这里")
        Text("临时结果会原位更新，句子确认后自动保存。").font(.caption).foregroundStyle(.secondary)
       }.frame(maxWidth:.infinity).padding(.top,100)
      }
      ForEach(model.transcripts.filter { $0.gap || !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) { item in
       VStack(alignment:.leading,spacing:7) {
        HStack {
         Button { playback.play(at:item.begin) } label: { Text(item.timeLabel).monospacedDigit() }.buttonStyle(.plain).foregroundStyle(Color.accentColor).disabled(model.recording || (model.busy && !model.batchRunning) || model.postProcessing).help("从此处播放")
         Text(item.sourceLabel)
         if active.contains(item.id) && !model.recording { Text("当前播放").foregroundStyle(Color.accentColor) }
         Spacer()
         Text(item.gap ? "转写不完整" : item.final ? "已确认" : model.recording ? "识别中…" : "未最终确认")
        }.font(.caption).foregroundStyle(item.gap ? .orange : .secondary)
        Text(item.text.isEmpty ? "…" : item.text).font(.body).lineSpacing(5).foregroundStyle(item.gap ? .orange : item.final ? .primary : .secondary).textSelection(.enabled)
       }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(item.gap ? Color.orange.opacity(0.07) : ((active.contains(item.id) && !model.recording) || (!playback.playing && model.focusedSentence == item.id) ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.035)),in:RoundedRectangle(cornerRadius:9)).id(item.id)
      }
      Color.clear.frame(height:1).id("bottom")
     }
    }.background(TranscriptScrollObserver { follow = false })
     .onChange(of:active) { _,ids in if follow && !model.recording, let id = ids.first { proxy.scrollTo(id,anchor:.center) } }
     .onChange(of:model.transcripts) { _, _ in if follow && model.recording { proxy.scrollTo("bottom",anchor:.bottom) } }
     .onAppear { if let id = model.focusedSentence { follow = false; proxy.scrollTo(id,anchor:.center) } else if playback.hasPosition, let id = PlaybackTimeline.anchor(cues,at:playback.position) { proxy.scrollTo(id,anchor:.center) } }
     .onChange(of:model.citationScrollToken) { _,_ in follow = false; if let id = model.focusedSentence { proxy.scrollTo(id,anchor:.center) } }
    }
   }
  }.frame(maxWidth:.infinity,maxHeight:.infinity).onChange(of:model.current?.id) { _,_ in follow = true }
 }
}

struct PostMeetingView: View {
 @EnvironmentObject var model: Model
 @State private var editing = false
 @State private var choosingTemplate = false
 @State private var showDetails = false
 @AppStorage("minutesTemplateID") private var selectedTemplate = "general"
 private var locked: Bool { model.recording || model.busy || model.postProcessing || model.qaBusy }
 var body: some View {
  VStack(alignment:.leading,spacing:0) {
   HStack(spacing:12) {
    Button { choosingTemplate = true } label: { Label(MinutesTemplate.all().first(where:{$0.id == selectedTemplate})?.name ?? "通用会议",systemImage:"square.grid.2x2").lineLimit(1) }.help("选择下次生成的模板").disabled(locked)
    if model.postProcessing { ProgressView().controlSize(.small); Button("停止等待",action:model.cancelPostMeeting) }
    else { Button(model.current?.post?.minutes.isEmpty == false ? "重新生成" : "生成总结") { model.startPostMeeting(onlyMinutes:!(model.current?.post?.sentences.isEmpty ?? true)) }.disabled(locked) }
    Spacer()
    Button { editing.toggle() } label: { Label(editing ? "完成编辑" : "编辑",systemImage:editing ? "checkmark" : "square.and.pencil") }.disabled(locked)
    Menu { Button("导出 Markdown",action:model.export); Button("处理详情") { showDetails.toggle() }; Divider(); Button("重新识别录音与说话人") { model.startPostMeeting(forceNew:true) }.disabled(locked) } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).frame(width:28)
   }.buttonStyle(.borderless).padding(.horizontal,12).padding(.vertical,12)
   if model.postProcessing { Text(model.postProgress).font(.caption).foregroundStyle(.secondary).padding(.horizontal,12).padding(.bottom,8) }
   if model.batchRunning { Text("批量生成中 · 可继续阅读和播放，编辑将在任务结束后恢复").font(.caption).foregroundStyle(.secondary).padding(.horizontal,12).padding(.bottom,8) }
   if model.minutesStale { Text("原文或笔记已更新，请重新核对总结。").font(.caption).foregroundStyle(.orange).padding(12) }
   if showDetails {
    VStack(alignment:.leading,spacing:6) { Text(model.current?.post?.status ?? "尚未生成"); if let warning = model.current?.post?.warning, !warning.isEmpty { Text(warning) }; Text("更换模板后，点击重新生成应用。已有总结的模板显示在会议信息中。") }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(12)
   }
   Divider()
   if editing { TextEditor(text:Binding(get:{model.current?.post?.minutes ?? ""},set:model.updateMinutes)).font(.system(size:15)).lineSpacing(7).padding(20).disabled(locked) }
   else { ScrollView { if let meeting = model.current { SummaryDocument(meeting:meeting) } }
    .environment(\.openURL,OpenURLAction { url in
     guard let id = url.fragment else { return .discarded }
     if id == "N1" { model.detailPage = "笔记" }
     else if model.current?.post?.sentences.contains(where:{$0.id == id}) == true { model.detailPage = "转写"; model.showingFinal = true; model.focusedSentence = id; model.citationScrollToken = UUID() }
     return .handled
    })
   }
  }.frame(maxHeight:.infinity).sheet(isPresented:$choosingTemplate) { TemplateGallery() }.onChange(of:model.current?.id) { _,_ in editing = false }
 }
}
struct FinalTranscriptView: View {
 @EnvironmentObject var playback: MeetingPlayback
 @EnvironmentObject var model: Model
 @State private var follow = true
 private var cues: [PlaybackCue] { (model.current?.post?.sentences ?? []).map { PlaybackCue(id:$0.id,begin:$0.begin,end:$0.end) } }
 private var active: [String] { guard playback.hasPosition else { return [] }; return PlaybackTimeline.active(cues,at:playback.position) }
 var body: some View {
  ScrollViewReader { proxy in
   VStack(alignment:.leading,spacing:12) {
    HStack { Text(follow ? "自动跟随播放" : "跟随已暂停 · 可自由浏览").font(.caption).foregroundStyle(.secondary); Spacer(); if !follow { Button("恢复跟随",systemImage:"location.fill") { follow = true; if let id = PlaybackTimeline.anchor(cues,at:playback.position) { proxy.scrollTo(id,anchor:.center) } } } }
   ScrollView {
    LazyVStack(alignment:.leading,spacing:16) {
     if model.current?.post?.sentences.isEmpty ?? true { Text("会后识别完成后，带说话人编号的句子将显示在这里。实时稿仍可切换查看。").foregroundStyle(.secondary) }
     ForEach(model.current?.post?.sentences ?? []) { sentence in
      VStack(alignment:.leading,spacing:8) {
       HStack {
        Button { follow = true; playback.play(at:sentence.begin); model.focusedSentence = nil } label: { Text("\(sentence.timeLabel)").monospacedDigit() }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption).disabled(model.recording || (model.busy && !model.batchRunning) || model.postProcessing).help("从此处播放")
        if let speaker = sentence.speaker {
         TextField("说话人 \(speaker+1)",text:Binding(get:{model.current?.post?.name(speaker) ?? ""},set:{model.renameSpeaker(speaker,to:$0)})).textFieldStyle(.plain).font(.caption.bold()).disabled(model.postProcessing || model.batchRunning).help("手动命名此说话人；编号不代表真实身份")
        } else { Text("说话人未识别").font(.caption) }
        Spacer()
        Text(active.contains(sentence.id) ? "当前播放" : "").font(.caption2).foregroundStyle(Color.accentColor).frame(width:55)
       }
       Text(sentence.text).textSelection(.enabled).lineSpacing(5)
      }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(active.contains(sentence.id) || (!playback.playing && model.focusedSentence == sentence.id) ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9)).id(sentence.id)
     }
    }
   }.background(TranscriptScrollObserver { follow = false })
    .onChange(of:active) { _,ids in if follow, let id = ids.first { proxy.scrollTo(id,anchor:.center) } }
    .onAppear { if let id = model.focusedSentence { follow = false; proxy.scrollTo(id,anchor:.center) } else if playback.hasPosition, let id = PlaybackTimeline.anchor(cues,at:playback.position) { proxy.scrollTo(id,anchor:.center) } }
    .onChange(of:model.focusedSentence) { _,id in if let id { proxy.scrollTo(id,anchor:.center) } }
    .onChange(of:model.citationScrollToken) { _,_ in follow = false; if let id = model.focusedSentence { proxy.scrollTo(id,anchor:.center) } }
   }.onChange(of:model.current?.id) { _,_ in follow = true }
  }
 }
}

struct MeetingQAView: View {
 @EnvironmentObject var model: Model
 var body: some View {
  VStack(alignment:.leading,spacing:10) {
   Text("只根据本场原文与笔记回答；每次提问独立。回答采用原文摘录，不补全未知事实。").font(.caption).foregroundStyle(.secondary)
   ScrollView {
    LazyVStack(alignment:.leading,spacing:18) {
     ForEach((model.current?.questions ?? []).reversed()) { entry in
      VStack(alignment:.leading,spacing:10) {
       Text(entry.question).font(.headline).textSelection(.enabled)
       Text(entry.status).foregroundStyle(entry.supported ? Color.primary : Color.secondary).textSelection(.enabled)
       if model.citationChanged(entry) { Text("原资料已更新，此回答基于旧版本，请重新提问核对。").font(.caption).foregroundStyle(.orange) }
       ForEach(entry.references) { ref in
        Button { model.openCitation(ref) } label: {
         VStack(alignment:.leading,spacing:6) {
          Text("\(ref.source.label) · \(ref.source.timeLabel) ↗").font(.caption).foregroundStyle(Color.accentColor)
          Text(ref.quote).font(.body).foregroundStyle(.primary).multilineTextAlignment(.leading)
         }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(Color.accentColor.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
        }.buttonStyle(.plain).help("跳回原文与时间点")
       }
       Text(entry.coverage).font(.caption2).foregroundStyle(.secondary)
       if entry.status != "正在检索" { Button("重新提问") { model.askQuestion(entry.question) }.font(.caption).disabled(model.qaBusy || model.recording || model.busy || model.postProcessing) }
      }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:10))
     }
    }
   }
   Divider()
   TextField("例如：讨论了哪些检查事项？",text:$model.question,axis:.vertical).lineLimit(1...3).textFieldStyle(.roundedBorder).onSubmit { model.askQuestion() }
   HStack {
    if model.qaBusy { ProgressView().controlSize(.small); Text(model.qaProgress).font(.caption); Button("取消") { model.cancelQA() } }
    else { Button("提问") { model.askQuestion() }.buttonStyle(.borderedProminent).disabled(model.question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.current == nil || model.recording || model.busy || model.postProcessing) }
   }
  }.frame(maxHeight:.infinity)
 }
}

struct MinutesTemplatePicker: View {
 @AppStorage("minutesTemplateID") private var selection = "general"
 @AppStorage("minutesTemplates") private var stored = "[]"
 @State private var pendingDeletion: MinutesTemplate?
 var showInstructions = false
 var body: some View {
  let _ = stored
  let current = MinutesTemplate.all().first { $0.id == selection } ?? MinutesTemplate.builtins[0]
  VStack(alignment:.leading,spacing:6) {
   Picker("纪要模板",selection:$selection) {
    ForEach(MinutesTemplate.all()) { item in Text(item.name).tag(item.id) }
   }.contextMenu {
    Button("删除模板",role:.destructive) { pendingDeletion = current }.disabled(MinutesTemplate.builtins.contains(where:{$0.id == current.id}))
   }
   if showInstructions {
    Text("下次生成 · \(current.name)：\(current.instructions)").font(.caption).foregroundStyle(.secondary)
    Text("切换模板后需重新生成；已有纪要保持不变。模板调整侧重与表达，仍保留四类纪要及原文引用。").font(.caption).foregroundStyle(.secondary)
   }
  }.modifier(TemplateDeletionConfirmation(template:$pendingDeletion))
   .onAppear { if !MinutesTemplate.all().contains(where:{$0.id == selection}) { selection = "general" } }
 }
}
struct TemplateDeletionConfirmation: ViewModifier {
 @Binding var template: MinutesTemplate?
 @State private var failure: String?
 func body(content: Content) -> some View {
  content.alert("删除“\(template?.name ?? "")”？",isPresented:Binding(get:{template != nil},set:{if !$0 {template = nil}}),presenting:template) { target in
   Button("取消",role:.cancel) {}
   Button("删除",role:.destructive) { do { try MinutesTemplate.delete(target.id) } catch { failure = error.localizedDescription } }
  } message: { _ in Text("删除后无法撤销，当前选中模板将回退为通用会议。已有纪要及其模板快照保留。") }
  .alert("无法删除",isPresented:Binding(get:{failure != nil},set:{if !$0 {failure = nil}})) { Button("好") { failure = nil } } message: { Text(failure ?? "") }
 }
}
struct MinutesTemplateSettings: View {
 @AppStorage("minutesTemplateID") private var selection = "general"
 @AppStorage("minutesTemplates") private var stored = "[]"
 @State private var draft: MinutesTemplate?
 @State private var pendingDeletion: MinutesTemplate?
 var body: some View {
  let _ = stored
  let _ = selection
  let current = MinutesTemplate.selected()
  VStack(alignment:.leading,spacing:10) {
   MinutesTemplatePicker()
   Text(current.instructions).font(.caption).foregroundStyle(.secondary)
   HStack {
    Button("新增模板") { draft = MinutesTemplate(id:UUID().uuidString,name:"",instructions:"") }
    Button("复制为新模板") { draft = MinutesTemplate(id:UUID().uuidString,name:current.name + "副本",instructions:current.instructions) }
    Button("编辑模板") { draft = current }.disabled(MinutesTemplate.builtins.contains(where:{$0.id == current.id}))
    Button("删除模板",role:.destructive) { pendingDeletion = current }.disabled(MinutesTemplate.builtins.contains(where:{$0.id == current.id}))
   }
   Text("模板可自定义侧重、详略和表达；仍保留总结、决策、行动项、未解决问题及原文引用。保存后用于下次生成，已有纪要不自动改写。请勿填写密钥。").font(.caption).foregroundStyle(.secondary)
  }.modifier(TemplateDeletionConfirmation(template:$pendingDeletion)).sheet(item:$draft) { item in MinutesTemplateEditor(template:item) }
 }
}
struct MinutesTemplateEditor: View {
 @Environment(\.dismiss) private var dismiss
 @State var template: MinutesTemplate
 @State private var error = ""
 var body: some View {
  VStack(alignment:.leading,spacing:14) {
   Text("纪要模板").font(.title2.bold())
   TextField("模板名称（最多40字）",text:$template.name).textFieldStyle(.roundedBorder)
   Text("描述希望重点总结的内容、语气和详细程度（最多4000字）").font(.caption)
   TextEditor(text:$template.instructions).font(.body).frame(minHeight:220)
   if !error.isEmpty { Text(error).foregroundStyle(.red) }
   HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
    Button("保存并选用") { do { try MinutesTemplate.save(template); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent)
   }
  }.padding(24).frame(width:560)
 }
}

struct TemplateGallery: View {
 @Environment(\.dismiss) private var dismiss
 @AppStorage("minutesTemplateID") private var selection = "general"
 @AppStorage("minutesTemplates") private var stored = "[]"
 @State private var draft: MinutesTemplate?
 @State private var pendingDeletion: MinutesTemplate?
 var body: some View {
  let _ = stored
  VStack(alignment:.leading,spacing:18) {
   HStack { VStack(alignment:.leading,spacing:5) { Text("选择总结模板").font(.title2.bold()); Text("选择后用于下次生成，已有总结不会自动改写。").foregroundStyle(.secondary).font(.caption) }; Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
   ScrollView {
    LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
     ForEach(MinutesTemplate.all()) { template in
      Button { selection = template.id; dismiss() } label: {
       VStack(alignment:.leading,spacing:12) {
        HStack { Image(systemName:"doc.text"); Text(template.name).font(.headline); Spacer(); if selection == template.id { Image(systemName:"checkmark.circle.fill").foregroundStyle(Color.accentColor) } }
        Text(template.instructions).font(.callout).foregroundStyle(.secondary).lineLimit(5).frame(maxWidth:.infinity,alignment:.topLeading)
        Text(MinutesTemplate.builtins.contains(where:{$0.id == template.id}) ? "内置模板" : "自定义模板").font(.caption2).foregroundStyle(.secondary)
       }.padding(18).frame(maxWidth:.infinity,minHeight:155,alignment:.topLeading).background(selection == template.id ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(selection == template.id ? Color.accentColor : Color.clear,lineWidth:1))
      }.buttonStyle(.plain).contextMenu {
       Button("编辑模板") { draft = template }.disabled(MinutesTemplate.builtins.contains(where:{$0.id == template.id}))
       Button("复制为新模板") { draft = MinutesTemplate(id:UUID().uuidString,name:template.name+"副本",instructions:template.instructions) }
       Button("删除模板",role:.destructive) { pendingDeletion = template }.disabled(MinutesTemplate.builtins.contains(where:{$0.id == template.id}))
      }
     }
    }
   }
   Button("新增模板",systemImage:"plus") { draft = MinutesTemplate(id:UUID().uuidString,name:"",instructions:"") }
  }.padding(24).frame(width:660,height:520).modifier(TemplateDeletionConfirmation(template:$pendingDeletion)).sheet(item:$draft) { item in MinutesTemplateEditor(template:item) }
 }
}
