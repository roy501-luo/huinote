import SwiftUI

extension Model {
 func saveKeywords(_ automatic: [MeetingKeyword], manual: [MeetingKeyword]) {
  current?.keywords = MeetingKeyword.normalize(automatic)
  current?.customKeywords = MeetingKeyword.normalize(manual)
  current?.keywordsManuallyEdited = true
  save()
 }
}
struct KeywordSection: View {
 @EnvironmentObject var model: Model
 let meeting: Meeting
 @State private var editing = false
 @State private var expanded = false
 private var words: [MeetingKeyword] { MeetingKeyword.normalize((meeting.keywords ?? []) + (meeting.customKeywords ?? [])) }
 private var locked: Bool { model.recording || model.busy || model.postProcessing || model.qaBusy || model.batchRunning }
 var body: some View {
  VStack(alignment:.leading,spacing:12) {
   HStack {
    Text("检索词").font(.caption).foregroundStyle(.secondary)
    Spacer()
    Button { editing = true } label: { Image(systemName:"pencil") }.buttonStyle(.plain).help("编辑检索词").disabled(locked)
   }
   if words.isEmpty { Text(meeting.keywordsGeneratedAt == nil ? "生成总结时自动提取，可通过编辑补充。" : "未提取到明确检索词，可手动添加。").font(.caption).foregroundStyle(.secondary) }
   if !expanded {
    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),alignment:.leading),count:4),alignment:.leading,spacing:8) {
     ForEach(MeetingKeyword.featured(automatic:meeting.keywords ?? [],manual:meeting.customKeywords ?? [])) { word in
      chip(word)
     }
    }
    if words.count > 8 { Button("查看全部（\(words.count)）") { expanded = true }.font(.caption).buttonStyle(.borderless) }

   } else {
   ForEach(MeetingKeyword.categories,id:\.self) { category in
    let group = words.filter{$0.category == category}
    if !group.isEmpty {
     HStack(alignment:.top) {
      Text(category).font(.caption).foregroundStyle(.secondary).frame(width:66,alignment:.leading)
      LazyVGrid(columns:[GridItem(.adaptive(minimum:110),alignment:.leading)],alignment:.leading,spacing:8) {
       ForEach(group) { word in
        Button { model.query = word.text; model.showingSearch = true } label: {
         Text(word.text).font(.callout).lineLimit(2).padding(.horizontal,9).padding(.vertical,5).background(Color.accentColor.opacity(0.08),in:RoundedRectangle(cornerRadius:6))
        }.buttonStyle(.plain).help("搜索相关会议")
       }
      }
     }
    }
   }
    Button("收起") { expanded = false }.font(.caption)
   }
  }.onChange(of:meeting.id) { _,_ in expanded = false }.sheet(isPresented:$editing) { KeywordEditor(meeting:meeting) }
 }
 private func chip(_ word: MeetingKeyword) -> some View {
  Button { model.query = word.text; model.showingSearch = true } label: {
   Text(word.text).font(.callout).lineLimit(1).truncationMode(.tail).padding(.horizontal,9).padding(.vertical,5)
    .frame(maxWidth:.infinity,alignment:.leading).background(Color.accentColor.opacity(0.08),in:RoundedRectangle(cornerRadius:6)).contentShape(Rectangle())
  }.buttonStyle(.plain).help(word.category+"："+word.text+" · 搜索相关会议")
 }

}
private struct KeywordEditor: View {
 @EnvironmentObject var model: Model
 @Environment(\.dismiss) var dismiss
 let meeting: Meeting
 @State private var automatic: [MeetingKeyword] = []
 @State private var manual: [MeetingKeyword] = []
 @State private var category = "项目"
 @State private var word = ""
 var body: some View {
  VStack(alignment:.leading,spacing:16) {
   Text("编辑检索词").font(.title2.bold())
   Text("点击检索词可搜索会议。手动添加的词在重新生成总结时保留。").font(.caption).foregroundStyle(.secondary)
   HStack { Picker("类别",selection:$category) { ForEach(MeetingKeyword.categories,id:\.self) { Text($0).tag($0) } }.frame(width:150); TextField("检索词",text:$word).onSubmit(add); Button("添加",action:add).disabled(word.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || word.count>40) }
   ScrollView { VStack(alignment:.leading,spacing:10) {
    ForEach(MeetingKeyword.normalize(automatic + manual)) { item in
     HStack { Text(item.category).foregroundStyle(.secondary).frame(width:75,alignment:.leading); Text(item.text); Spacer(); Button("删除",role:.destructive) { automatic.removeAll{$0.id == item.id}; manual.removeAll{$0.id == item.id} } }
    }
   } }
   HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") { model.saveKeywords(automatic,manual:manual); dismiss() }.buttonStyle(.borderedProminent) }
  }.padding(24).frame(width:560,height:440).onAppear { automatic = meeting.keywords ?? []; manual = meeting.customKeywords ?? [] }
 }
 private func add() { guard word.count<=40 else { return }; manual = MeetingKeyword.normalize(manual + [.init(category:category,text:word)]); word = "" }
}
