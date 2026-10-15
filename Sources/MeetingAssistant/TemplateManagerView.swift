import SwiftUI

struct TemplateManagerView: View {
 @Environment(\.dismiss) private var dismiss
 @AppStorage("minutesTemplates") private var stored = "[]"
 @AppStorage("minutesTemplateID") private var defaultID = "general"
 @State private var selectedID = "general"
 @State private var filter = ""
 @State private var draft: MinutesTemplate?
 @State private var deletion: MinutesTemplate?
 private var templates: [MinutesTemplate] { let _ = stored; return MinutesTemplate.all() }
 private var selected: MinutesTemplate { templates.first(where:{$0.id == selectedID}) ?? MinutesTemplate.builtins[0] }
 private func builtin(_ template: MinutesTemplate) -> Bool { MinutesTemplate.builtins.contains(where:{$0.id == template.id}) }
 var body: some View {
  VStack(spacing:0) {
   HStack { Text("模板").font(.title2.bold()); Spacer(); Button("新建模板",systemImage:"plus") { draft = MinutesTemplate(id:UUID().uuidString,name:"",instructions:"") }; Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(24)
   Divider()
   HStack(spacing:0) {
    VStack(alignment:.leading,spacing:12) {
     TextField("搜索模板",text:$filter).textFieldStyle(.roundedBorder)
     ScrollView {
      VStack(alignment:.leading,spacing:8) {
       ForEach([true,false],id:\.self) { isBuiltin in
        Text(isBuiltin ? "内置模板" : "我的模板").font(.caption).foregroundStyle(.secondary).padding(.top,8)
        ForEach(templates.filter{builtin($0) == isBuiltin && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.instructions.localizedCaseInsensitiveContains(filter))}) { template in
         Button { selectedID = template.id } label: {
          HStack { Text(template.name).lineLimit(2); Spacer(); if defaultID == template.id { Image(systemName:"checkmark.circle.fill").foregroundStyle(Color.accentColor) } }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(selectedID == template.id ? Color.accentColor.opacity(0.10) : Color.clear,in:RoundedRectangle(cornerRadius:7))
         }.buttonStyle(.plain).contextMenu {
          Button("设为默认") { defaultID = template.id }
          Button("复制为新模板") { copy(template) }
          if !builtin(template) { Button("编辑模板") { draft = template }; Button("删除模板…",role:.destructive) { deletion = template } }
         }
        }
       }
      }
     }
    }.padding(20).frame(width:220)
    Divider()
    VStack(alignment:.leading,spacing:18) {
     Text(selected.name).font(.title2.bold())
     Text(defaultID == selected.id ? "默认模板 · 用于未单独选择模板的新会议" : builtin(selected) ? "内置模板 · 可复制后修改" : "自定义模板").font(.caption).foregroundStyle(.secondary)
     ScrollView { Text(selected.instructions).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).lineSpacing(6) }.frame(maxHeight:.infinity)
     Text("更换默认模板不会重新生成已有总结；每场会议仍可单独选择。").font(.caption).foregroundStyle(.secondary)
     HStack {
      Button("设为默认") { defaultID = selected.id }.disabled(defaultID == selected.id)
      Button("复制") { copy(selected) }
      if !builtin(selected) { Button("编辑") { draft = selected } }
     }
    }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
   }
  }.frame(width:800,height:560).onAppear { selectedID = defaultID }
   .modifier(TemplateDeletionConfirmation(template:$deletion))
   .sheet(item:$draft) { template in MinutesTemplateEditor(template:template,onSave:{ selectedID = $0.id }) }
   .onChange(of:stored) { _,_ in if !templates.contains(where:{$0.id == selectedID}) { selectedID = defaultID } }
 }
 private func copy(_ template: MinutesTemplate) {
  let names = Set(templates.map(\.name)); var name = String(template.name.prefix(28)) + "副本"; var count = 2
  while names.contains(name) { name = String(template.name.prefix(28)) + "副本\(count)"; count += 1 }
  draft = MinutesTemplate(id:UUID().uuidString,name:name,instructions:template.instructions)
 }
}
