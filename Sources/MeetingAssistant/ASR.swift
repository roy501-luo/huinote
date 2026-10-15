import Foundation

struct Transcript: Codable, Identifiable, Equatable {
 var id: String
 var source: String
 var begin: Double
 var end: Double?
 var text: String
 var final: Bool
 var gap: Bool = false
 var timeLabel: String { let t = max(0,Int(begin)); return String(format:"%02d:%02d",t/60,t%60) }
 var sourceLabel: String { source == "system" ? "系统音频" : source == "microphone" ? "麦克风" : "录音验证" }
}
struct ASRRunStatistics: Codable {
 var taskID: String
 var state: String
 var sentSeconds: Double
 var interimEvents: Int
 var finalEvents: Int
}
struct TranscriptReducer {
 static func merge(_ incoming: Transcript, into items: inout [Transcript]) {
  if let index = items.firstIndex(where: { $0.id == incoming.id }) {
   // A delayed interim event must never overwrite a finalized sentence.
   if items[index].final && !incoming.final { return }
   items[index] = incoming
  } else { items.append(incoming) }
  items.sort { $0.begin == $1.begin ? $0.id < $1.id : $0.begin < $1.begin }
 }
}
enum ASRState: String {
 case idle = "未连接", connecting = "连接中", running = "转写中", finishing = "收齐尾部", finished = "已收齐", failed = "失败"
}
struct ASRConfiguration {
 let endpoint: URL
 let model: String
 let key: String
 static func load() throws -> ASRConfiguration {
  let defaults = UserDefaults.standard
  let endpoint = defaults.string(forKey:"asrEndpoint") ?? "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
  let model = defaults.string(forKey:"asrModel") ?? "fun-asr-realtime"
  let key = try Secrets.read("asr").trimmingCharacters(in:.whitespacesAndNewlines)
  guard !key.isEmpty else { throw AppFailure(message:"请先在设置中保存 ASR Key。") }
  guard let url = URL(string:endpoint), url.scheme == "wss", url.host != nil, url.user == nil, url.password == nil, url.query == nil else { throw AppFailure(message:"ASR Endpoint 必须是有效的 wss:// 地址，且不包含账号或查询参数。") }
  guard model.hasPrefix("fun-asr-"), model.contains("realtime") else { throw AppFailure(message:"当前仅实现 Fun-ASR-Realtime 协议，不能直接替换为 Qwen-ASR 模型。") }
  return ASRConfiguration(endpoint:url,model:model,key:key)
 }
}
struct ASREvent {
 enum Kind { case started, sentence, finished, failed, ignored }
 var kind: Kind
 var sentence: Transcript?
 var error: String?
 static func parse(_ data: Data, task: String, source: String, offset: Double) throws -> ASREvent {
  guard let json = try JSONSerialization.jsonObject(with:data) as? [String:Any],
        let header = json["header"] as? [String:Any], let event = header["event"] as? String else { throw AppFailure(message:"ASR 返回了无法解析的事件") }
  guard header["task_id"] as? String == task else { return ASREvent(kind:.ignored) }
  switch event {
  case "task-started": return ASREvent(kind:.started)
  case "task-finished": return ASREvent(kind:.finished)
  case "task-failed":
   let code = header["error_code"] as? String ?? "UnknownError"
   // Never surface raw server bodies: providers may echo request parameters.
   let knownCodes = ["InvalidApiKey", "InvalidParameter", "InvalidParameter.ValueError", "Throttling", "Throttling.RateQuota", "ModelNotFound", "AccessDenied", "InternalError", "InvalidTask", "CLIENT_ERROR", "SERVER_ERROR"]
   let safeCode = knownCodes.contains(code) ? code : "未分类错误"
   return ASREvent(kind:.failed,error:"百炼任务失败（\(safeCode)）。请检查北京地域 Key、模型权限、余额与 Endpoint。")
  case "result-generated":
   guard let payload = json["payload"] as? [String:Any], let output = payload["output"] as? [String:Any], let s = output["sentence"] as? [String:Any] else { throw AppFailure(message:"ASR 结果缺少句子字段") }
   if s["heartbeat"] as? Bool == true { return ASREvent(kind:.ignored) }
   guard let id = s["sentence_id"] as? Int, let text = s["text"] as? String, let final = s["sentence_end"] as? Bool else { throw AppFailure(message:"ASR 句子字段不完整") }
   let begin = (s["begin_time"] as? Double ?? 0)/1000 + offset
   let end = (s["end_time"] as? Double).map { $0/1000 + offset }
   return ASREvent(kind:.sentence,sentence:Transcript(id:"\(source):\(task):\(id)",source:source,begin:begin,end:end,text:text,final:final))
  default: return ASREvent(kind:.ignored)
  }
 }
}

