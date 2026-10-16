import Foundation

/// Scoped to active capture; never changes the user's power settings.
final class RecordingActivity {
 private var token: NSObjectProtocol?
 func update(recording: Bool, paused: Bool) {
  if recording && !paused {
   guard token == nil else { return }
   token = ProcessInfo.processInfo.beginActivity(
    options:[.userInitiated,.idleSystemSleepDisabled,.idleDisplaySleepDisabled],
    reason:"HuiNote 正在录音，保持音频采集与实时转写")
  } else { end() }
 }
 private func end() {
  guard let token else { return }
  ProcessInfo.processInfo.endActivity(token)
  self.token = nil
 }
 deinit { end() }
}
