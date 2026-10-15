import SwiftUI

struct GlobalSearchView: View {
 @EnvironmentObject var model: Model
 @Environment(\.dismiss) private var dismiss
 @State private var term = ""
 @State private var scope = "all"
 @State private var hits: [MeetingSearchHit] = []
 @State private var failure = ""
 @FocusState private var focused: Bool
 var visible: [MeetingSearchHit] { hits.filter { scope == "all" || (scope == "unfiled" ? model.memberships[$0.meeting.id] == nil : model.memberships[$0.meeting.id] == scope) } }
 var body: some View {
  VStack(alignment:.leading,spacing:16) {
   HStack { Text("全局搜索").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
   HStack {
    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
    TextField("搜索标题、原文、总结、标记或检索词",text:$term).textFieldStyle(.plain).focused($focused).onSubmit { if let hit = visible.first { open(hit) } }
    if !term.isEmpty { Button { term = "" } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).help("清空搜索") }
   }.padding(12).background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:8))
   Picker("范围",selection:$scope) { Text("全部会议").tag("all"); Text("未分类").tag("unfiled"); ForEach(model.folders) { Text($0.name).tag($0.id) } }.frame(maxWidth:300)
   if !failure.isEmpty { Text(failure).foregroundStyle(.red) }
   ScrollView {
    LazyVStack(alignment:.leading,spacing:8) {
     if term.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
      Text("最近会议").font(.caption).foregroundStyle(.secondary)
      ForEach(model.meetings.filter { scope == "all" || (scope == "unfiled" ? model.memberships[$0.id] == nil : model.memberships[$0.id] == scope) }.prefix(12)) { meeting in
       Button { open(MeetingSearchHit(meeting:meeting,kind:"title",target:"",excerpt:"")) } label: { result(meeting,excerpt:"",label:"",query:"") }.buttonStyle(.plain).disabled(model.busy || model.qaBusy)
      }
     } else if visible.isEmpty { Text("没有找到匹配的会议").foregroundStyle(.secondary).padding(.vertical,30) }
     else {
      Text("找到 \(visible.count) 场会议 · 每场显示一处匹配").font(.caption).foregroundStyle(.secondary)
      ForEach(visible, id:\.meeting.id) { hit in
       Button { open(hit) } label: { result(hit.meeting,excerpt:hit.excerpt,label:hit.label,query:term) }.buttonStyle(.plain).disabled(model.busy || model.qaBusy)
      }
     }
    }
   }.id(term + "|" + scope)
  }.padding(24).frame(width:720,height:540)
   .onAppear { term = model.query; focused = true; search() }
   .onChange(of:term) { _,_ in search() }
 }
 private func search() { do { hits = try model.store?.search(term) ?? []; failure = "" } catch { hits = []; failure = error.localizedDescription } }
 private func result(_ meeting: Meeting,excerpt: String,label: String,query: String) -> some View {
  VStack(alignment:.leading,spacing:7) {
   SearchHighlight(text:meeting.title,query:query).fontWeight(.medium)
   Text(meeting.started.formatted(date:.abbreviated,time:.shortened) + (label.isEmpty ? "" : " · " + label)).font(.caption).foregroundStyle(.secondary)
   if !excerpt.isEmpty { SearchHighlight(text:excerpt,query:query).font(.callout).lineLimit(3).foregroundStyle(.secondary) }
  }.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
 }
 private func open(_ hit: MeetingSearchHit) {
  guard !model.busy && !model.qaBusy else { return }
  model.query = ""; model.select(hit.meeting)
  if hit.kind == "final" || hit.kind == "realtime" {
   model.showingFinal = hit.kind == "final"; model.focusedSentence = hit.target; model.citationScrollToken = UUID()
  } else if hit.kind == "minutes" || hit.kind == "keywords" { model.summarySearchTerm = hit.kind == "minutes" ? term : ""; model.detailPage = "总结" }
  else if hit.kind == "notes" { model.notesVisible = true }
  dismiss()
 }
}