enum ASRNetworkFailure {
 static func retryable(_ error: Error, httpStatus: Int?) -> Bool {
  if let httpStatus, [400,401,403,404].contains(httpStatus) { return false }
  if error is AppFailure || error is CancellationError { return false }
  let e = error as NSError
  if e.domain == NSURLErrorDomain {
   return ![NSURLErrorCancelled,NSURLErrorBadURL,NSURLErrorUnsupportedURL,NSURLErrorUserAuthenticationRequired,NSURLErrorSecureConnectionFailed,NSURLErrorServerCertificateUntrusted,NSURLErrorServerCertificateHasBadDate,NSURLErrorClientCertificateRequired,NSURLErrorClientCertificateRejected].contains(e.code)
  }
  // URLSession WebSockets can surface POSIX reset/closed-stream errors directly.
  if e.domain == NSPOSIXErrorDomain { return ![Int(EACCES),Int(EPERM),Int(EINVAL)].contains(e.code) }
  return true
 }
}
struct TranscriptUpdateGate {
 private var last = -Double.infinity
 mutating func accepts(final: Bool, now: Double) -> Bool {
  if final { return true }
  guard now-last >= 0.2 else { return false }
  last = now; return true
 }
}
actor ASRConnection {
 let taskID = UUID().uuidString
 let source: String
 private(set) var state: ASRState = .idle
 private(set) var failure: String?
 private(set) var lastFinalEnd: Double = 0
 private(set) var sentSeconds: Double = 0
 private(set) var interimCount = 0
 private(set) var finalCount = 0
 private var retryableFailure = true
 func canRetry() -> Bool { retryableFailure }
 private var pendingSentences = Set<String>()
 private var displayGate = TranscriptUpdateGate()
 private var offset: Double = 0
 private var offsetSet = false
 private var socket: URLSessionWebSocketTask?
 private var session: URLSession?
 private var receiver: Task<Void,Never>?
 private var timeout: Task<Void,Never>?
 private var pingLoop: Task<Void,Never>?
 private var pingTimeout: Task<Void,Never>?
 private var pingID: UUID?
 private var onSentence: (@Sendable (Transcript) async -> Void)?
 private var onState: (@Sendable (ASRState,String?,Double) async -> Void)?
 func configure(onSentence: @escaping @Sendable (Transcript) async -> Void, onState: @escaping @Sendable (ASRState,String?,Double) async -> Void) {
  self.onSentence = onSentence; self.onState = onState
 }
 func statistics() -> ASRRunStatistics { ASRRunStatistics(taskID:taskID,state:state.rawValue,sentSeconds:sentSeconds,interimEvents:interimCount,finalEvents:finalCount) }

 init(source: String) { self.source = source }
 private func transition(_ state: ASRState) async { self.state = state; await onState?(state,failure,lastFinalEnd) }
 func start(_ configuration: ASRConfiguration) async throws {
  guard state == .idle else { throw AppFailure(message:"ASR 任务不能重复启动") }
  await transition(.connecting)
  let config = URLSessionConfiguration.ephemeral
  config.timeoutIntervalForRequest = 15
  VerificationNetwork.configure(config)
  let session = URLSession(configuration:config); self.session = session
  var request = URLRequest(url:configuration.endpoint)
  request.setValue("Bearer " + configuration.key,forHTTPHeaderField:"Authorization")
  request.setValue("MeetingAssistant/0.2",forHTTPHeaderField:"User-Agent")
  let socket = session.webSocketTask(with:request); self.socket = socket; socket.resume()
  receiver = Task { [weak self] in await self?.receive() }
  armTimeout(seconds:15, message:"连接启动超时；本地录音仍可保留。")
  do {
   try await sendJSON(["header":["action":"run-task","task_id":taskID,"streaming":"duplex"],"payload":["task_group":"audio","task":"asr","function":"recognition","model":configuration.model,"parameters":["format":"pcm","sample_rate":16000,"language_hints":["zh"],"heartbeat":true,"semantic_punctuation_enabled":false],"input":[:]]])
   while state == .connecting { try await Task.sleep(nanoseconds:25_000_000) }
   guard state == .running else { throw AppFailure(message:failure ?? "ASR 未启动") }
   timeout?.cancel(); timeout = nil
   pingLoop = Task { [weak self] in
    while !Task.isCancelled {
     do { try await Task.sleep(nanoseconds:10_000_000_000) } catch { return }
     await self?.ping()
    }
   }
  } catch { if state != .failed { await fail("ASR 连接失败，请检查网络、北京地域 Key 和服务权限。",retryable:![401,403,404].contains((socket.response as? HTTPURLResponse)?.statusCode ?? 0)) }; throw AppFailure(message:failure ?? "ASR 连接失败") }
 }
 func send(_ packet: AudioPacket) async {
  while state == .idle || state == .connecting {
   do { try await Task.sleep(nanoseconds:25_000_000) } catch { return }
  }
  guard state == .running, let socket else { return }
  if !offsetSet { offset = packet.offset; lastFinalEnd = offset; offsetSet = true }
  // Packet timestamps reflect the common meeting clock; excessive capture gaps are explicit.
  let expected = offset + sentSeconds
  if abs(packet.offset-expected) > 0.35 { await fail("音频时间线中断；从最后确认位置起的实时稿可能缺失，本地录音已保留。"); return }
  armTimeout(seconds:10,message:"音频发送超时；后续实时转写缺失，本地录音继续。")
  do { try await socket.send(.data(packet.data)); sentSeconds += Double(packet.data.count)/32000; timeout?.cancel(); timeout = nil }
  catch { await fail("ASR 音频连接中断；后续实时转写缺失，本地录音继续。") }
 }
 func finish() async {
  guard state == .running else { return }
  await transition(.finishing)
  armTimeout(seconds:20,message:"尾部结果等待超时，未确认部分已标记缺失。")
  do {
   try await sendJSON(["header":["action":"finish-task","task_id":taskID,"streaming":"duplex"],"payload":["input":[:]]])
   while state == .finishing { try await Task.sleep(nanoseconds:25_000_000) }
  } catch { await fail("结束任务失败，尾部结果可能缺失。") }
 }
 func fail(_ message: String, retryable: Bool = true) async {
  guard state != .failed && state != .finished else { return }
  retryableFailure = retryable
  failure = message; state = .failed; close(); await onState?(.failed,failure,lastFinalEnd)
 }
 func cancel() async { if state != .finished && state != .failed { await fail("转写任务已取消，未确认结果可能缺失。") }; close() }
 private func ping() {
  guard state == .running, let socket else { return }
  let id = UUID(); pingID = id
  pingTimeout?.cancel()
  pingTimeout = Task { [weak self] in
   do { try await Task.sleep(nanoseconds:8_000_000_000) } catch { return }
   await self?.fail("网络心跳超时，切换本地录音并自动重连。")
  }
  socket.sendPing { [weak self] error in Task { await self?.pingCompleted(id,error:error) } }
 }
 private func pingCompleted(_ id: UUID,error: Error?) async {
  guard pingID == id else { return }
  pingTimeout?.cancel(); pingTimeout = nil; pingID = nil
  if error != nil { await fail("网络心跳中断，切换本地录音并自动重连。") }
 }
 private func close() {
  pingLoop?.cancel(); pingLoop = nil; pingTimeout?.cancel(); pingTimeout = nil; pingID = nil
  timeout?.cancel(); timeout = nil
  socket?.cancel(with:.normalClosure,reason:nil); socket = nil
  receiver?.cancel(); receiver = nil
  session?.invalidateAndCancel(); session = nil
 }
 private func armTimeout(seconds: Double,message: String) {
  timeout?.cancel()
  timeout = Task { [weak self] in
   do { try await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) } catch { return }
   await self?.fail(message)
  }
 }
 private func sendJSON(_ object: [String:Any]) async throws {
  let data = try JSONSerialization.data(withJSONObject:object)
  guard let socket else { throw AppFailure(message:"连接已关闭") }
  try await socket.send(.string(String(decoding:data,as:UTF8.self)))
 }
 private func receive() async {
  do {
   while !Task.isCancelled, let socket {
    let message = try await socket.receive()
    let data: Data
    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
    let event = try ASREvent.parse(data,task:taskID,source:source,offset:offset)
    switch event.kind {
    case .started: if state == .connecting { await transition(.running) }
    case .sentence:
     if let sentence = event.sentence, state == .running || state == .finishing {
      if sentence.final { pendingSentences.remove(sentence.id) } else { pendingSentences.insert(sentence.id) }
      if sentence.final { lastFinalEnd = max(lastFinalEnd,sentence.end ?? sentence.begin); finalCount += 1 } else { interimCount += 1 }
      if displayGate.accepts(final:sentence.final,now:ProcessInfo.processInfo.systemUptime) { await onSentence?(sentence) }
     }
    case .finished:
     guard state == .finishing else { await fail("服务提前结束任务，后续转写缺失。"); return }
     guard pendingSentences.isEmpty else { await fail("服务结束仍有未确认句子，将由会后录音补齐。",retryable:false); return }
     await transition(.finished); close(); return
    case .failed: await fail(event.error ?? "ASR 任务失败",retryable:["InternalError","SERVER_ERROR","Throttling"].contains(where:{event.error?.contains($0) == true})); return
    case .ignored: break
    }
   }
  } catch {
   if state != .finished && state != .failed { await fail("ASR 连接中断或协议错误。未确认结果已标记缺失。",retryable:ASRNetworkFailure.retryable(error,httpStatus:(socket?.response as? HTTPURLResponse)?.statusCode)) }
  }
 }
}

