import SwiftUI

struct MeetingQAView: View {
 @EnvironmentObject var model: Model
 @FocusState private var inputFocused: Bool
 private var entries: [QAEntry] { (model.current?.questions ?? []).sorted { $0.created < $1.created } }
 var body: some View {
  VStack(alignment:.leading,spacing:12) {
   ScrollView {
     VStack(alignment:.leading,spacing:24) {
      if model.current?.questions?.isEmpty ?? true {
       VStack(alignment:.leading,spacing:12) {
        Text("想先了解什么？").font(.headline)
        ForEach(["归纳各位发言人的核心观点","有哪些已明确的决策？","有哪些待办，负责人和期限是什么？"],id:\.self) { prompt in
         Button(prompt) { model.question = prompt; inputFocused = true }.buttonStyle(.borderless)
        }
       }.padding(.vertical,12)
      }
      ForEach(entries) { entry in
       VStack(alignment:.leading,spacing:12) {
        Text(entry.question).font(.headline).textSelection(.enabled)
         .padding(12).frame(maxWidth:.infinity,alignment:.leading)
         .background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
        if let points = entry.points, !points.isEmpty {
         ForEach(Array(points.enumerated()),id:\.offset) { _, point in
          VStack(alignment:.leading,spacing:6) {
           Text(point.text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
           ForEach(entry.references.filter { point.sourceIDs.contains($0.source.id) }) { ref in
            Button { model.openCitation(ref) } label: {
             Text("\(ref.source.label) · \(ref.source.timeLabel) ↗").font(.caption).multilineTextAlignment(.leading)
            }.buttonStyle(.borderless).help(ref.quote)
           }
          }
         }
         DisclosureGroup("查看原文摘录") { quotes(entry) }
          .font(.caption).foregroundStyle(.secondary)
        } else {
         Text(entry.status).foregroundStyle(.secondary).textSelection(.enabled)
         quotes(entry)
        }
        if model.citationChanged(entry) { Text("原文已更新，请重新提问核对。").font(.caption).foregroundStyle(.orange) }
        if entry.coverage.contains("缺失") { Text("转写存在缺失片段，回答可能不完整。").font(.caption).foregroundStyle(.orange) }
        if entry.status != "正在检索" {
         HStack {
          Button("编辑问题") { model.question = entry.question; inputFocused = true }.buttonStyle(.borderless)
          if !entry.supported {
           Button("重试") { model.askQuestion(entry.question,replacing:entry.id) }.buttonStyle(.borderless)
            .disabled(model.qaBusy || model.busy || model.postProcessing)
          }
         }.font(.caption)
        }
       }.id(entry.id)
      }
     }.padding(.vertical,6).frame(maxWidth:.infinity,alignment:.leading)
   }.defaultScrollAnchor(.bottom).frame(maxHeight:.infinity)
   Divider()
   if model.qaBusy {
    HStack { ProgressView().controlSize(.small); Text(model.qaProgress.isEmpty ? "正在检索…" : model.qaProgress).font(.caption); Spacer(); Button("取消") { model.cancelQA() }.buttonStyle(.borderless) }
   }
   TextEditor(text:$model.question).focused($inputFocused).font(.body).scrollContentBackground(.hidden)
    .frame(height:72).padding(8).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
    .accessibilityLabel("本场问题")
   HStack {
    Spacer()
    Button("发送") { model.askQuestion() }.keyboardShortcut(.return,modifiers:.command).help("⌘回车发送，回车换行")
     .buttonStyle(.borderedProminent)
     .disabled(model.qaBusy || model.question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.current == nil || model.busy || model.postProcessing)
   }
  }.frame(maxHeight:.infinity)
 }
 @ViewBuilder private func quotes(_ entry: QAEntry) -> some View {
  ForEach(entry.references) { ref in
   Button { model.openCitation(ref) } label: {
    VStack(alignment:.leading,spacing:5) {
     Text("\(ref.source.label) · \(ref.source.timeLabel) ↗").font(.caption).foregroundStyle(Color.accentColor)
     Text(ref.quote).font(.callout).foregroundStyle(.primary).multilineTextAlignment(.leading)
    }.padding(.vertical,6).frame(maxWidth:.infinity,alignment:.leading)
   }.buttonStyle(.plain).help("跳回原文与时间点")
  }
 }
}

