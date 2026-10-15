import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Model {
 var notesLocked: Bool { current == nil || currentSummaryLocked || qaBusy || postProcessing }
 func changeNotes(_ change: (inout Meeting) -> Void) {
  guard !notesLocked, var meeting = current, store != nil else { return }
  change(&meeting); current = meeting; notesDirty = true
  noteSaveTask?.cancel()
  noteSaveTask = Task { [weak self] in
   do { try await Task.sleep(nanoseconds:350_000_000) } catch { return }
   self?.flushNotes()
  }
 }
 func flushNotes() {
  noteSaveTask?.cancel(); noteSaveTask = nil
  guard notesDirty, let meeting = current, let store else { return }
  do {
   try store.saveNotes(meeting); notesDirty = false
   if let index = meetings.firstIndex(where:{$0.id == meeting.id}) { meetings[index] = meeting }
   searchHits = [:]
  } catch { self.error = "笔记保存失败：" + error.localizedDescription }
 }
 func addNote(kind: String = "笔记", time: Double?, imageData: Data? = nil) {
  guard !notesLocked, var meeting = current, let store else { return }
  flushNotes()
  var note = kind == "笔记" && imageData == nil ? meeting.noteDraft ?? MeetingNote(time:time) : MeetingNote(time:time,kind:kind)
  note.text = note.text.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !note.text.isEmpty || kind != "笔记" || imageData != nil else { return }
  var written: URL?
  do {
   if let imageData {
    guard imageData.count <= 30_000_000, let bitmap = NSBitmapImageRep(data:imageData), bitmap.pixelsWide <= 16000, bitmap.pixelsHigh <= 16000,
          let png = bitmap.representation(using:.png,properties:[:]) else { throw AppFailure(message:"图片过大或格式无法读取，请使用 PNG/JPEG 截图（30 MB 以内）") }
    let relative = "Recordings/\(meeting.id)/Notes/\(note.id).png"
    let url = store.root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
    try png.write(to:url,options:.atomic); written = url; note.image = relative; note.kind = "图片"
   }
   meeting.noteCards = (meeting.noteCards ?? []) + [note]
   if kind == "笔记" && imageData == nil { meeting.noteDraft = nil }
   try store.save(meeting); current = meeting; reload()
  } catch { if let written { try? FileManager.default.removeItem(at:written) }; self.error = error.localizedDescription }
 }
}

