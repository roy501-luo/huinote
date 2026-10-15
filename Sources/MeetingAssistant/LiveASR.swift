import Foundation

protocol LiveASRTransport: Sendable {
 var taskID: String { get }
 func configure(onSentence: @escaping @Sendable (Transcript) async -> Void, onState: @escaping @Sendable (ASRState,String?,Double) async -> Void) async
 func start(_ configuration: ASRConfiguration) async throws
 func send(_ packet: AudioPacket) async
 func finish() async
 func fail(_ message: String, retryable: Bool) async
 func cancel() async
 func statistics() async -> ASRRunStatistics
 func canRetry() async -> Bool
}
extension ASRConnection: LiveASRTransport {}

// Audio callbacks never wait for a socket, an actor, or a retry timer.
final class LiveAudioRoute: @unchecked Sendable {
 private let lock = NSLock()
 private var target: (String, AudioIngress, @Sendable () -> Void)?
 private var startup: [AudioPacket] = []
 private var initial = true
 private var truncated = false
 var startupWasTruncated: Bool { lock.lock(); defer { lock.unlock() }; return truncated }
 func install(id: String, ingress: AudioIngress, overflow: @escaping @Sendable () -> Void) {
  lock.lock()
  target = (id,ingress,overflow); initial = false
  var exceeded = false
  for packet in startup { if ingress.offer(packet) == .overflow { exceeded = true } }
  startup.removeAll(); lock.unlock()
  if exceeded { overflow() }
 }
 func remove(id: String) {
  lock.lock(); if target?.0 == id { target = nil }; lock.unlock()
 }
 func push(_ packet: AudioPacket) {
  lock.lock(); let route = target
  if route == nil && initial { startup.append(packet); if startup.count > 100 { startup.removeFirst(); truncated = true } }
  lock.unlock()
  if let route, route.1.offer(packet) == .overflow { route.2() }
 }
}

struct LiveRetryPolicy {
 static func delay(_ failures: Int) -> Double { min(60, 3 * pow(2, Double(min(5,max(0,failures-1)))) ) }
}

actor LiveASRSession {
 nonisolated let route = LiveAudioRoute()
 private let configuration: ASRConfiguration
 private let factory: @Sendable () -> any LiveASRTransport
 private let sentence: @Sendable (Transcript) async -> Void
 private let status: @Sendable (String) async -> Void
 private let missing: @Sendable (String,Double,String) async -> Void
 private let recovered: @Sendable (Double) async -> Void
 private let retryDelay: @Sendable (Int) -> Double
 private var worker: Task<Void,Never>?
 private var sleeper: Task<Void,Error>?
 private var connection: (any LiveASRTransport)?
 private var ingress: AudioIngress?
 private var stopped = false
 private var audioFailed = false
 private var runs: [String:ASRRunStatistics] = [:]
 private var floor: Double
 init(configuration: ASRConfiguration, source: String, offset: Double,
      factory: (@Sendable () -> any LiveASRTransport)? = nil,
      retryDelay: @escaping @Sendable (Int) -> Double = { LiveRetryPolicy.delay($0) },
      sentence: @escaping @Sendable (Transcript) async -> Void,
      status: @escaping @Sendable (String) async -> Void,
      missing: @escaping @Sendable (String,Double,String) async -> Void,
      recovered: @escaping @Sendable (Double) async -> Void) {
  self.configuration = configuration; self.factory = factory ?? { ASRConnection(source:source) }
  self.floor = offset; self.retryDelay = retryDelay; self.sentence = sentence; self.status = status
  self.missing = missing; self.recovered = recovered
 }
 func start() { guard worker == nil else { return }; worker = Task { await run() } }
 private func run() async {
  var attempt = 0
  while !stopped {
   let socket = factory(); connection = socket
   let input = AudioIngress(); ingress = input
   let id = socket.taskID
   let route = self.route
   let missing = self.missing; let sentence = self.sentence
   let attemptFloor = floor
   await socket.configure(onSentence:sentence,onState: { state,message,end in
    if state == .failed {
     route.remove(id:id); input.finish()
     await missing(id,max(attemptFloor,end),message ?? "实时转写连接中断")
    }
   })
   // Initial connection buffers a bounded startup tail. Reconnects only accept fresh audio.
   if attempt == 0 { bind(socket,input:input) }
   await status(attempt == 0 ? "连接中 · 本地录音持续保存" : "正在恢复实时转写 · 本地录音持续保存")
   do {
    try await socket.start(configuration)
    if !stopped && attempt > 0 { bind(socket,input:input) }
    var first = true
    for await packet in input.stream {
     if first {
      first = false; floor = packet.offset
      if attempt == 0 && route.startupWasTruncated { await missing(id,attemptFloor,"启动期间实时音频未完全接入，已保留本地录音。") }
      await recovered(packet.offset)
      await status("转写中")
     }
     await socket.send(packet)
    }
   } catch { /* Transport callback records the missing interval without exposing server bodies. */ }
   route.remove(id:id); input.finish()
   if stopped { await socket.finish() }
   await socket.cancel()
   runs[id] = await socket.statistics()
   if stopped { break }
   guard await socket.canRetry() else { await status(audioFailed ? "音源中断 · 请检查麦克风或设备" : "仅本地录音 · 配置或服务错误，请检查设置"); break }
   attempt += 1
   let delay = retryDelay(attempt)
   await status("仅本地录音 · \(Int(delay))秒后自动重连")
   let sleep = Task { try await Task.sleep(nanoseconds:UInt64(max(0,delay)*1_000_000_000)) }
   sleeper = sleep
   do { try await sleep.value } catch { break }
   sleeper = nil
  }
 }
 private func bind(_ socket: any LiveASRTransport, input: AudioIngress) {
  route.install(id:socket.taskID,ingress:input) {
   Task { await socket.fail("网络发送积压超过10秒，已切换本地录音，等待自动恢复。",retryable:true) }
  }
 }
 func interruptForVerification() async { await connection?.fail("验证：主动断开转写连接，本地录音继续。",retryable:true) }
 func failAudio(_ message: String) async { audioFailed = true; await connection?.fail(message,retryable:false) }
 func finish() async -> [String:ASRRunStatistics] {
  stopped = true; sleeper?.cancel(); ingress?.finish()
  let socket = connection
  let deadline = Task {
   do { try await Task.sleep(nanoseconds:3_000_000_000) } catch { return }
   if let socket, await socket.statistics().state == ASRState.finishing.rawValue { return }
   await socket?.fail("停止时弱网发送未收齐，缺失内容等待会后补齐。",retryable:true)
  }
  await worker?.value
  deadline.cancel(); worker = nil
  return runs
 }
}

struct RepairRetryPolicy {
 static func delay(_ attempts: Int) -> Double { min(300,30 * pow(2,Double(min(4,max(0,attempts-1))))) }
 static func isTransient(_ error: Error) -> Bool {
  if let e = error as? URLError { return [.timedOut,.cannotFindHost,.cannotConnectToHost,.networkConnectionLost,.dnsLookupFailed,.notConnectedToInternet,.resourceUnavailable,.internationalRoamingOff,.dataNotAllowed].contains(e.code) }
  let message = error.localizedDescription
  return ["HTTP 408","HTTP 429","HTTP 500","HTTP 502","HTTP 503","HTTP 504","超时","网络连接"].contains(where:message.contains)
 }
}
