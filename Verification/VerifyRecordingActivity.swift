import Foundation
@main struct VerifyRecordingActivity {
 static func assertions() -> String {
  let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/pmset");p.arguments=["-g","assertions"]
  let pipe=Pipe();p.standardOutput=pipe;try! p.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
  return String(decoding:data,as:UTF8.self).split(separator:"\n").filter{$0.contains("pid \(ProcessInfo.processInfo.processIdentifier)(")}.joined(separator:"\n")
 }
 static func main() {
  var activity:RecordingActivity?=RecordingActivity()
  activity!.update(recording:false,paused:false)
  assert(assertions().isEmpty)
  activity!.update(recording:true,paused:false)
  let active=assertions();print(active)
  assert(active.contains("PreventUserIdleDisplaySleep") && active.contains("PreventUserIdleSystemSleep"))
  activity!.update(recording:true,paused:false)
  assert(assertions().split(separator:"\n").count == active.split(separator:"\n").count)
  activity!.update(recording:true,paused:true)
  assert(assertions().isEmpty)
  activity!.update(recording:true,paused:false)
  assert(assertions().contains("PreventUserIdleDisplaySleep"))
  activity!.update(recording:false,paused:false)
  assert(assertions().isEmpty)
  activity!.update(recording:true,paused:false);activity=nil
  assert(assertions().isEmpty)
  print("PASS real macOS assertions: idle/start/idempotence/pause/resume/stop/deinit")
 }
}
