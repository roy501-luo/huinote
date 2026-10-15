import SwiftUI

struct MeetingLibraryView: View {
 @EnvironmentObject var model: Model
 @Binding var selectedIDs: Set<String>
 @Binding var deletion: [Meeting]
 @State private var choosingBatch = false
 @State private var templateID = "general"
 @State private var newestFirst = true
 var rows: [Meeting] { model.libraryMeetings.sorted { newestFirst ? $0.started > $1.started : $0.started < $1.started } }
 private var eligibleCount: Int { rows.filter { selectedIDs.contains($0.id) && !($0.post?.sentences.isEmpty ?? true) }.count }
 var body: some View {
  VStack(alignment:.leading,spacing:20) {
   HStack { Text(model.libraryTitle).font(.largeTitle.bold()); Spacer(); if let current = model.current { Button("返回当前会议") { model.select(current) } } }
   HStack {
    if !selectedIDs.isEmpty {
     Toggle("全选",isOn:Binding(get:{!rows.isEmpty && rows.allSatisfy { selectedIDs.contains($0.id) }},set:{ selectedIDs = $0 ? Set(rows.map(\.id)) : [] })).toggleStyle(.checkbox)
     Text("已选 \(selectedIDs.count) 项").foregroundStyle(.secondary)
     FolderMoveMenu(ids:selectedIDs)
     Button("批量生成总结…") { choosingBatch = true }
     Button("删除已选…",role:.destructive) { deletion = rows.filter { selectedIDs.contains($0.id) } }
     Button("取消选择") { selectedIDs = [] }
    } else { Text("共 \(rows.count) 场会议").foregroundStyle(.secondary) }
    Spacer()
   }.font(.callout).frame(height:24).disabled(!model.canDelete)
   if model.batchRunning || model.postProcessing { Label("正在后台处理，可继续浏览会议。详情见左侧任务。",systemImage:"clock").font(.callout).foregroundStyle(.secondary) }
   HStack {
    Text("名称").frame(maxWidth:.infinity,alignment:.leading)
    Text("时长").frame(width:105,alignment:.leading)
    Button { newestFirst.toggle() } label: { HStack { Text("创建时间"); Image(systemName:newestFirst ? "chevron.down" : "chevron.up") } }.buttonStyle(.plain).frame(width:165,alignment:.leading)
    Color.clear.frame(width:28,height:1)
   }.font(.caption).foregroundStyle(.secondary).padding(.leading,40).padding(.trailing,14)
   Divider()
   ScrollView {
    LazyVStack(spacing:6) {
     if rows.isEmpty { Text(model.meetings.isEmpty ? "还没有会议，点击开始会议进行记录。" : "这里还没有会议，可从全部会议中选择并移动到此处。").foregroundStyle(.secondary).padding(40) }
     ForEach(rows) { meeting in
      MeetingLibraryRow(meeting:meeting,hit:model.searchHits[meeting.id],selected:selectedIDs.contains(meeting.id),selecting:!selectedIDs.isEmpty,enabled:model.canDelete,toggle:{ if selectedIDs.contains(meeting.id) { selectedIDs.remove(meeting.id) } else { selectedIDs.insert(meeting.id) } },open:{ model.select(meeting) },remove:{ deletion = [meeting] })
       .draggable("huinote-meetings:" + (selectedIDs.contains(meeting.id) ? selectedIDs.sorted().joined(separator:",") : meeting.id))
     }
    }
   }
  }.sheet(isPresented:$choosingBatch) {
   VStack(alignment:.leading,spacing:18) {
    Text("批量生成总结").font(.title2.bold())
    Text("已选 \(selectedIDs.count) 场：\(eligibleCount) 场可生成，\(selectedIDs.count-eligibleCount) 场需先转写（本次跳过）。成功后更新总结与名称；旧内容保留本地备份。")
    Picker("纪要模板",selection:$templateID) { ForEach(MinutesTemplate.all()) { Text($0.name).tag($0.id) } }
    Text(MinutesTemplate.all().first(where:{$0.id == templateID})?.instructions ?? "").font(.callout).foregroundStyle(.secondary)
    Text("逐场调用设置中的 LLM，会产生相应 API 用量。失败保留原内容，可重新选择重试。").font(.caption).foregroundStyle(.secondary)
    HStack { Spacer(); Button("取消") { choosingBatch = false }; Button("开始生成") { let selected = rows.filter { selectedIDs.contains($0.id) }; let template = MinutesTemplate.all().first(where:{$0.id == templateID}) ?? MinutesTemplate.builtins[0]; choosingBatch = false; selectedIDs = []; model.startBatchMinutes(selected,template:template) }.buttonStyle(.borderedProminent).disabled(eligibleCount == 0) }
   }.padding(24).frame(width:520)
  }.padding(32).onChange(of:rows.map(\.id)) { _,ids in selectedIDs.formIntersection(Set(ids)) }
 }
}
struct MeetingLibraryRow: View {
 @EnvironmentObject var model: Model
 let meeting: Meeting
 let hit: MeetingSearchHit?
 let selected: Bool
 let selecting: Bool
 let enabled: Bool
 let toggle: () -> Void
 let open: () -> Void
 let remove: () -> Void
 @State private var hovered = false
 var body: some View {
  HStack(spacing:12) {
   Toggle("选择“\(meeting.title)”",isOn:Binding(get:{selected},set:{_ in toggle()})).labelsHidden().toggleStyle(.checkbox).frame(width:18).opacity(hovered || selecting ? 1 : 0.35).disabled(!enabled)
   HStack(spacing:12) {
     VStack(alignment:.leading,spacing:5) { SearchHighlight(text:meeting.title,query:model.query).lineLimit(2); Text(meeting.libraryStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1); if let hit { SearchHighlight(text:"\(hit.label)：\(hit.excerpt)",query:model.query).font(.caption).foregroundStyle(.secondary).lineLimit(2) } }.frame(maxWidth:.infinity,alignment:.leading)
     Text(length).foregroundStyle(.secondary).frame(width:105,alignment:.leading)
     Text(meeting.started.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())).foregroundStyle(.secondary).font(.caption).frame(width:165,alignment:.leading)
   }.frame(maxWidth:.infinity,minHeight:48).contentShape(Rectangle())
    .onTapGesture(perform:selecting ? toggle : open).accessibilityAddTraits(.isButton).accessibilityAction { if selecting { toggle() } else { open() } }
   Menu { Button("打开会议",action:open); FolderMoveMenu(ids:[meeting.id]); Button("删除会议…",role:.destructive,action:remove) } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).frame(width:28).disabled(!enabled)
  }.padding(.horizontal,12).padding(.vertical,8).background(selected ? Color.accentColor.opacity(0.10) : hovered ? Color.primary.opacity(0.045) : Color.clear,in:RoundedRectangle(cornerRadius:7)).onHover { hovered = $0 }
   .contextMenu { Button("打开会议",action:open); FolderMoveMenu(ids:[meeting.id]); Button("删除会议…",role:.destructive,action:remove).disabled(!enabled) }
 }
 private var length: String { let seconds = max(0,Int(meeting.duration)); return seconds >= 3600 ? "\(seconds/3600)时 \((seconds/60)%60)分 \(seconds%60)秒" : "\(seconds/60)分 \(seconds%60)秒" }
}