struct MeetingNotesView: View {
 @EnvironmentObject var model: Model
 @EnvironmentObject var playback: MeetingPlayback
 @State private var expanded = false
 @State private var targeted = false
 @State private var preview: String?
 private var stamp: Double? { MeetingNote.timestamp(recording:model.viewingRecording,elapsed:model.elapsed,hasPlayback:playback.hasPosition,position:playback.position) }
 private var cards: [MeetingNote] { (model.current?.noteCards ?? []).filter { $0.deleted != true } }
 var body: some View {
  let editingMeetingID = model.current?.id
  VStack(alignment:.leading,spacing:10) {
   HStack {
    Button { model.notesVisible.toggle() } label: { Label(cards.isEmpty ? "会议标记" : "会议标记 · \(cards.count)",systemImage:model.notesVisible ? "chevron.down" : "chevron.right") }.buttonStyle(.plain).foregroundStyle(.secondary)
    Spacer()
    if model.notesVisible { Button { expanded.toggle() } label: { Image(systemName:expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help(expanded ? "收起标记区域" : "展开标记区域") }
   }
   if model.notesVisible {
    ScrollViewReader { proxy in
     ScrollView {
      LazyVStack(alignment:.leading,spacing:16) {
       ForEach(cards) { note in NoteCardView(note:note,onPreview:{ preview = $0 }) }
       VStack(alignment:.leading,spacing:2) {
        if let draft = model.current?.noteDraft { Text(draft.timeLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
        ZStack(alignment:.topLeading) {
         if (model.current?.noteDraft?.text ?? "").isEmpty { Text("点击输入内容，⌘ + ↵ 记下").foregroundStyle(.tertiary).padding(.leading,25).padding(.top,6).allowsHitTesting(false) }
         HStack(alignment:.top,spacing:4) {
          Image(systemName:"pencil").foregroundStyle(.secondary).padding(.top,7)
          NoteComposer(text:model.current?.noteDraft?.text ?? "",enabled:!model.notesLocked,onChange:{ text in
           guard model.current?.id == editingMeetingID else { return }
           let time = stamp
           model.changeNotes { meeting in
            if meeting.noteDraft == nil { meeting.noteDraft = MeetingNote(time:time) }
            meeting.noteDraft?.text = text
            if text.isEmpty { meeting.noteDraft = nil }
           }
          },onSubmit:{ model.addNote(time:stamp) },onImage:{ model.addNote(time:stamp,imageData:$0) }).id(editingMeetingID).frame(height:58)
         }
        }
       }.id("composer")
      }.padding(.vertical,4)
     }.frame(height:model.viewingRecording ? 210 : expanded ? 180 : 100)
     .onAppear { proxy.scrollTo("composer",anchor:.bottom) }
     .onChange(of:model.current?.id) { _ in proxy.scrollTo("composer",anchor:.bottom) }
     .onChange(of:cards.count) { _ in withAnimation { proxy.scrollTo("composer",anchor:.bottom) } }
    }
    HStack(spacing:12) {
     Text(model.current?.noteDraft?.timeLabel ?? MeetingNote(time:stamp).timeLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary)
     Spacer()
     Button { model.addNote(kind:"标记",time:stamp) } label: { Image(systemName:"flag") }.help("标记当前时刻").accessibilityLabel("标记当前时刻")
     Button { chooseImage() } label: { Image(systemName:"photo.badge.plus") }.help("添加图片，也可直接粘贴或拖入").accessibilityLabel("添加图片")
    }.disabled(model.notesLocked)
   }
  }
  .onChange(of:model.recording) { _, recording in model.notesVisible = recording }
  .onChange(of:model.current?.id) { _,_ in model.notesVisible = model.viewingRecording }
  .overlay { if targeted { RoundedRectangle(cornerRadius:8).stroke(Color.accentColor,lineWidth:2).allowsHitTesting(false) } }
  .onDrop(of:[UTType.fileURL.identifier,UTType.png.identifier,UTType.tiff.identifier,UTType.jpeg.identifier],isTargeted:$targeted,perform:drop)
  .sheet(item:Binding(get: { preview.map { NoteImagePreview(path:$0) } },set:{ preview = $0?.path })) { item in
   VStack { HStack { Text("笔记图片").font(.headline); Spacer(); Button("关闭") { preview = nil } }; if let root = model.store?.root, let image = NSImage(contentsOf:root.appendingPathComponent(item.path)) { Image(nsImage:image).resizable().scaledToFit() } }.padding(20).frame(width:700,height:500)
  }
 }
 private func chooseImage() {
  let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg,.tiff]; panel.allowsMultipleSelection = true
  let time = stamp
  if panel.runModal() == .OK { for url in panel.urls { do { model.addNote(time:time,imageData:try Data(contentsOf:url)) } catch { model.error = error.localizedDescription } } }
 }
 private func drop(_ providers: [NSItemProvider]) -> Bool {
  guard !model.notesLocked else { return false }
  let meetingID = model.current?.id, time = stamp
  for provider in providers {
   let type = [UTType.fileURL.identifier,UTType.png.identifier,UTType.tiff.identifier,UTType.jpeg.identifier].first { provider.hasItemConformingToTypeIdentifier($0) }
   guard let type else { continue }
   provider.loadDataRepresentation(forTypeIdentifier:type) { data,error in
    Task { @MainActor in
     guard model.current?.id == meetingID else { model.error = "会议已切换，请在目标会议重新拖入图片"; return }
     do {
      if let error { throw error }; guard let data else { throw AppFailure(message:"无法读取拖入的图片") }
      if type == UTType.fileURL.identifier {
       guard let url = URL(dataRepresentation:data,relativeTo:nil), url.isFileURL else { throw AppFailure(message:"请选择本地图片") }
       let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
       model.addNote(time:time,imageData:try Data(contentsOf:url))
      } else { model.addNote(time:time,imageData:data) }
     } catch { model.error = error.localizedDescription }
    }
   }
  }
  return true
 }
}
private struct NoteImagePreview: Identifiable { let path: String; var id: String { path } }

private struct NoteCardView: View {
 @EnvironmentObject var model: Model
 @EnvironmentObject var playback: MeetingPlayback
 let note: MeetingNote
 let onPreview: (String) -> Void
 @State private var thumbnail: NSImage?
 var body: some View {
  VStack(alignment:.leading,spacing:6) {
   HStack(spacing:6) {
    Image(systemName:note.image != nil ? "photo" : note.kind == "标记" ? "flag" : "pencil")
    if let time = note.time { Button(note.timeLabel) { model.reviewQuery = ""; model.reviewSpeaker = "all"; model.focusedSentence = model.current?.post?.sentences.last(where:{$0.begin <= time})?.id; model.citationScrollToken = UUID(); playback.play(at:time) }.buttonStyle(.plain).disabled(model.recording || model.postProcessing) }
    else { Text(note.timeLabel) }
    Spacer()
   }.font(.caption).foregroundStyle(.secondary)
   TextField(note.kind == "标记" ? "添加标记说明" : "随手记下你的灵感和重点",text:Binding(get:{note.text},set:{ value in model.changeNotes { meeting in if let i = meeting.noteCards?.firstIndex(where:{$0.id == note.id}) { meeting.noteCards?[i].text = value } } }),axis:.vertical)
    .textFieldStyle(.plain).disabled(model.notesLocked).padding(.leading,20)
   if let path = note.image, let thumbnail { Button { onPreview(path) } label: { Image(nsImage:thumbnail).resizable().scaledToFit().frame(maxWidth:240,maxHeight:100,alignment:.leading) }.buttonStyle(.plain).help("查看图片").padding(.leading,20) }
  }.frame(maxWidth:.infinity,alignment:.leading)
  .contextMenu { Button("删除标记",role:.destructive) { model.changeNotes { meeting in if let i = meeting.noteCards?.firstIndex(where:{$0.id == note.id}) { meeting.noteCards?[i].deleted = true } } }.disabled(model.notesLocked) }
  .task(id:note.image) { if let path = note.image, let root = model.store?.root { thumbnail = NSImage(contentsOf:root.appendingPathComponent(path)) } }
 }
}

