import SwiftUI

struct TranscriptReviewBar: View {
 @EnvironmentObject var model: Model
 @State private var cursor = 0
 private var matches: [String] {
  let query = model.reviewQuery.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !query.isEmpty else { return [] }
  if model.showingFinal {
   return (model.current?.post?.sentences ?? []).filter {
    (model.reviewSpeaker == "all" || String($0.speaker ?? -1) == model.reviewSpeaker) && $0.text.localizedStandardContains(query)
   }.map(\.id)
  }
  return model.transcripts.filter { !$0.gap && $0.text.localizedStandardContains(query) }.map(\.id)
 }
 private var speakerIDs: [Int] { Array(Set((model.current?.post?.sentences ?? []).compactMap(\.speaker))).sorted() }
 var body: some View {
  HStack(spacing:8) {
   TextField("查找本场转写",text:$model.reviewQuery).textFieldStyle(.roundedBorder).frame(maxWidth:240)
    .onSubmit { navigate(1) }
   if !model.reviewQuery.isEmpty {
    Text(matches.isEmpty ? "无匹配" : "\(min(cursor+1,matches.count))/\(matches.count)").font(.caption).monospacedDigit()
    Button { navigate(-1) } label: { Image(systemName:"chevron.up") }.help("上一处").disabled(matches.isEmpty)
    Button { navigate(1) } label: { Image(systemName:"chevron.down") }.help("下一处").disabled(matches.isEmpty)
    Button { model.reviewQuery = "" } label: { Image(systemName:"xmark.circle.fill") }.help("清除本场查找")
   }
   Spacer(minLength:0)
   if model.showingFinal && !speakerIDs.isEmpty {
    Picker("发言人",selection:$model.reviewSpeaker) {
     Text("全部发言人").tag("all")
     ForEach(speakerIDs,id:\.self) { id in Text(model.current?.post?.name(id) ?? "说话人").tag(String(id)) }
     if model.current?.post?.sentences.contains(where:{$0.speaker == nil}) == true { Text("未识别").tag("-1") }
    }.labelsHidden().frame(maxWidth:150)
    Button(model.speakerPanelVisible && !model.showingQA ? "收起发言人" : "维护发言人",systemImage:"person.2") { model.speakerPanelVisible = model.showingQA || !model.speakerPanelVisible; model.showingQA = false }.disabled(model.recording || model.postProcessing || model.currentSummaryLocked || model.qaBusy)
   }
  }.controlSize(.small)
   .onChange(of:model.reviewQuery) { _,_ in cursor = 0; focus() }
   .onChange(of:model.reviewSpeaker) { _,_ in cursor = 0; focus() }
   .onChange(of:model.showingFinal) { _,_ in cursor = 0; focus() }
 }
 private func navigate(_ delta: Int) { guard !matches.isEmpty else { return }; cursor = (cursor+delta+matches.count)%matches.count; focus() }
 private func focus() { guard !matches.isEmpty else { return }; cursor = min(cursor,matches.count-1); model.focusedSentence = matches[cursor]; model.citationScrollToken = UUID() }
}

struct SentenceEditor: View {
 @EnvironmentObject var model: Model
 @Environment(\.dismiss) private var dismiss
 let meetingID: String
 let sentence: FinalSentence
 @State private var text = ""
 @State private var failure: String?
 var body: some View {
  VStack(alignment:.leading,spacing:16) {
   Text("校对转写 · " + sentence.timeLabel).font(.title2.bold())
   Text("仅修改本句文字，保留时间点、说话人及最初识别结果。相关总结与问答会提示需重新核对。").font(.callout).foregroundStyle(.secondary)
   TextEditor(text:$text).font(.body).frame(minHeight:160)
   DisclosureGroup("最初识别结果") { Text(sentence.originalText ?? sentence.text).textSelection(.enabled).font(.callout) }
   if let failure { Text(failure).foregroundStyle(.red) }
   HStack {
    Button("恢复最初文字") { text = sentence.originalText ?? sentence.text }
    Spacer()
    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
    Button("保存校对") { do { try model.correctSentence(meetingID:meetingID,id:sentence.id,text:text); dismiss() } catch { failure = error.localizedDescription } }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
   }
  }.padding(24).frame(width:560).onAppear { text = sentence.text }
 }
}

