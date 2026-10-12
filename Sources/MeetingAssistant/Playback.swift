import SwiftUI
import AVFoundation

@MainActor final class MeetingPlayback: ObservableObject {
 @Published var hasPosition = false
 @Published var position = 0.0
 @Published var duration = 0.0
 @Published var playing = false
 @Published var loading = false
 @Published var failure: String?
 @Published var rate: Float = 1
 private var player: AVAudioPlayer?
 private var timer: Timer?
 private var preparation: Task<Void,Never>?
 private var generation = UUID()
 private var folder: URL?
 private var imported: URL?
 private var available = false
 func configure(folder: URL?, imported: URL?, duration: Double, enabled: Bool) {
  reset(); self.folder = folder; self.imported = imported; self.duration = duration; available = enabled
 }
 func reset() {
  generation = UUID(); preparation?.cancel(); preparation = nil
  timer?.invalidate(); timer = nil; player?.stop(); player = nil
  playing = false; loading = false; position = 0; hasPosition = false; failure = nil
 }
 func toggle() { if playing { pause() } else { play(at:position) } }
 func pause() { player?.pause(); playing = false; timer?.invalidate(); timer = nil }
 func seek(_ value: Double) {
  guard value.isFinite else { return }
  hasPosition = true
  position = min(max(0,value),duration)
  player?.currentTime = position
 }
 func play(at value: Double) {
  guard available, !loading else { return }
  if let player { seek(value >= duration ? 0 : value); resume(player); return }
  guard let folder else { failure = "没有可播放的录音"; return }
  let token = generation; let imported = imported
  loading = true; failure = nil
  preparation = Task {
   do {
    let url: URL
    if let imported { url = imported }
    else {
     let mixed = folder.appendingPathComponent("meeting-mono.wav")
     if FileManager.default.fileExists(atPath:mixed.path) { url = mixed }
     else {
      let work = Task.detached { try MeetingMix.make(folder:folder).url }
      url = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
     }
    }
    try Task.checkCancellation()
    guard generation == token else { return }
    let audio = try AVAudioPlayer(contentsOf:url)
    audio.enableRate = true; audio.prepareToPlay(); player = audio; duration = audio.duration
    loading = false; seek(value); resume(audio)
   } catch {
    guard generation == token else { return }
    loading = false; failure = "无法播放录音：\(error.localizedDescription)"
   }
  }
 }
 private func resume(_ audio: AVAudioPlayer) {
  audio.rate = rate
  guard audio.play() else { failure = "音频设备无法开始播放"; return }
  playing = true; timer?.invalidate()
  timer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in
   Task { @MainActor [weak self] in
    guard let self, let player = self.player else { return }
    self.position = player.currentTime
    if !player.isPlaying { self.position = self.duration; self.pause() }
   }
  }
 }
 func changeRate(_ value: Float) { rate = value; player?.rate = value }
}

struct MeetingPlayerView: View {
 @EnvironmentObject var player: MeetingPlayback
 @EnvironmentObject var model: Model
 var body: some View {
  VStack(spacing:10) {
   HStack(spacing:14) {
    Button { player.toggle() } label: { Image(systemName:player.playing ? "pause.fill" : "play.fill").font(.title3).frame(width:30,height:30) }.buttonStyle(.borderless).help(player.playing ? "暂停录音" : "播放录音").accessibilityLabel(player.playing ? "暂停录音" : "播放录音")
    Button { player.seek(player.position-15) } label: { Image(systemName:"gobackward.15") }.buttonStyle(.borderless).help("后退15秒")
    Slider(value:Binding(get:{player.position},set:{player.seek($0)}),in:0...max(1,player.duration)).accessibilityLabel("音频播放进度")
    Text(time(player.position)+" / "+time(player.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
    Button { player.seek(player.position+15) } label: { Image(systemName:"goforward.15") }.buttonStyle(.borderless).help("前进15秒")
    Picker("播放速度",selection:Binding(get:{player.rate},set:{player.changeRate($0)})) { ForEach([Float(0.75),1,1.25,1.5,2],id:\.self) { Text(String(format:"%g×",$0)).tag($0) } }.labelsHidden().frame(width:70)
   }.disabled(model.current == nil || model.recording || (model.busy && !model.batchRunning) || model.postProcessing || player.loading)
   if player.loading { HStack { ProgressView().controlSize(.small); Text("准备本地录音…").font(.caption) } }
   if let failure = player.failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
  }.padding(14).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
 }
 private func time(_ seconds: Double) -> String { let n = max(0,Int(seconds)); return String(format:"%02d:%02d",n/60,n%60) }
}
