import SwiftUI

struct SummaryDocument: View {
 @EnvironmentObject var model: Model
 let meeting: Meeting
 var isProcessing = false
 @State private var selectedChapter: Int?
 private var paragraphs: [String] {
  (meeting.post?.minutes ?? "").components(separatedBy:"\n\n").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("AI 生成草稿") && !$0.hasPrefix("模板：") }
 }
 var body: some View {
  GeometryReader { geometry in
  ScrollViewReader { proxy in
  VStack(spacing:0) {
   if geometry.size.width < 850 {
    HStack { Spacer(); Menu("章节") {
     Button("概览") { proxy.scrollTo("overview",anchor:.top) }
     ForEach(Array(paragraphs.enumerated()),id:\.offset) { index, paragraph in
      if paragraph.hasPrefix("#") { Button(String(paragraph.drop(while:{$0 == "#" || $0 == " "}))) { proxy.scrollTo("chapter-\(index)",anchor:.top) } }
     }
    }.menuStyle(.borderlessButton).fixedSize() }.padding(.horizontal,20).padding(.vertical,6)
   }
   HStack(alignment:.top,spacing:0) {
  ScrollView {
  VStack(alignment:.leading,spacing:22) {
   Text(meeting.title).font(.system(size:28,weight:.semibold)).lineSpacing(6).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).id("overview")
   VStack(alignment:.leading,spacing:10) {
    Text("会议信息").font(.system(size:17,weight:.semibold))
    HStack(alignment:.top,spacing:14) {
     Rectangle().fill(Color.primary.opacity(0.12)).frame(width:3)
     VStack(alignment:.leading,spacing:7) {
      Text("日期："+meeting.started.formatted(date:.abbreviated,time:.shortened))
      Text("时长：\(Int(meeting.duration)/60) 分钟")
      if let template = meeting.post?.minutesTemplate { Text("纪要模板："+template.name) }
     }.font(.system(size:13)).foregroundStyle(.secondary)
    }.fixedSize(horizontal:false,vertical:true)
   }
   KeywordSection(meeting:meeting)
   Divider().padding(.vertical,4)
   if paragraphs.isEmpty {
    VStack(spacing:12) {
     Text(isProcessing ? "正在处理，完成后将在这里显示总结。" : "尚未生成总结。").foregroundStyle(.secondary)
     if !isProcessing { Button(model.generateLabel,action:model.requestSummary).disabled(model.recording || model.busy || model.postProcessing || model.qaBusy || model.currentSummaryLocked) }
    }.frame(maxWidth:.infinity).padding(.vertical,24)
   }
   ForEach(Array(paragraphs.enumerated()),id:\.offset) { index, paragraph in
    Group {
    if paragraph.hasPrefix("本会议按完整资料分为") { DisclosureGroup("长会议处理说明") { Text(paragraph).font(.caption).foregroundStyle(.secondary) } }
    else if paragraph.hasPrefix("#") {
     Text(paragraph.drop(while:{$0 == "#" || $0 == " "})).font(.system(size:paragraph.hasPrefix("###") ? 17 : 21,weight:.semibold)).padding(.top,12).textSelection(.enabled)
    } else {
     VStack(alignment:.leading,spacing:12) {
      ForEach(Array(paragraph.components(separatedBy:"\n").enumerated()),id:\.offset) { _,line in
       if line.hasPrefix("- ") || line.hasPrefix("* ") {
        HStack(alignment:.top,spacing:10) {
         Text("•").foregroundStyle(.secondary).frame(width:12)
         SummaryLine(text:String(line.dropFirst(2)),meeting:meeting).frame(maxWidth:.infinity,alignment:.leading)
        }
       } else { SummaryLine(text:line,meeting:meeting).frame(maxWidth:.infinity,alignment:.leading) }
      }
     }.font(.system(size:15)).lineSpacing(7).foregroundStyle(Color.primary.opacity(0.85)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
    }
    }.id("chapter-\(index)")
   }
   Divider().padding(.top,18)
   Text("AI 生成草稿 · 请核对原文。点击时间戳试听，点击对照原文可并排核对完整依据。").font(.caption).foregroundStyle(.secondary)
  }.frame(maxWidth:860,alignment:.leading).padding(.horizontal,32).padding(.vertical,28).frame(maxWidth:.infinity,alignment:.center)
  }
   if geometry.size.width >= 850 {
    ScrollView {
     VStack(alignment:.leading,spacing:14) {
      Button("概览") { selectedChapter = nil; proxy.scrollTo("overview",anchor:.top) }
      ForEach(Array(paragraphs.enumerated()),id:\.offset) { index, paragraph in
       if paragraph.hasPrefix("#") {
        Button { selectedChapter = index; withAnimation { proxy.scrollTo("chapter-\(index)",anchor:.top) } } label: {
         Text(String(paragraph.drop(while:{$0 == "#" || $0 == " "}))).font(.caption).foregroundStyle(selectedChapter == index ? Color.accentColor : Color.secondary).multilineTextAlignment(.leading)
        }
       }
      }
     }.buttonStyle(.plain).padding(.vertical,28).padding(.horizontal,12)
    }.frame(width:150)
   }
   }
  }.onChange(of:meeting.id) { _,_ in selectedChapter = nil }
   .onAppear { if !model.summarySearchTerm.isEmpty, let index = paragraphs.firstIndex(where:{$0.localizedCaseInsensitiveContains(model.summarySearchTerm)}) { proxy.scrollTo("chapter-\(index)",anchor:.top) } }
   .onChange(of:model.summarySearchTerm) { _,term in if !term.isEmpty, let index = paragraphs.firstIndex(where:{$0.localizedCaseInsensitiveContains(term)}) { proxy.scrollTo("chapter-\(index)",anchor:.top) } }
  }
  }
 }
}

private struct SummaryLine: View {
 @EnvironmentObject var playback: MeetingPlayback
 @EnvironmentObject var model: Model
 let text: String
 let meeting: Meeting
 private var matches: [NSTextCheckingResult] { (try? NSRegularExpression(pattern:#"\[([^\]]+)\]\(#([^\)]+)\)"#))?.matches(in:text,range:NSRange(text.startIndex...,in:text)) ?? [] }
 private var references: [String] { var seen = Set<String>(); return matches.compactMap { Range($0.range(at:2),in:text).map { String(text[$0]) } }.filter { seen.insert($0).inserted } }
 private var bodyText: String { var value = text; for match in matches.reversed() { if let range = Range(match.range,in:value) { value.removeSubrange(range) } }; return value.trimmingCharacters(in:.whitespacesAndNewlines) }
 var body: some View {
  VStack(alignment:.leading,spacing:7) {
   Text(.init(bodyText))
   if !references.isEmpty {
    HStack(spacing:10) {
     ForEach(Array(references.prefix(3)),id:\.self) { id in
      if let sentence = meeting.post?.sentences.first(where:{$0.id == id}) {
       Button { model.openSummarySources(references,text:bodyText,selected:id); playback.play(at:sentence.begin) } label: { Label(sentence.timeLabel,systemImage:"play.circle") }
        .buttonStyle(.borderless).help("试听这段原话").disabled(model.recording || model.postProcessing)
      }
     }
     Button("对照原文 · \(references.count)") { model.openSummarySources(references,text:bodyText) }.buttonStyle(.borderless)
    }.font(.system(size:12)).foregroundStyle(Color.accentColor)

   }
  }.padding(.vertical,3).background(model.summarySourcesVisible && model.summaryReferenceText == bodyText ? Color.accentColor.opacity(0.06) : Color.clear,in:RoundedRectangle(cornerRadius:5))
 }
}
