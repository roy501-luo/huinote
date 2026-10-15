import SwiftUI

struct LibraryQARecord: Codable, Identifiable {
 var id = UUID().uuidString
 var meetingIDs: [String]
 var scope: String
 var entry: QAEntry
}
@MainActor final class LibraryQAState: ObservableObject {
 @Published var scope = "all"
 @Published var selected = Set<String>()
 @Published var filter = ""
 @Published var question = ""
 @Published var records: [LibraryQARecord] = []
 @Published var running = false
 @Published var progress = ""
 @Published var failure: String?
 private var task: Task<Void,Never>?
 private var root: URL?
 func load(_ root: URL?) {
  guard let root, self.root != root, !running else { return }
  self.root = root
  let url = root.appendingPathComponent("library-questions.json")
  do {
   records = FileManager.default.fileExists(atPath:url.path) ? try JSONDecoder().decode([LibraryQARecord].self,from:Data(contentsOf:url)) : []
   for i in records.indices where records[i].entry.status == "正在检索" { records[i].entry.status = "上次问答被中断，请重试" }
  } catch { failure = "问答历史无法读取："+error.localizedDescription }
 }
 private func save() {
  guard let root else { return }
  do { try JSONEncoder().encode(records).write(to:root.appendingPathComponent("library-questions.json"),options:.atomic) }
  catch { failure = "问答历史保存失败："+error.localizedDescription }
 }
 func cancel() { task?.cancel() }
 func ask(meetings: [Meeting], scope: String, store: Store?) {
  let text = question.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !running, !meetings.isEmpty, !text.isEmpty, text.count <= 1000, let store else { return }
  var sources: [QASource] = []; var missing = 0
  do {
   for meeting in meetings {
    let realtime = (meeting.post?.sentences.isEmpty ?? true) ? try store.transcripts(meeting.id) : []
    let local = QAEvidence.librarySources(meeting:meeting,realtime:realtime)
    if local.isEmpty { missing += 1 }
    sources += local
   }
  } catch { failure = "读取原文失败："+error.localizedDescription; return }
  let coverage = "范围：\(scope)，\(meetings.count) 场；\(missing) 场没有可用原文。只使用转写和用户笔记，转写缺失的内容无法判断。"
  var record = LibraryQARecord(meetingIDs:meetings.map(\.id),scope:scope,entry:QAEntry(question:text,status:"正在检索",sourceDigest:QAEvidence.digest(sources),coverage:coverage))
  records.append(record); save(); question = ""; running = true
  task = Task {
   let service = MeetingQAService()
   do {
    let answer = sources.isEmpty ? QAAnswer() : try await service.answer(question:text,sources:sources,configuration:LLMConfiguration.load(),progress:{ [weak self] value in await self?.update(value) })
    try Task.checkCancellation()
    record.entry.references = answer.references; record.entry.points = answer.points; record.entry.supported = !answer.references.isEmpty
    record.entry.status = answer.references.isEmpty ? "所选资料不足以回答这个问题，未找到可靠的原文依据。" : "根据所选会议原文归纳"
   } catch { record.entry.status = Task.isCancelled ? "已取消，可重试" : "问答失败："+error.localizedDescription }
   await service.close()
   if let index = records.firstIndex(where:{$0.id == record.id}) { records[index] = record }
   running = false; progress = ""; save()
  }
 }
 private func update(_ value: String) { progress = value }
}

