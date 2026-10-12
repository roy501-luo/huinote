import SwiftUI

struct SummaryDocument: View {
 let meeting: Meeting
 private var paragraphs: [String] {
  (meeting.post?.minutes ?? "").components(separatedBy:"\n\n").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("AI 生成草稿") && !$0.hasPrefix("模板：") }
 }
 var body: some View {
  VStack(alignment:.leading,spacing:22) {
   Text(meeting.title).font(.system(size:28,weight:.semibold)).lineSpacing(6).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
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
   Divider().padding(.vertical,4)
   if paragraphs.isEmpty { Text("尚未生成总结。选择模板后点击“生成总结”。").foregroundStyle(.secondary).padding(.vertical,24) }
   ForEach(Array(paragraphs.enumerated()),id:\.offset) { _, paragraph in
    if paragraph.hasPrefix("#") {
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
   }
   Divider().padding(.top,18)
   Text("AI 生成草稿 · 请核对原文。点击引用编号可查看对应转写。").font(.caption).foregroundStyle(.secondary)
  }.frame(maxWidth:860,alignment:.leading).padding(.horizontal,32).padding(.vertical,28).frame(maxWidth:.infinity,alignment:.center)
 }
}

private struct SummaryLine: View {
 let text: String
 let meeting: Meeting
 private var matches: [NSTextCheckingResult] { (try? NSRegularExpression(pattern:#"\[([^\]]+)\]\(#([^\)]+)\)"#))?.matches(in:text,range:NSRange(text.startIndex...,in:text)) ?? [] }
 private var references: [String] { matches.compactMap { Range($0.range(at:2),in:text).map { String(text[$0]) } } }
 private var bodyText: String { var value = text; for match in matches.reversed() { if let range = Range(match.range,in:value) { value.removeSubrange(range) } }; return value.trimmingCharacters(in:.whitespacesAndNewlines) }
 var body: some View {
  VStack(alignment:.leading,spacing:7) {
   Text(.init(bodyText))
   if !references.isEmpty {
    DisclosureGroup("原文依据 · \(references.count) 处") {
     ScrollView(.horizontal) { HStack(spacing:12) { ForEach(Array(references.enumerated()),id:\.offset) { _,id in
      Link(id == "N1" ? "用户笔记" : (meeting.post?.sentences.first(where:{$0.id == id})?.timeLabel ?? id),destination:URL(string:"#"+id)!)
     } }.padding(.vertical,5) }
    }.font(.system(size:12)).foregroundStyle(.secondary)
   }
  }
 }
}
