import SwiftUI
import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
 var model: Model?
 func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
 func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
  model?.flushNotes()
  guard let model, model.recording || model.busy || model.postProcessing || model.qaBusy else { return .terminateNow }
  if model.busy || model.postProcessing || model.qaBusy { return .terminateCancel }
  Task { @MainActor in await model.stop(runPostProcessing:false); NSApp.reply(toApplicationShouldTerminate:true) }
  return .terminateLater
 }
}
@main struct MeetingAssistantApp: App {
 @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
 @StateObject private var model: Model
 init() { SingleInstance.acquire(); _model = StateObject(wrappedValue:Model()) }
 var body: some Scene {
  Window("HuiNote · 会记",id:"main") {
   ContentView().environmentObject(model).frame(minWidth:1080,minHeight:640)
    .onAppear { delegate.model = model; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true); model.runLaunchVerificationIfRequested(); model.runKeywordBackfillIfRequested() }
  }.defaultSize(width:1180,height:780)
  Settings { SettingsView().environmentObject(model) }
 }
}
struct ContentView: View {
 @StateObject private var playback = MeetingPlayback()
 @State private var deletion: [Meeting] = []
 @State private var showingTemplates = false
 @StateObject private var libraryQA = LibraryQAState()
 private var selecting: Bool { !selectedIDs.isEmpty }
 @State private var selectedIDs = Set<String>()
 @EnvironmentObject var model: Model
 var body: some View {
  NavigationSplitView {
   VStack(alignment:.leading,spacing:8) {
    Text("会议资料库").font(.headline)
    HStack(spacing:4) {
     Button("开始会议",systemImage:"record.circle") { playback.pause(); Task { await model.startNewMeeting() } }.buttonStyle(.borderedProminent).disabled(!model.canCreateMeeting)
     Menu { Button("导入音频／视频…",action:model.importMedia).disabled(model.recording || model.busy) } label: { Image(systemName:"chevron.down") }.menuStyle(.borderlessButton).fixedSize().help("导入音频／视频").accessibilityLabel("导入音频／视频")
    }
    Button("全局搜索",systemImage:"magnifyingglass") { model.showingSearch = true }.buttonStyle(SidebarButtonStyle(selected:model.showingSearch)).keyboardShortcut("k",modifiers:.command)
    Button("跨会议问答",systemImage:"sparkles") { model.showingLibraryQA = true; playback.pause() }.buttonStyle(SidebarButtonStyle(selected:model.showingLibraryQA))
    Button("模板",systemImage:"square.grid.2x2") { showingTemplates = true }.buttonStyle(SidebarButtonStyle(selected:showingTemplates))
    Divider()
    LibraryNavigation(navigationActive:!model.showingLibraryQA && !model.showingSearch && !showingTemplates)
    Spacer(minLength:20)
    BackgroundTaskButton().buttonStyle(SidebarButtonStyle())
    PlaudSyncButton().buttonStyle(SidebarButtonStyle())
    SettingsLink { Label("设置",systemImage:"gearshape") }.buttonStyle(SidebarButtonStyle())
   }.padding().navigationSplitViewColumnWidth(240)
  } detail: {
   VStack(spacing:0) {
   if model.recording || model.busy && model.current?.status == "正在启动录音" {
    HStack(spacing:14) {
     Circle().fill(model.recordingPaused ? Color.orange : Color.red).frame(width:8,height:8)
     Text(model.busy ? (model.recording ? "正在收尾…" : "正在启动录音…") : model.recordingPaused ? "录音已暂停" : "录音中").fontWeight(.medium)
     Text(duration(model.recordingElapsed)).monospacedDigit()
     Text(model.asrSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
     Spacer()
     if !model.viewingRecording || model.showingLibraryQA || model.showingLibrary { Button("返回录音",action:model.returnToRecording).disabled(model.busy || model.qaBusy) }
     Button(model.recordingPaused ? "继续" : "暂停",systemImage:model.recordingPaused ? "play.fill" : "pause.fill") { Task { if model.recordingPaused { await model.resumeRecording() } else { await model.stop(runPostProcessing:false,pauseOnly:true) } } }.disabled(model.busy || !model.recording)
     Button("结束会议",systemImage:"stop.fill") { Task { await model.stop() } }.tint(.red).disabled(model.busy || !model.recording)
    }.padding(.horizontal,20).padding(.vertical,12).frame(minHeight:56).background(Color(nsColor:.controlBackgroundColor))
    Divider()
   }

   ZStack {
   Group {
   if model.current == nil {
    ContentUnavailableView("选择会议",systemImage:"doc.text",description:Text("从会议列表选择会议，或开始新会议。"))
   } else {
   VStack(spacing:0) {
    HStack(spacing:16) {
     Button("返回" + model.libraryTitle,systemImage:"arrow.left") { model.showingLibrary = true; playback.pause() }.buttonStyle(.borderless)
     if model.returningToLibraryQA { Button("返回问答",systemImage:"arrow.left") { model.showingLibraryQA = true; playback.pause() }.buttonStyle(.bordered) }
     VStack(alignment:.leading,spacing:5) {
      TextField("会议标题",text:Binding(get:{model.current?.title ?? "HuiNote · 会记"},set:{model.current?.title = $0; model.save()})).font(.title2.bold()).textFieldStyle(.plain).disabled(model.current == nil || model.currentSummaryLocked || model.qaBusy)
      Text(model.batchRunning ? "批量总结在后台处理中" : model.plaudSyncRunning ? "正在同步 Plaud…" : model.current?.status ?? "新建会议，开始记录").font(.caption).foregroundStyle(.secondary)
     }
     Spacer()
     if let id = model.current?.id { FolderMoveMenu(ids:[id]).fixedSize() }
     Text(duration(model.elapsed)).monospacedDigit().font(.title3)

    }.padding(.horizontal,24).padding(.vertical,16)
    if (model.viewingRecording && !model.recordingPaused) || (model.busy && !model.batchRunning && !model.plaudSyncRunning) { HStack(spacing:24) {
     health("系统音频",model.system)
     health("麦克风",model.microphone)
     Spacer()
     Text(model.asrSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(model.asrSummary)
    }.padding(.horizontal,24).padding(.bottom,10) }
    Divider()
    HStack(spacing:0) {
     VStack(alignment:.leading,spacing:12) {
      HStack(spacing:24) {
       ForEach(["转写","总结"],id:\.self) { page in
        Button { model.detailPage = page; model.summarySourcesVisible = false } label: {
         VStack(spacing:10) { Text(page).font(.headline).foregroundStyle(model.detailPage == page ? Color.primary : Color.secondary); Rectangle().fill(model.detailPage == page ? Color.accentColor : Color.clear).frame(height:2) }
        }.buttonStyle(.plain).fixedSize(horizontal:true,vertical:false)
       }
       Spacer()
       GenerationButton()
       Button { model.showingQA.toggle(); if model.showingQA { model.summarySourcesVisible = false } } label: { Label(model.showingQA ? "收起问答" : "本场问答",systemImage:"sparkles") }.buttonStyle(.bordered)
       Menu { Button("查看录音文件",action:model.showFiles); if model.detailPage != "总结" { Button("导出 Markdown",action:model.export) }; Divider(); Button("删除会议…",role:.destructive) { if let current = model.current { deletion = [current] } } } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(model.current == nil || !model.canDelete)
      }
      if !model.viewingRecording && model.current?.status != "未开始" && (model.detailPage != "总结" || model.summarySourcesVisible || playback.playing) { MeetingPlayerView() }
      if model.detailPage != "总结" {
       HStack {
        Picker("稿件",selection:$model.showingFinal) { Text("实时保留稿").tag(false); Text("说话人稿").tag(true) }.labelsHidden().frame(width:150)
        TranscriptReviewBar()
       }
       VStack(spacing:10) {
        if model.viewingRecording { MeetingNotesView(); Divider() }
        HStack(alignment:.top,spacing:14) {
         Group { if model.showingFinal { FinalTranscriptView() } else { TranscriptView() } }.frame(maxWidth:.infinity,maxHeight:.infinity)
         if model.showingFinal && model.speakerPanelVisible && !model.showingQA { SpeakerSidebar() }
        }.frame(minHeight:120,maxHeight:.infinity).layoutPriority(1)
        if !model.viewingRecording { Divider(); MeetingNotesView() }
       }
      } else {
       HStack(spacing:12) {
        if model.summarySourcesVisible { SummarySourcePane(); Divider() }
        PostMeetingView().frame(minWidth:330,maxWidth:.infinity,maxHeight:.infinity)
       }
      }
     }.padding(.horizontal,24).padding(.vertical,16).frame(minWidth:360,maxWidth:.infinity,maxHeight:.infinity)
     if model.showingQA {
      Divider()
      VStack(alignment:.leading,spacing:18) {
       HStack { Label("本场问答",systemImage:"sparkles").font(.headline); Spacer(); Button { model.showingQA = false } label: { Image(systemName:"xmark") }.buttonStyle(.plain).help("收起问答") }
       MeetingQAView()
      }.padding(16).frame(width:280).frame(maxHeight:.infinity).background(Color(nsColor:.controlBackgroundColor))
     }
    }.environmentObject(playback)

   }
   }
   }.opacity(model.showingLibraryQA || model.showingLibrary ? 0 : 1).allowsHitTesting(!model.showingLibraryQA && !model.showingLibrary).accessibilityHidden(model.showingLibraryQA || model.showingLibrary)
   MeetingLibraryView(selectedIDs:$selectedIDs,deletion:$deletion)
    .opacity(model.showingLibrary && !model.showingLibraryQA ? 1 : 0).allowsHitTesting(model.showingLibrary && !model.showingLibraryQA).accessibilityHidden(!model.showingLibrary || model.showingLibraryQA)
   LibraryQAView(state:libraryQA)
    .opacity(model.showingLibraryQA ? 1 : 0).allowsHitTesting(model.showingLibraryQA).accessibilityHidden(!model.showingLibraryQA).disabled(!model.showingLibraryQA)
   }
  }
  }
  .sheet(isPresented:$model.showingSearch) { GlobalSearchView() }
  .sheet(isPresented:$showingTemplates) { TemplateManagerView() }
  .overlay(alignment:.bottomTrailing) { PlaudSyncNotice() }
  .onAppear { model.showLibrary(model.libraryScope); configurePlayback() }
  .onChange(of:model.current?.id) { _,_ in configurePlayback() }
  .onChange(of:model.detailPage) { _,page in if page == "笔记" { model.notesVisible = true; model.detailPage = "转写" } }
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
  let imported = model.current.flatMap { model.store?.importedAudio(for:$0) }
  playback.configure(folder:folder,imported:imported,duration:model.current?.duration ?? 0,enabled:model.current != nil && !model.viewingRecording)
 }
 func duration(_ seconds: Double) -> String { let value = max(0,Int(seconds)); return String(format:"%02d:%02d:%02d",value/3600,(value/60)%60,value%60) }
 func health(_ title: String,_ value: AudioHealth) -> some View {
  let stale = value.lastReceived.map { model.now.timeIntervalSince($0) > 3 } ?? true
  let text = value.error != nil ? "失败" : (!model.recording ? (value.frames > 0 ? "已保存" : "未采集") : stale ? "等待音频" : value.peak < 0.001 ? "收到音频 · 静音" : "收到音频")
  return HStack(spacing:6) { Circle().fill(value.error != nil ? Color.red : model.recording && !stale ? .green : .gray).frame(width:7,height:7); Text("\(title)：\(text)").font(.caption) }.help(value.error ?? "已保存 \(value.frames) 帧")
 }
}
struct SettingsView: View {
 @EnvironmentObject var model: Model

 @AppStorage("plaudDirectory") private var plaudDirectory = PlaudImport.defaultDirectory
 @AppStorage("plaudTool") private var plaudTool = PlaudImport.defaultTool
 @AppStorage("asrEndpoint") private var asrEndpoint = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
 @AppStorage("asrModel") private var asrModel = "fun-asr-realtime"
 @AppStorage("llmBaseURL") private var llmBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
 @AppStorage("llmModel") private var llmModel = "qwen-plus"
 @AppStorage("offlineBaseURL") private var offlineBaseURL = "https://dashscope.aliyuncs.com/api/v1"
 @AppStorage("offlineModel") private var offlineModel = "fun-asr"
 @AppStorage("autoPostMeeting") private var autoPostMeeting = true
 @AppStorage("microphoneDeviceID") private var microphoneDeviceID = ""
 @AppStorage("liveTranscription") private var liveTranscription = true
 @State private var asrKey = ""
 @State private var llmKey = ""
 @State private var status = ""
 @State private var testing = false
 @State private var category = "录音"
 @State private var keysLoaded = false
 var body: some View {
  VStack(spacing:0) {
   Picker("设置分类",selection:$category) { ForEach(["录音","AI 服务","数据与导入"],id:\.self) { Text($0).tag($0) } }.pickerStyle(.segmented).padding()
  Form {
   if category == "数据与导入" {
   Section("本地资料目录") {
    Text(model.store?.root.path ?? "资料库不可用").textSelection(.enabled).font(.caption)
    Button("选择目录并迁移资料…",action:model.chooseLibraryDirectory)
     .disabled(model.recording || model.busy || model.postProcessing || model.qaBusy || model.batchRunning)
    Text("录音、转写、笔记与纪要统一保存。迁移后使用新目录，原目录保留备份；API Key 仍存于钥匙串。").font(.caption).foregroundStyle(.secondary)
   }
   }
   if category == "录音" {
   Section("录音与网络") {
    if #available(macOS 15.0, *) {
     Picker("麦克风",selection:$microphoneDeviceID) {
      Text("系统默认输入").tag("")
      ForEach(Capture.microphoneDevices,id:\.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
      if !microphoneDeviceID.isEmpty && !Capture.microphoneDevices.contains(where:{$0.uniqueID == microphoneDeviceID}) { Text("所选设备未连接").tag(microphoneDeviceID) }
     }.disabled(model.recording)
    }
    Toggle("录音时实时转写",isOn:$liveTranscription).disabled(model.recording)
    Toggle("结束后自动生成纪要",isOn:$autoPostMeeting)
    Text("开启后遇到断网会自动保留本地录音并重连，恢复后转写新音频；缺失片段会后自动上传完整录音补齐。关闭后仅本地录音，是否会后上传由自动生成纪要选项决定。").font(.caption).foregroundStyle(.secondary)
   }
   }
   if category == "AI 服务" {
   Section("百炼 · 北京") {
    Text("会后录音使用百炼临时 OSS，云端文件 48 小时后自动清理。").font(.caption).foregroundStyle(.secondary)
    SecureField("ASR API Key",text:$asrKey)
    TextField("WebSocket Endpoint",text:$asrEndpoint)
    TextField("实时模型",text:$asrModel)
   }
   }
   if category == "AI 服务" {
   Section("会后识别 · 使用 ASR Key") {
    TextField("文件识别 Base URL",text:$offlineBaseURL)
    TextField("文件识别模型",text:$offlineModel)
    Text("仅上传单声道混音；实时稿始终保留。会后识别支持十二小时以内录音；说话人分离建议两小时以内，长录音需重点核对编号。临时 OSS 不提供本地可执行的提前删除入口，48 小时后由服务清理。").font(.caption).foregroundStyle(.secondary)
   }
   }
   if category == "AI 服务" {
   Section("纪要模型 · OpenAI 兼容接口") {
    SecureField("LLM API Key",text:$llmKey)
    Button("使用 ASR Key") { do { llmKey = asrKey.isEmpty ? try Secrets.read("asr") : asrKey; status = "已填入，请保存密钥。" } catch { status = error.localizedDescription } }
    TextField("Base URL",text:$llmBaseURL)
    TextField("模型",text:$llmModel)
   }
   }
   if category == "数据与导入" {
   Section("文件导入") {
    Button("导入音频或视频录像…",action:model.importMedia)
     .disabled(model.recording || model.busy || model.postProcessing || model.qaBusy || model.batchRunning)
    Text("支持系统可读取的音频及视频格式。保留原文件并提取音轨，导入后可生成转写、说话人稿与纪要。").font(.caption).foregroundStyle(.secondary)
   }
   }
   if category == "数据与导入" {
   Section("Plaud 本地资料") {
    DisclosureGroup("导入旧版本地纪要") {
    Button("选择本地纪要目录…",action:model.choosePlaudDirectory)
     .disabled(model.recording || model.busy || model.postProcessing || model.qaBusy || model.batchRunning)
    Button("导入本地 Plaud 纪要") { model.syncPlaud() }
     .disabled(model.recording || model.busy || model.postProcessing || model.qaBusy || model.batchRunning)

    DisclosureGroup("高级：本地导入路径") { TextField("本地纪要目录",text:$plaudDirectory); TextField("原 Plaud 工具目录",text:$plaudTool) }
    Text("按文件编号去重导入，不覆盖本机编辑，原文件保留。").font(.caption).foregroundStyle(.secondary)
    }
    Text("日常下载录音请使用主窗口的“同步 Plaud”，登录失效时会自动打开登录。").font(.caption).foregroundStyle(.secondary)
   }
   }
   if category == "AI 服务" {
   Section {
    Button("保存密钥到钥匙串") {
     do { try Secrets.save(asrKey,account:"asr"); try Secrets.save(llmKey,account:"llm"); status = "密钥已保存到钥匙串。" }
     catch { status = error.localizedDescription }
    }
    DisclosureGroup("钥匙串授权诊断") {
    Button("检查钥匙串授权状态") { do { status = try Secrets.checkAccess() } catch { status = error.localizedDescription } }
    Text("密钥由固定签名的 MeetingAssistantKeychain 组件读取。首次迁移时请在系统弹窗选择“始终允许”；后续普通 App 更新会复用该组件。").font(.caption).foregroundStyle(.secondary)
    }
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
    if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
    Text("地址与模型自动保存；密钥仅保存到 macOS 钥匙串。开始会议后，两路音频会发送至所配置的百炼实时识别接口；原始录音仍保存在本机。").font(.caption).foregroundStyle(.secondary)
   }
   }
  }.formStyle(.grouped)
  }.frame(width:680,height:680)
  .onChange(of:category) { _,section in
   if section == "AI 服务" && !keysLoaded { do { asrKey = try Secrets.read("asr"); llmKey = try Secrets.read("llm"); keysLoaded = true } catch { status = error.localizedDescription } }
  }
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
   ScrollViewReader { proxy in
    VStack(spacing:8) {
    HStack { Text("音源标签不代表说话人").font(.caption).foregroundStyle(.secondary); Spacer(); if follow { Text("自动跟随").font(.caption).foregroundStyle(.secondary) }; if !follow { Button("恢复跟随",systemImage:"location.fill") { follow = true; if model.recording { proxy.scrollTo("bottom",anchor:.bottom) } else if let id = PlaybackTimeline.anchor(cues,at:playback.position) { proxy.scrollTo(id,anchor:.center) } }.controlSize(.small) } }.frame(height:24)
    ScrollView {
     LazyVStack(alignment:.leading,spacing:18) {
      if model.transcripts.isEmpty {
       VStack(spacing:14) {
        Image(systemName:"waveform").font(.system(size:36)).foregroundStyle(.tertiary)
        Text(model.busy && !model.recording ? "正在启动录音…" : model.viewingRecording ? "等待语音识别结果…" : model.current?.status == "未开始" ? "点击左侧开始会议" : "录音已保存，尚无实时转写")
        Text(model.busy && !model.recording ? "正在检查系统音频与麦克风。" : model.viewingRecording ? "本地录音独立保存；网络不佳时会后补齐。" : "已有录音可在总结页进行转写，无需新建会议。").font(.caption).foregroundStyle(.secondary)

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
        SearchHighlight(text:item.text.isEmpty ? "…" : item.text,query:model.reviewQuery).font(.body).lineSpacing(5).foregroundStyle(item.gap ? .orange : item.final ? .primary : .secondary).textSelection(.enabled)
       }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(item.gap ? Color.orange.opacity(0.07) : ((active.contains(item.id) && !model.recording) || (!playback.playing && model.focusedSentence == item.id) ? Color.accentColor.opacity(0.08) : Color.clear),in:RoundedRectangle(cornerRadius:9)).id(item.id)
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
 @State private var showDetails = false

 private var locked: Bool { model.recording || model.busy || model.postProcessing || model.qaBusy }
 var body: some View {
  VStack(alignment:.leading,spacing:0) {
   HStack(spacing:12) {
    Text("总结 · " + model.meetingTemplate.name).foregroundStyle(.secondary).lineLimit(1)
    if model.postProcessing && model.postMeetingID == model.current?.id { ProgressView().controlSize(.small); Button("停止等待",action:model.cancelPostMeeting) }
    Spacer()
    Button { editing.toggle() } label: { Label(editing ? "完成编辑" : "编辑",systemImage:editing ? "checkmark" : "square.and.pencil") }.disabled(locked)
    Menu { Button("导出 Markdown",action:model.export); Button("处理详情") { showDetails.toggle() }; Divider(); Button("重新识别录音与说话人") { model.startPostMeeting(forceNew:true) }.disabled(locked) } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).frame(width:28)
   }.buttonStyle(.borderless).padding(.horizontal,12).padding(.vertical,12)
   if model.postProcessing { Text(model.postProgress).font(.caption).foregroundStyle(.secondary).padding(.horizontal,12).padding(.bottom,8) }
   if model.batchRunning { Text("批量生成中 · 可继续阅读和播放，编辑将在任务结束后恢复").font(.caption).foregroundStyle(.secondary).padding(.horizontal,12).padding(.bottom,8) }
   if model.current?.post?.minutes.isEmpty == false, let used = model.current?.post?.minutesTemplate, used != model.meetingTemplate { Text("当前总结使用“\(used.name)” · 下次生成将使用“\(model.meetingTemplate.name)”").font(.caption).foregroundStyle(.secondary).padding(12) }
   if model.minutesStale && !model.postProcessing { Text("内容已修改，可通过右上角“更新总结”重新生成。").font(.caption).foregroundStyle(.orange).padding(12) }
   if showDetails {
    VStack(alignment:.leading,spacing:6) { Text(model.current?.post?.status ?? "尚未生成"); if let warning = model.current?.post?.warning, !warning.isEmpty { Text(warning) }; Text("通过右上角生成入口选择模板；已有总结的模板显示在会议信息中。") }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(12)
   }
   Divider()
   if editing { TextEditor(text:Binding(get:{model.current?.post?.minutes ?? ""},set:model.updateMinutes)).font(.system(size:15)).lineSpacing(7).padding(20).disabled(locked) }
   else { Group { if let meeting = model.current { SummaryDocument(meeting:meeting,isProcessing:model.postProcessing && model.postMeetingID == meeting.id) } }
    .environment(\.openURL,OpenURLAction { url in
     guard let id = url.fragment else { return .discarded }
     if id == "N1" { model.detailPage = "笔记" }
     else if model.current?.post?.sentences.contains(where:{$0.id == id}) == true { model.detailPage = "转写"; model.showingFinal = true; model.reviewQuery = ""; model.reviewSpeaker = "all"; model.focusedSentence = id; model.citationScrollToken = UUID() }
     return .handled
    })
   }
  }.frame(maxHeight:.infinity).onChange(of:model.current?.id) { _,_ in editing = false }
 }
}
struct FinalTranscriptView: View {
 @EnvironmentObject var playback: MeetingPlayback
 @EnvironmentObject var model: Model
 @State private var follow = true
 @State private var editingSentence: FinalSentence?
 @State private var hoveredSentence: String?
 private var visibleSentences: [FinalSentence] { (model.current?.post?.sentences ?? []).filter { model.reviewSpeaker == "all" || String($0.speaker ?? -1) == model.reviewSpeaker } }
 private var cues: [PlaybackCue] { visibleSentences.map { PlaybackCue(id:$0.id,begin:$0.begin,end:$0.end) } }
 private var active: [String] { guard playback.hasPosition else { return [] }; return PlaybackTimeline.active(cues,at:playback.position) }
 @ViewBuilder private func sentenceHeader(_ sentence: FinalSentence) -> some View {
HStack {
        Button { follow = true; playback.play(at:sentence.begin); model.focusedSentence = nil } label: { Label(sentence.timeLabel,systemImage:"play.fill").monospacedDigit().padding(.horizontal,8).frame(minHeight:28).background(Color.accentColor.opacity(0.08),in:RoundedRectangle(cornerRadius:6)).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption).disabled(model.recording || (model.busy && !model.batchRunning) || model.postProcessing).help("从此处播放")
        if let speaker = sentence.speaker {
         Button { model.speakerEditTarget = nil; model.openSpeakerReview(); model.speakerEditTarget = speaker } label: { HStack(spacing:5) { Circle().fill(SpeakerPalette.color(speaker)).frame(width:7,height:7); Text(model.current?.post?.name(speaker) ?? "说话人").font(.caption.bold()).foregroundStyle(SpeakerPalette.color(speaker)) }.padding(.horizontal,8).frame(minHeight:28).background(SpeakerPalette.color(speaker).opacity(0.08),in:RoundedRectangle(cornerRadius:6)).contentShape(Rectangle()) }.buttonStyle(.plain).help("修改本场发言人姓名").disabled(model.recording || model.postProcessing || model.currentSummaryLocked || model.qaBusy)
        } else { Text("说话人未识别").font(.caption) }
        Button { editingSentence = sentence } label: { Label("校对",systemImage:"pencil").padding(.horizontal,8).frame(minHeight:28).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).font(.caption).help("校对本句文字").disabled(model.recording || model.postProcessing || model.currentSummaryLocked || model.qaBusy)
        if sentence.originalText != nil { Text("已校对").font(.caption2).foregroundStyle(.secondary) }
        Spacer()
        Text(active.contains(sentence.id) ? "当前播放" : "").font(.caption2).foregroundStyle(Color.accentColor).frame(width:55)
       }
 }
 var body: some View {
  ScrollViewReader { proxy in
   VStack(alignment:.leading,spacing:12) {
    HStack { Text(follow ? "自动跟随播放" : "跟随已暂停 · 可自由浏览").font(.caption).foregroundStyle(.secondary); Spacer(); if !follow { Button("恢复跟随",systemImage:"location.fill") { follow = true; if let id = PlaybackTimeline.anchor(cues,at:playback.position) { proxy.scrollTo(id,anchor:.center) } } } }
   ScrollView {
    LazyVStack(alignment:.leading,spacing:16) {
     if model.current?.post?.sentences.isEmpty ?? true { Text("会后识别完成后，带说话人编号的句子将显示在这里。实时稿仍可切换查看。").foregroundStyle(.secondary) }
     ForEach(visibleSentences) { sentence in
      VStack(alignment:.leading,spacing:8) {
       sentenceHeader(sentence)
       TranscriptTextClick(text:sentence.text,query:model.reviewQuery,highlighted:active.contains(sentence.id)) {
         guard !model.recording, !(model.busy && !model.batchRunning), !model.postProcessing, !playback.loading else { return }
         follow = false
         playback.seek(sentence.begin)
        }
        .help("点击定位到本句录音；拖动可选择文字")

      }.padding(.horizontal,10).padding(.vertical,6).frame(maxWidth:.infinity,alignment:.leading).background(active.contains(sentence.id) || (!playback.playing && model.focusedSentence == sentence.id) ? Color.accentColor.opacity(0.08) : Color.clear,in:RoundedRectangle(cornerRadius:5)).onHover { hoveredSentence = $0 ? sentence.id : nil }.contextMenu { Button("校对文字") { editingSentence = sentence }.disabled(model.recording || model.postProcessing || model.currentSummaryLocked || model.qaBusy) }.id(sentence.id)
     }
    }
   }.background(TranscriptScrollObserver { follow = false })
    .onChange(of:active) { _,ids in if follow, let id = ids.first { proxy.scrollTo(id,anchor:.center) } }
    .onAppear { if let id = model.focusedSentence { follow = false; proxy.scrollTo(id,anchor:.center) } else if playback.hasPosition, let id = PlaybackTimeline.anchor(cues,at:playback.position) { proxy.scrollTo(id,anchor:.center) } }
    .onChange(of:model.focusedSentence) { _,id in if let id { proxy.scrollTo(id,anchor:.center) } }
    .onChange(of:model.citationScrollToken) { _,_ in follow = false; if let id = model.focusedSentence { proxy.scrollTo(id,anchor:.center) } }
   }.onChange(of:model.current?.id) { _,_ in follow = true; editingSentence = nil }
  }.sheet(item:$editingSentence) { sentence in SentenceEditor(meetingID:model.current?.id ?? "",sentence:sentence) }
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
struct MinutesTemplateEditor: View {
 @Environment(\.dismiss) private var dismiss
 @State var template: MinutesTemplate
 @State private var error = ""
 var onSave: ((MinutesTemplate) -> Void)? = nil
 var body: some View {
  VStack(alignment:.leading,spacing:14) {
   Text("纪要模板").font(.title2.bold())
   TextField("模板名称（最多40字）",text:$template.name).textFieldStyle(.roundedBorder)
   Text("描述希望重点总结的内容、语气和详细程度（最多4000字）").font(.caption)
   TextEditor(text:$template.instructions).font(.body).frame(minHeight:220)
   if !error.isEmpty { Text(error).foregroundStyle(.red) }
   HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
    Button(onSave == nil ? "保存并设为默认" : "保存") { do { try MinutesTemplate.save(template,selectAsDefault:onSave == nil); onSave?(template); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent)
   }
  }.padding(24).frame(width:560)
 }
}

struct TemplateGallery: View {
 @Environment(\.dismiss) private var dismiss
 @Binding var selection: String
 @AppStorage("minutesTemplates") private var stored = "[]"
 var body: some View {
  let _ = stored
  VStack(alignment:.leading,spacing:18) {
   HStack { VStack(alignment:.leading,spacing:5) { Text("选择总结模板").font(.title2.bold()); Text("仅用于本场下次生成，不改变默认模板；已有总结保持不变。").foregroundStyle(.secondary).font(.caption) }; Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
   ScrollView {
    LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
     ForEach(MinutesTemplate.all()) { template in
      Button { selection = template.id; dismiss() } label: {
       VStack(alignment:.leading,spacing:12) {
        HStack { Image(systemName:"doc.text"); Text(template.name).font(.headline); Spacer(); if selection == template.id { Image(systemName:"checkmark.circle.fill").foregroundStyle(Color.accentColor) } }
        Text(template.instructions).font(.callout).foregroundStyle(.secondary).lineLimit(5).frame(maxWidth:.infinity,alignment:.topLeading)
        Text(MinutesTemplate.builtins.contains(where:{$0.id == template.id}) ? "内置模板" : "自定义模板").font(.caption2).foregroundStyle(.secondary)
       }.padding(18).frame(maxWidth:.infinity,minHeight:155,alignment:.topLeading).background(selection == template.id ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(selection == template.id ? Color.accentColor : Color.clear,lineWidth:1))
      }.buttonStyle(.plain)
     }
    }
   }
   Text("新增、编辑和默认模板设置请使用主窗口左侧的“模板”。").font(.caption).foregroundStyle(.secondary)
  }.padding(24).frame(width:660,height:520)
 }
}