struct SpeakerReviewSection: View {
 @EnvironmentObject var model: Model
 var body: some View {
  if let post = model.current?.post, !post.sentences.isEmpty {
   VStack(alignment:.leading,spacing:8) {
    HStack {
     Label("发言人",systemImage:"person.2").font(.headline)
     Spacer()
     Button("核对与改名") { model.summaryAfterSpeakerReview = false; model.openSpeakerReview() }
      .disabled(model.recording || model.postProcessing || model.currentSummaryLocked || model.qaBusy)
    }
    Text(Array(Set(post.sentences.compactMap(\.speaker))).sorted().map { post.name($0) }.joined(separator:" · ")).textSelection(.enabled)
    Text("生成总结前，可试听原话并补充姓名；不确定的保留编号。").font(.caption).foregroundStyle(.secondary)
   }.padding(14).background(Color.accentColor.opacity(0.05),in:RoundedRectangle(cornerRadius:10))
  }
 }
}

enum SpeakerPalette {
 static func color(_ id: Int?) -> Color {
  guard let id else { return .secondary }
  let colors: [Color] = [.blue,.orange,.purple,.teal,.pink,.indigo,.brown,.green]
  return colors[((id % colors.count) + colors.count) % colors.count]
 }
}
struct SpeakerSidebar: View {
 @EnvironmentObject var model: Model
 @EnvironmentObject var playback: MeetingPlayback
 private var groups: [(Int,[FinalSentence])] {
  let all = model.current?.post?.sentences ?? []
  return Array(Set(all.compactMap(\.speaker))).sorted().map { id in (id,all.filter{$0.speaker == id}) }
 }
 private var locked: Bool { model.recording || model.postProcessing || model.currentSummaryLocked || model.qaBusy }
 var body: some View {
  VStack(alignment:.leading,spacing:12) {
   HStack { Label("发言人",systemImage:"person.2").font(.headline); Spacer(); Button { model.speakerPanelVisible = false } label: { Image(systemName:"sidebar.right") }.buttonStyle(.plain).help("收起发言人") }
   Button("显示全部发言") { model.reviewSpeaker = "all" }.buttonStyle(.borderless)
   ScrollViewReader { proxy in
   ScrollView {
    VStack(spacing:12) {
     ForEach(groups,id:\.0) { id, sentences in
      VStack(alignment:.leading,spacing:8) {
       HStack { Circle().fill(SpeakerPalette.color(id)).frame(width:9,height:9); Text("说话人 \(id + (model.current?.post?.speakerNumberOffset ?? 1))").font(.caption.bold()); Spacer(); Text("\(sentences.count)句").font(.caption).foregroundStyle(.secondary) }
       SpeakerNameEditor(speaker:id,saved:model.current?.post?.speakerNames[String(id)] ?? "",locked:locked).id("\(model.current?.id ?? "")-\(id)")
       HStack {
        Button(model.reviewSpeaker == String(id) ? "显示全部" : "只看此人") { model.reviewSpeaker = model.reviewSpeaker == String(id) ? "all" : String(id) }.buttonStyle(.borderless)
        Spacer()
        if let sample = sentences.first(where:{$0.text.count>=8}) ?? sentences.first {
         Button("试听",systemImage:"play.circle") { model.reviewQuery = ""; model.reviewSpeaker = "all"; model.focusedSentence = sample.id; model.citationScrollToken = UUID(); playback.play(at:sample.begin) }.buttonStyle(.borderless).disabled(locked)
        }
       }.font(.caption)
      }.padding(12).background(SpeakerPalette.color(id).opacity(model.reviewSpeaker == String(id) ? 0.13 : 0.05),in:RoundedRectangle(cornerRadius:9)).id(id)
     }
     if groups.isEmpty { Text("会后识别完成后，可在这里核对发言人。").font(.caption).foregroundStyle(.secondary) }
    }
   }
   .onAppear { if let id = model.speakerEditTarget { proxy.scrollTo(id,anchor:.center) } }
   .onChange(of:model.speakerEditTarget) { _,id in if let id { proxy.scrollTo(id,anchor:.center) } }
   }
   if playback.playing { Button("暂停试听",action:playback.pause).buttonStyle(.borderless) }
   if model.summaryAfterSpeakerReview {
    Text("核对后生成总结；不确定的可保留编号。").font(.caption).foregroundStyle(.secondary)
    Button("返回生成设置") { model.summaryAfterSpeakerReview = false; playback.pause(); model.requestSummary() }.buttonStyle(.borderedProminent).disabled(locked)
    Button("稍后生成") { model.summaryAfterSpeakerReview = false }.buttonStyle(.borderless)
   }
   Text("输入后按回车或点击保存，统一应用于本场同编号发言。").font(.caption).foregroundStyle(.secondary)
  }.padding(14).frame(width:235).background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:10))
 }
}

