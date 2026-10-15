import SwiftUI

struct PlaudSyncButton: View {
 @EnvironmentObject var model: Model
 @State private var details = false
 var body: some View {
  Button(model.plaudSyncRunning ? "同步中…" : "同步 Plaud",systemImage:"arrow.triangle.2.circlepath") { model.syncPlaud(download:true) }
   .disabled(model.recording || model.busy || model.postProcessing || model.qaBusy || model.batchRunning)
   .contextMenu { if !model.plaudProgress.isEmpty { Button("查看最近同步结果") { details = true } } }
   .popover(isPresented:$details) { Text(model.plaudProgress).textSelection(.enabled).padding(20).frame(width:360) }
 }
}

struct PlaudSyncNotice: View {
 @EnvironmentObject var model: Model
 @State private var visible = false
 @State private var details = false
 var body: some View {
  Group {
   if visible {
    HStack(spacing:12) {
     Image(systemName:"info.circle")
     Text(model.plaudProgress.contains("未全部完成") ? "同步未完成，已导入资料保留" : "Plaud 同步完成")
     Button("详情") { details = true }.buttonStyle(.borderless)
     Button { visible = false } label: { Image(systemName:"xmark") }.buttonStyle(.plain).help("关闭提醒")
    }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).shadow(radius:6,y:2).padding(20)
   }
  }
  .onChange(of:model.plaudSyncRunning) { wasRunning,running in if wasRunning && !running { visible = true }; if running { visible = false } }
  .task(id:visible) { if visible { do { try await Task.sleep(for:.seconds(6)); if !details { visible = false } } catch {} } }
  .popover(isPresented:$details) { Text(model.plaudProgress).textSelection(.enabled).padding(20).frame(width:360) }
  .onChange(of:details) { _,showing in if !showing { visible = false } }
 }
}
