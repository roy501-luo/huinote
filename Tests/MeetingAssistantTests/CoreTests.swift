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
  let writer = AudioWriter(); writer.begin(folder:root)
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