struct LibraryQAView: View {
 @EnvironmentObject var model: Model
 @ObservedObject var state: LibraryQAState
 private var meetings: [Meeting] {
  QAEvidence.scopedMeetings(model.meetings,scope:state.scope,selected:state.selected,memberships:model.memberships)
 }
 private var scopeName: String { state.scope == "all" ? "全部会议" : state.scope == "selected" ? "指定会议" : model.folders.first(where:{$0.id == state.scope})?.name ?? "已删除文件夹" }
 var body: some View {
  VStack(alignment:.leading,spacing:14) {
   HStack { Text("跨会议问答").font(.title2.bold()); Spacer() }
   HStack {
    Picker("范围",selection:$state.scope) {
     Text("全部会议").tag("all"); Text("指定会议").tag("selected")
     ForEach(model.folders) { Text("文件夹 · "+$0.name).tag($0.id) }
    }.frame(width:300)
    Text("\(meetings.count) 场会议").foregroundStyle(.secondary)
   }.disabled(state.running)
   if state.scope == "selected" {
    TextField("查找要加入范围的会议",text:$state.filter).textFieldStyle(.roundedBorder).disabled(state.running)
    ScrollView {
     LazyVStack(alignment:.leading) {
      ForEach(model.meetings.filter { state.filter.isEmpty || $0.title.localizedCaseInsensitiveContains(state.filter) }) { meeting in
       Toggle(meeting.title,isOn:Binding(get:{state.selected.contains(meeting.id)},set:{ if $0 { state.selected.insert(meeting.id) } else { state.selected.remove(meeting.id) } })).toggleStyle(.checkbox)
      }
     }
    }.frame(height:110).disabled(state.running)
   }
   Divider()
   ScrollView {
    LazyVStack(alignment:.leading,spacing:24) {
     if state.records.isEmpty { Text("选择资料范围后提问。每次独立回答；长资料逐段阅读，引用可跳回原文。").foregroundStyle(.secondary) }
     ForEach(state.records) { record in
      VStack(alignment:.leading,spacing:8) {
       Text(record.entry.question).font(.headline).textSelection(.enabled)
       Text(record.entry.coverage).font(.caption).foregroundStyle(.secondary)
       Text(record.entry.status).font(.caption).foregroundStyle(.secondary)
       ForEach(Array((record.entry.points ?? []).enumerated()),id:\.offset) { _, point in
        Text(point.text).textSelection(.enabled)
        ForEach(record.entry.references.filter { point.sourceIDs.contains($0.source.id) }) { ref in
         Button { open(ref) } label: { Text(ref.source.label+" · "+ref.source.timeLabel+" ↗").font(.caption).multilineTextAlignment(.leading) }.buttonStyle(.borderless).help(ref.quote).disabled(state.running || model.qaBusy)
        }
       }
       if !state.running { Button("再次提问") { state.question = record.entry.question; state.scope = "selected"; state.selected = Set(record.meetingIDs) }.font(.caption) }
      }.frame(maxWidth:.infinity,alignment:.leading)
     }
    }.padding(.vertical,8)
   }.defaultScrollAnchor(.bottom).frame(maxHeight:.infinity)
   if state.running { HStack { ProgressView().controlSize(.small); Text(state.progress).font(.caption); Spacer(); Button("取消",action:state.cancel) } }
   TextEditor(text:$state.question).frame(height:60).border(Color.secondary.opacity(0.25)).accessibilityLabel("跨会议问题")
   HStack { Text("仅回答有依据的内容；资料会发送至已配置的 LLM。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("发送") { state.ask(meetings:meetings,scope:scopeName,store:model.store) }.keyboardShortcut(.return,modifiers:.command).buttonStyle(.borderedProminent).disabled(state.running || meetings.isEmpty || state.question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || state.question.count > 1000 || model.qaBusy || model.busy) }
  }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity).onAppear { state.load(model.store?.root) }
   .onChange(of:state.running) { _,running in model.qaBusy = running }
   .alert("无法完成",isPresented:Binding(get:{state.failure != nil},set:{if !$0 { state.failure = nil }})) { Button("好") { state.failure = nil } } message: { Text(state.failure ?? "") }
 }
 private func open(_ ref: QAReference) {
  guard let id = ref.source.meetingID, let meeting = model.meetings.first(where:{$0.id == id}) else { state.failure = "原会议已删除，无法跳转。"; return }
  model.select(meeting)
  guard let source = model.qaSources().first(where:{$0.id == ref.source.originalSourceID}) else { state.failure = "原文已修改，引用快照可能过期，请重新提问。"; return }
  model.returningToLibraryQA = true; model.showingLibraryQA = false; model.openCitation(QAReference(source:source,quote:ref.quote))
 }
}
