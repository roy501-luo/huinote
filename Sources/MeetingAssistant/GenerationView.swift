import SwiftUI

struct GenerationButton: View {
 @EnvironmentObject var model: Model
 @EnvironmentObject var playback: MeetingPlayback
 @State private var reviewFirst = false
 private var hasTranscript: Bool { model.current?.post?.sentences.isEmpty == false }
 private var locked: Bool { model.current == nil || model.recording || model.busy || model.postProcessing || model.qaBusy || model.currentSummaryLocked }
 var body: some View {
  Button { model.requestSummary() } label: {
   Label(model.generateLabel,systemImage:locked && model.postProcessing ? "hourglass" : "sparkles")
   Image(systemName:"chevron.down").font(.caption2)
  }.accessibilityIdentifier("open-generation").disabled(locked).popover(isPresented:$model.showingGeneration,arrowEdge:.bottom) {
   VStack(alignment:.leading,spacing:16) {
    Text(model.generateLabel).font(.headline)
    Picker("纪要模板",selection:Binding(get:{model.meetingTemplate.id},set:{ id in
     if let template = MinutesTemplate.all().first(where:{$0.id == id}) { model.chooseMeetingTemplate(template) }
    })) { ForEach(MinutesTemplate.all()) { Text($0.name).tag($0.id) } }
    if hasTranscript {
     HStack {
      Text("发言人").foregroundStyle(.secondary)
      Spacer()
      Button("核对与改名") {
       model.showingGeneration = false; model.summaryAfterSpeakerReview = true; model.openSpeakerReview()
      }
     }
     Text("复用现有转写，结合已保存的笔记生成总结与检索词。").font(.caption).foregroundStyle(.secondary)
    } else {
     Toggle("转写完成后，先核对发言人",isOn:$reviewFirst)
     Text("先识别录音与说话人，再按所选模板生成总结。").font(.caption).foregroundStyle(.secondary)
    }
    if model.current?.post?.minutes.isEmpty == false {
     Text("生成成功后更新现有总结；失败时保留旧总结。").font(.caption).foregroundStyle(.secondary)
    }
    HStack {
     Button("取消") { model.showingGeneration = false }
     Spacer()
     Button(model.generateLabel) {
      playback.pause(); model.detailPage = "总结"
      model.startPostMeeting(onlyMinutes:hasTranscript,reviewBeforeSummary:!hasTranscript && reviewFirst)
     }.buttonStyle(.borderedProminent).accessibilityIdentifier("confirm-generation").disabled(locked)
    }
   }.padding(20).frame(width:340)
  }
 }
}
