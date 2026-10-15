import Foundation

private actor LiveTestLog {
 var statuses: [String] = []; var gaps: [Double] = []; var recovered: [Double] = []; var text: [Transcript] = []
 func status(_ s: String) { statuses.append(s) }
 func gap(_ s: Double) { gaps.append(s) }
 func recovery(_ s: Double) { recovered.append(s) }
 func sentence(_ s: Transcript) { text.append(s) }
 func snapshot() -> ([String],[Double],[Double],[Transcript]) { (statuses,gaps,recovered,text) }
}
private actor FakeLiveTransport: LiveASRTransport {
 nonisolated let taskID = UUID().uuidString
 private let breaks: Bool
 private var state: ASRState = .idle
 private var seconds = 0.0
 private var retry = true
 private var onState: (@Sendable (ASRState,String?,Double) async -> Void)?
 private var onSentence: (@Sendable (Transcript) async -> Void)?
 init(breaks: Bool) { self.breaks = breaks }
 func configure(onSentence: @escaping @Sendable (Transcript) async -> Void,onState: @escaping @Sendable (ASRState,String?,Double) async -> Void) { self.onSentence = onSentence; self.onState = onState }
 func start(_ configuration: ASRConfiguration) async throws { state = .running; await onState?(.running,nil,0) }
 func send(_ packet: AudioPacket) async {
  guard state == .running else { return }
  if breaks { await fail("模拟断网",retryable:true); return }
  seconds += Double(packet.data.count)/32000
  await onSentence?(Transcript(id:taskID+":"+String(packet.offset),source:"test",begin:packet.offset,end:packet.offset+0.1,text:"恢复后的新音频",final:true))
 }
 func finish() { if state == .running { state = .finished } }
 func fail(_ message: String,retryable: Bool) async { guard state != .failed && state != .finished else { return }; state = .failed; retry = retryable; await onState?(.failed,message,0) }
 func cancel() async { if state != .finished && state != .failed { await fail("取消",retryable:false) } }
 func canRetry() -> Bool { retry }
 func statistics() -> ASRRunStatistics { ASRRunStatistics(taskID:taskID,state:state.rawValue,sentSeconds:seconds,interimEvents:0,finalEvents:0) }
}
private final class LiveFactory: @unchecked Sendable {
 let lock = NSLock(); var count = 0
 func make() -> any LiveASRTransport { lock.lock(); defer { lock.unlock() }; count += 1; return FakeLiveTransport(breaks:count == 1) }
 func created() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
func verifyLiveRecovery() async throws {
 func check(_ value: Bool,_ message: String) throws { if !value { throw AppFailure(message:message) } }
 try check(ASRNetworkFailure.retryable(NSError(domain:NSPOSIXErrorDomain,code:54),httpStatus:101),"POSIX连接重置必须自动重连")
 try check(!ASRNetworkFailure.retryable(URLError(.networkConnectionLost),httpStatus:401),"鉴权错误不得反复联网")
 try check(!ASRNetworkFailure.retryable(AppFailure(message:"协议解析失败"),httpStatus:101),"协议错误不能当作断网")
 let route = LiveAudioRoute(); let buffered = AudioIngress()
 for n in 0..<3 { route.push(AudioPacket(data:Data(repeating:0,count:3200),offset:Double(n)/10)) }
 route.install(id:"startup",ingress:buffered,overflow:{})
 route.push(AudioPacket(data:Data(repeating:0,count:3200),offset:0.3)); buffered.finish()
 var offsets: [Double] = []
 for await packet in buffered.stream { offsets.append(packet.offset) }
 try check(offsets == [0,0.1,0.2,0.3],"本地录音先启动的首段必须按序进入实时转写")
 route.remove(id:"startup"); route.push(AudioPacket(data:Data(repeating:0,count:3200),offset:1))
 let restored = AudioIngress(); route.install(id:"restored",ingress:restored,overflow:{})
 route.push(AudioPacket(data:Data(repeating:0,count:3200),offset:2)); restored.finish()
 var fresh: [Double] = []; for await packet in restored.stream { fresh.append(packet.offset) }
 try check(fresh == [2],"断网恢复不可重复发送断网期间的旧音频")
 print("PASS 本地先录音的首包缓冲与断网恢复不重播")
 let factory = LiveFactory(); let log = LiveTestLog()
 let session = LiveASRSession(configuration:ASRConfiguration(endpoint:URL(string:"wss://example.invalid")!,model:"test",key:"unused"),source:"test",offset:0,factory:{ factory.make() },retryDelay:{ _ in 0.04 },sentence:{ await log.sentence($0) },status:{ await log.status($0) },missing:{ _,begin,_ in await log.gap(begin) },recovered:{ await log.recovery($0) })
 await session.start()
 for n in 0..<60 {
  session.route.push(AudioPacket(data:Data(repeating:0,count:3200),offset:Double(n)/10))
  try await Task.sleep(nanoseconds:5_000_000)
 }
 let runs = await session.finish()
 let before = factory.created()
 try await Task.sleep(nanoseconds:80_000_000)
 let observed = await log.snapshot()
 try check(runs.count == 2,"断线后应建立唯一新任务")
 try check(observed.1.count == 1 && observed.2.count == 2,"断线与恢复区间必须可追踪")
 try check(observed.2.last! > observed.2.first!,"重连时间点不得归零")
 try check(!observed.3.isEmpty && Set(observed.3.map(\.id)).count == observed.3.count,"恢复新音频且不重复句子")
 try check(factory.created() == before,"停止后不得后台重连")
 try check(observed.0.contains(where:{$0.contains("仅本地录音")}),"断网必须展示本地录音状态")
 try check(LiveRetryPolicy.delay(1) == 3 && LiveRetryPolicy.delay(100) == 60,"实时重试应有退避上限")
 try check(RepairRetryPolicy.isTransient(URLError(.notConnectedToInternet)) && !RepairRetryPolicy.isTransient(AppFailure(message:"服务请求失败（HTTP 401）")),"鉴权错误不得无限重试")
 let backoffFactory = LiveFactory()
 let backoff = LiveASRSession(configuration:ASRConfiguration(endpoint:URL(string:"wss://example.invalid")!,model:"test",key:"unused"),source:"test",offset:0,factory:{backoffFactory.make()},retryDelay:{_ in 5},sentence:{_ in},status:{_ in},missing:{_,_,_ in},recovered:{_ in})
 await backoff.start()
 for _ in 0..<20 { backoff.route.push(AudioPacket(data:Data(repeating:0,count:3200),offset:0)); try await Task.sleep(nanoseconds:5_000_000) }
 let stopTime = Date()
 _ = await backoff.finish()
 try check(Date().timeIntervalSince(stopTime)<1 && backoffFactory.created()==1,"停止必须取消重连退避等待")
 let permanent = FakeLiveTransport(breaks:false)
 let permanentSession = LiveASRSession(configuration:ASRConfiguration(endpoint:URL(string:"wss://example.invalid")!,model:"test",key:"unused"),source:"test",offset:0,factory:{permanent},retryDelay:{_ in 0.01},sentence:{_ in},status:{_ in},missing:{_,_,_ in},recovered:{_ in})
 await permanentSession.start()
 try await Task.sleep(nanoseconds:20_000_000)
 await permanentSession.failAudio("模拟不可恢复错误")
 try await Task.sleep(nanoseconds:40_000_000)
 let permanentRuns = await permanentSession.finish()
 try check(permanentRuns.count==1,"不可恢复错误必须停止自动重连")
 print("PASS 自动恢复模拟：断线降级、退避、新任务新时间点、无重复、停止不重连、鉴权错误拒绝自动重试")
}
