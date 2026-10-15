import SwiftUI
import UniformTypeIdentifiers

struct FolderMoveMenu: View {
 @EnvironmentObject var model: Model
 let ids: Set<String>
 var body: some View {
  Menu {
   Button("未分类") { model.moveMeetings(ids,to:nil) }
   ForEach(model.folders) { folder in Button(folder.name) { model.moveMeetings(ids,to:folder.id) } }
  } label: { Label("移动到文件夹",systemImage:"folder") }
 }
}
struct LibraryNavigation: View {
 var navigationActive = true
 @EnvironmentObject var model: Model
 @State private var draft: MeetingFolder?
 @State private var name = ""
 @State private var removal: MeetingFolder?
 var body: some View {
  VStack(alignment:.leading,spacing:4) {
   destination("最近会议",icon:"clock",scope:"recent")
   destination("全部会议",icon:"square.grid.2x2",scope:"all")
   destination("未分类",icon:"tray",scope:"unfiled")
   HStack { Text("文件夹").font(.caption).foregroundStyle(.secondary); Spacer(); Button { name = ""; draft = MeetingFolder(id:UUID().uuidString,name:"") } label: { Image(systemName:"folder.badge.plus") }.buttonStyle(.plain).help("新建文件夹") }
   ScrollView {
    VStack(alignment:.leading,spacing:4) {
     ForEach(model.folders) { folder in
      destination(folder.name,icon:"folder",scope:folder.id)
       .contextMenu {
        Button("重命名…") { name = folder.name; draft = folder }
        Button("删除文件夹…",role:.destructive) { removal = folder }
       }
     }
    }
   }.frame(maxHeight:140)
  }
  .sheet(item:$draft) { folder in
   VStack(alignment:.leading,spacing:16) {
    Text(folder.name.isEmpty ? "新建文件夹" : "重命名文件夹").font(.headline)
    TextField("文件夹名称",text:$name).onSubmit { commit(folder) }
    HStack { Spacer(); Button("取消") { draft = nil }; Button("保存") { commit(folder) }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
   }.padding(24).frame(width:360)
  }
  .confirmationDialog("删除文件夹？会议将保留在未分类中。",isPresented:Binding(get:{removal != nil},set:{if !$0 { removal = nil }}),titleVisibility:.visible) {
   Button("删除文件夹，保留会议",role:.destructive) { if let removal { model.deleteFolder(removal) }; removal = nil }
  }
 }
 private func commit(_ folder: MeetingFolder) { model.saveFolder(MeetingFolder(id:folder.id,name:name)); if model.error == nil { draft = nil } }
 private func destination(_ title: String,icon: String,scope: String) -> some View {
  Button { model.showLibrary(scope) } label: {
   HStack { Image(systemName:icon).frame(width:18); Text(title).lineLimit(1); Spacer() }
    .contentShape(Rectangle())
  }.buttonStyle(SidebarButtonStyle(selected:navigationActive && model.libraryScope == scope))
   .dropDestination(for:String.self) { items,_ in
    guard scope == "unfiled" || model.folders.contains(where:{$0.id == scope}) else { return false }
    let ids = Set(items.filter{$0.hasPrefix("huinote-meetings:")}.flatMap{String($0.dropFirst("huinote-meetings:".count)).split(separator:",").map(String.init)})
    guard !ids.isEmpty else { return false }; model.moveMeetings(ids,to:scope == "unfiled" ? nil : scope); return model.error == nil
   }
 }
}
