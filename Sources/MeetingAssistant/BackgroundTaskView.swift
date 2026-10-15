import SwiftUI

struct BackgroundTaskButton: View {
 @EnvironmentObject var model: Model
 @State private var showing = false
 private var needsAttention: Bool { model.batchRunning || model.postProcessing || !(model.batchJob?.failures.isEmpty ?? true) || !(model.batchJob?.pending.isEmpty ?? true) || model.meetings.contains { $0.automaticRepair == true } }
 private var label: String {
  if model.batchRunning || model.postProcessing { return "后台任务 · 处理中" }
  let failures = model.batchJob?.failures.count ?? 0
  if failures > 0 { return "后台任务 · \(failures) 项失败" }
  if !(model.batchJob?.pending.isEmpty ?? true) { return "后台任务 · 待继续" }
  return "等待转写补齐"
 }
 var body: some View {
  if needsAttention { Button(label,systemImage:"clock.arrow.circlepath") { showing = true }
   .sheet(isPresented:$showing) { BackgroundTaskView() }
  }
 }
}

struct BackgroundTaskView: View {
 @EnvironmentObject var model: Model
 @Environment(\.dismiss) private var dismiss
 @State private var repairs: [Meeting] = []
 var body: some View {
  VStack(alignment:.leading,spacing:18) {
   HStack { Text("后台任务").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
   Text("处理期间可以关闭此面板继续浏览会议。停止任务会保留已经完成的结果。").font(.callout).foregroundStyle(.secondary)
   ScrollView {
    VStack(alignment:.leading,spacing:18) {
     if model.postProcessing {
      GroupBox(model.keywordBackfillRunning ? "历史检索词补齐" : "单场会后处理") { HStack { Text(model.postProgress).frame(maxWidth:.infinity,alignment:.leading); Button("停止处理",action:model.cancelPostMeeting) }.padding(8) }
     }
     if let job = model.batchJob {
      GroupBox("最近一次批量总结 · " + job.template.name) {
       VStack(alignment:.leading,spacing:12) {
        Text("完成 \(job.completed.count) · 待继续 \(job.pending.count) · 失败 \(job.failures.count) · 跳过 \(job.skipped.count)")
        if model.batchRunning { ProgressView(); Text(model.batchProgress); Button("停止批量处理",action:model.cancelBatchMinutes) }
        else {
         HStack {
          if !job.pending.isEmpty { Button("继续任务",action:model.resumeBatchMinutes).disabled(!model.canDelete) }
          if !job.failures.isEmpty { Button("一键重试失败项",action:model.retryBatchFailures).disabled(!model.canDelete) }
         }
        }
        ForEach(job.failures.keys.sorted(),id:\.self) { id in
         VStack(alignment:.leading,spacing:5) {
          Text(model.meetings.first(where:{$0.id == id})?.title ?? "会议任务").fontWeight(.medium)
          Text(job.failures[id] ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
         }
        }
       }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
      }
     }
     if !repairs.isEmpty {
      GroupBox("网络恢复后自动补齐") { VStack(alignment:.leading,spacing:10) { ForEach(repairs) { meeting in
       VStack(alignment:.leading) { Text(meeting.title); Text(meeting.post?.status ?? "等待网络恢复").font(.caption).foregroundStyle(.secondary) }
      } }.frame(maxWidth:.infinity,alignment:.leading).padding(8) }
     }
     if model.batchJob == nil && !model.postProcessing && repairs.isEmpty { Text("暂无后台任务").foregroundStyle(.secondary).padding(.vertical,30) }
    }
   }
  }.padding(24).frame(width:560,height:460).onAppear { refresh() }.onChange(of:model.postProcessing) { _,_ in refresh() }
 }
 private func refresh() { repairs = ((try? model.store?.list()) ?? []).filter{$0.automaticRepair == true} }
}