struct SummarySourcePane: View {
 @EnvironmentObject var model: Model
 var body: some View {
  VStack(alignment:.leading,spacing:12) {
   HStack {
    Text("转写原文").font(.headline); Spacer()
    Text("\(model.summaryReferenceIndex+1)/\(model.summaryReferenceIDs.count)").font(.caption).monospacedDigit()
    Button { model.summaryReferenceIndex -= 1; model.focusSummarySource() } label: { Image(systemName:"chevron.up") }.disabled(model.summaryReferenceIndex == 0).help("上一处依据")
    Button { model.summaryReferenceIndex += 1; model.focusSummarySource() } label: { Image(systemName:"chevron.down") }.disabled(model.summaryReferenceIndex+1 >= model.summaryReferenceIDs.count).help("下一处依据")
    Button { model.summarySourcesVisible = false } label: { Image(systemName:"xmark") }.help("收起原文")
   }.buttonStyle(.borderless)
   Text(model.summaryReferenceText).font(.caption).foregroundStyle(.secondary).lineLimit(3)
   if model.focusedSentence == "N1" { ScrollView { Text(model.current?.noteText ?? "").textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) } }
   else { FinalTranscriptView() }
  }.padding(.trailing,12).frame(minWidth:280,maxWidth:.infinity,maxHeight:.infinity)
 }
}

struct SpeakerNameEditor: View {
 @EnvironmentObject var model: Model
 let speaker: Int
 let saved: String
 let locked: Bool
 @State private var draft: String
 @FocusState private var focused: Bool
 init(speaker: Int, saved: String, locked: Bool) {
  self.speaker = speaker; self.saved = saved; self.locked = locked
  _draft = State(initialValue:saved)
 }
 var body: some View {
  VStack(alignment:.leading,spacing:6) {
   TextField("姓名或身份",text:$draft).textFieldStyle(.roundedBorder).focused($focused).disabled(locked).onSubmit(commit)
   if draft != saved {
    HStack { Button("保存",action:commit).disabled(locked); Button("取消") { draft = saved }; Text("未保存").font(.caption2).foregroundStyle(.secondary) }.controlSize(.small)
   }
  }
  .onAppear { if model.speakerEditTarget == speaker { focused = true } }
  .onChange(of:model.speakerEditTarget) { _, value in if value == speaker { focused = true } }
 }
 private func commit() {
  guard !locked, draft != saved else { return }
  model.renameSpeaker(speaker,to:draft); draft = draft.trimmingCharacters(in:.whitespacesAndNewlines)
 }
}
