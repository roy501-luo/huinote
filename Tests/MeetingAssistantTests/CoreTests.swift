import XCTest
import AVFoundation
@testable import MeetingAssistant
final class CoreTests: XCTestCase {
 func testPersistenceAndInterruptedRecovery() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:root) }
  let id: String
  do {
   let store = try Store(root:root)
   var meeting = Meeting(title:"产品评审"); meeting.notes = "确认下周交付，负责人未明确"; meeting.status = "录音中"; id = meeting.id
   try store.save(meeting)
   meeting.notes += "。补充记录"; try store.save(meeting)
   XCTAssertEqual(try store.list().count,1)
  }
  let reopened = try Store(root:root)
  let rows = try reopened.list(query:"负责人")
  XCTAssertEqual(rows.count,1); XCTAssertEqual(rows.first?.id,id)
  XCTAssertEqual(rows.first?.status,"异常中断 · 已保留录音")
  XCTAssertTrue(rows.first?.notes.contains("补充记录") == true)
  XCTAssertEqual(try reopened.list(query:"不存在").count,0)
 }
 func testNoteOnlySavePreservesTranscriptAndSearch() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:root) }
  let store = try Store(root:root)
  var meeting = Meeting(title:"笔记性能验证")
  try store.save(meeting)
  let line = Transcript(id:"original",source:"microphone",begin:0,end:1,text:"原始转写不能丢失",final:true,gap:false)
  try store.saveTranscript(line,meetingID:meeting.id)
  meeting.noteDraft = MeetingNote(time:12)
  meeting.noteDraft?.text = "草稿保留"
  meeting.noteCards = [MeetingNote(time:12,text:"连续输入后的完整中文笔记")]
  try store.saveNotes(meeting)
  XCTAssertEqual(try store.list().first?.noteDraft?.text,meeting.noteDraft?.text)
  XCTAssertEqual(try store.search("完整中文").first?.meeting.id,meeting.id)
  XCTAssertEqual(try store.transcripts(meeting.id).first?.text,line.text)
  meeting.noteCards?[0].text = "修改后的内容"
  try store.saveNotes(meeting)
  XCTAssertTrue(try store.search("完整中文").isEmpty)
  XCTAssertEqual(try store.search("原始转写").first?.meeting.id,meeting.id)
 }
 func testAudioCopyAndTwoPlayableFiles() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:root) }
  let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
  let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800)!
  buffer.frameLength = 4800
  for i in 0..<4800 { buffer.floatChannelData![0][i] = Float(sin(Double(i)*2 * .pi * 440 / 48000))*0.25 }
  let copy = try XCTUnwrap(AudioWriter.copy(buffer))
  buffer.floatChannelData![0][100] = 0
  XCTAssertNotEqual(copy.floatChannelData![0][100],0)
  let writer = AudioWriter(); try writer.begin(folder:root)
  writer.append(copy,source:"microphone"); writer.append(copy,source:"system")
  await writer.finish()
  for source in ["microphone","system"] {
   let file = try AVAudioFile(forReading:root.appendingPathComponent("\(source)-1.caf"))
   XCTAssertEqual(file.length,4800)
   let decoded = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:4800)!
   try file.read(into:decoded)
   XCTAssertEqual(decoded.floatChannelData![0][100],copy.floatChannelData![0][100],accuracy:0.0001)
  }
 }
}