struct AudioPacket: Sendable { let data: Data; let offset: Double }
// Thread-safe bounded ingress. A slow socket cannot grow an unlimited audio backlog.
final class AudioIngress: @unchecked Sendable {
 let stream: AsyncStream<AudioPacket>
 private let continuation: AsyncStream<AudioPacket>.Continuation
 private let lock = NSLock()
 private var closed = false
 enum Offer { case accepted, overflow, closed }
 init() {
  var captured: AsyncStream<AudioPacket>.Continuation!
  stream = AsyncStream(bufferingPolicy:.bufferingOldest(100)) { captured = $0 }
  continuation = captured
 }
 func offer(_ packet: AudioPacket) -> Offer {
  lock.lock(); defer { lock.unlock() }
  guard !closed else { return .closed }
  switch continuation.yield(packet) {
  case .enqueued: return .accepted
  case .dropped: closed = true; continuation.finish(); return .overflow
  case .terminated: closed = true; return .closed
  @unknown default: closed = true; continuation.finish(); return .overflow
  }
 }
 func yield(_ packet: AudioPacket) -> Bool { offer(packet) == .accepted }
 func finish() { lock.lock(); defer { lock.unlock() }; closed = true; continuation.finish() }
}

// Development-only opaque CONNECT proxy; no credentials or TLS plaintext are logged.
// Enabled only by explicit launch arguments, never stored as an application preference.
enum VerificationNetwork {
 static func configure(_ configuration: URLSessionConfiguration) {
  let args = CommandLine.arguments
  guard args.contains("--verify-network"), let index = args.firstIndex(of:"--verify-network-proxy-port"), args.indices.contains(index+1), let port = Int(args[index+1]), (1024...65535).contains(port) else { return }
  configuration.connectionProxyDictionary = ["HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":port,"HTTPSEnable":1,"HTTPSProxy":"127.0.0.1","HTTPSPort":port]
 }
}
