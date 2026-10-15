import Foundation
import CSQLite
import Security
import CryptoKit

struct MeetingFolder: Identifiable, Equatable { var id: String; var name: String }

struct Meeting: Identifiable, Codable {
 var id = UUID().uuidString
 var title: String = "新会议"
 var started = Date()
 var duration: Double = 0
 var notes = ""
 var noteCards: [MeetingNote]?
 var noteDraft: MeetingNote?
 var status = "未开始"
 var asrRuns: [String:ASRRunStatistics]?
 var audioCaptureIncomplete: Bool?
 var automaticRepair: Bool?
 var repairAfter: Date?
 var repairAttempts: Int?
 var post: PostRecord?
 var preferredMinutesTemplate: MinutesTemplate?
 var summaryBatchID: String?
 var questions: [QAEntry]?
 var plaud: PlaudOrigin?
 var mediaFile: String?
 var keywords: [MeetingKeyword]?
 var customKeywords: [MeetingKeyword]?
 var keywordsGeneratedAt: Date?
}
struct MeetingNote: Identifiable, Codable, Equatable {
 var id = UUID().uuidString
 var created = Date()
 var time: Double?
 var kind = "笔记"
 var text = ""
 var image: String?
 var deleted: Bool?
 var timeLabel: String { guard let time, time.isFinite else { return "会后补充" }; let t = max(0,Int(time)); return String(format:"%02d:%02d",t/60,t%60) }
 static func timestamp(recording: Bool, elapsed: Double, hasPlayback: Bool, position: Double) -> Double? {
  let value: Double? = recording ? elapsed : hasPlayback ? position : nil
  guard let value, value.isFinite else { return nil }; return max(0,value)
 }
}
extension Meeting {
 var noteText: String {
  ([notes] + (noteCards ?? []).filter { $0.deleted != true }.map { "[\($0.timeLabel)] [\($0.kind)] \($0.text)" + ($0.image == nil ? "" : "（附本地图片，未识别内容）") }).filter { !$0.isEmpty }.joined(separator:"\n")
 }
}
struct AppFailure: LocalizedError {
 let message: String
 var errorDescription: String? { message }
}
final class Store {
 static var defaultRoot: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("MeetingAssistant") }
 static var configuredRoot: URL { UserDefaults.standard.string(forKey:"libraryDirectory").map { URL(fileURLWithPath:$0) } ?? defaultRoot }
 func migrate(to destination: URL, activate: Bool = true) throws -> Store {
  let fm = FileManager.default
  let target = destination.resolvingSymlinksInPath().standardizedFileURL
  let source = root.resolvingSymlinksInPath().standardizedFileURL
  guard target != source, !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/") else { throw AppFailure(message:"请选择资料库之外的空文件夹") }
  guard (try fm.contentsOfDirectory(atPath:target.path)).isEmpty else { throw AppFailure(message:"请选择空文件夹，避免覆盖已有文件") }
  try execute("PRAGMA wal_checkpoint(TRUNCATE)")
  for item in try fm.contentsOfDirectory(at:source,includingPropertiesForKeys:nil) {
   try fm.copyItem(at:item,to:target.appendingPathComponent(item.lastPathComponent))
  }
  let enumerator = fm.enumerator(at:source,includingPropertiesForKeys:[.isRegularFileKey])!
  for case let original as URL in enumerator {
   guard try original.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true else { continue }
   let copied = target.appendingPathComponent(String(original.resolvingSymlinksInPath().path.dropFirst(source.path.count + 1)))
   guard SHA256.hash(data:try Data(contentsOf:original,options:.mappedIfSafe)) == SHA256.hash(data:try Data(contentsOf:copied,options:.mappedIfSafe)) else { throw AppFailure(message:"文件迁移校验失败，仍使用原资料库") }
  }
  let next = try Store(root:target)
  for var meeting in try next.list() {
   if let path = meeting.plaud?.directory, path.hasPrefix(source.path + "/") {
    meeting.plaud?.directory = target.path + path.dropFirst(source.path.count)
    try next.save(meeting)
   }
  }
  guard try next.list().count == list().count else { throw AppFailure(message:"迁移校验失败，仍使用原资料库") }
  if activate { UserDefaults.standard.set(target.path,forKey:"libraryDirectory") }
  return next
 }

 let root: URL
 private var db: OpaquePointer?
 init(root: URL? = nil) throws {
  if root == nil, UserDefaults.standard.string(forKey:"libraryDirectory") != nil,
     !FileManager.default.fileExists(atPath:Self.configuredRoot.appendingPathComponent("meetings.sqlite").path) {
   throw AppFailure(message:"自定义资料目录不可用，请连接对应磁盘后重新打开应用。")
  }
  self.root = root ?? Self.configuredRoot
  try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
  guard sqlite3_open(self.root.appendingPathComponent("meetings.sqlite").path, &db) == SQLITE_OK else { throw AppFailure(message: "无法打开会议数据库") }
  try execute("PRAGMA journal_mode=WAL;")
  try execute("CREATE TABLE IF NOT EXISTS meetings(id TEXT PRIMARY KEY, title TEXT NOT NULL, notes TEXT NOT NULL, data TEXT NOT NULL);")
  try execute("CREATE TABLE IF NOT EXISTS transcripts(meeting_id TEXT NOT NULL, id TEXT NOT NULL, text TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(meeting_id,id));")
  try execute("CREATE TABLE IF NOT EXISTS library_folders(id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE);")
  try execute("CREATE TABLE IF NOT EXISTS library_membership(meeting_id TEXT PRIMARY KEY,folder_id TEXT NOT NULL);")
  try prepareSearch()
  try migrateLegacyKeywords()
  // An interrupted recording remains recoverable, but is never presented as active.
  for var meeting in try list() where ["录音中","连接中","收齐转写尾部","已暂停"].contains(meeting.status) {
   meeting.status = "异常中断 · 已保留录音"
   try save(meeting)
   try saveTranscript(Transcript(id:"recovery:" + meeting.id,source:"system",begin:0,end:nil,text:"上次异常退出，转写尾部及录音完整性未经确认。",final:true,gap:true),meetingID:meeting.id)
  }
 }
 deinit { sqlite3_close(db) }
 private func execute(_ sql: String) throws {
  guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
 }
 private func failure() -> AppFailure { AppFailure(message: "数据库操作失败：" + String(cString: sqlite3_errmsg(db))) }
 private func bind(_ value: String, _ index: Int32, _ stmt: OpaquePointer?) {
  sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
 }
 func folders() throws -> [MeetingFolder] {
  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db,"SELECT id,name FROM library_folders ORDER BY name COLLATE NOCASE",-1,&stmt,nil) == SQLITE_OK else { throw failure() }
  defer { sqlite3_finalize(stmt) }
  var result: [MeetingFolder] = []
  while true {
   let status = sqlite3_step(stmt); if status == SQLITE_DONE { break }
   guard status == SQLITE_ROW else { throw failure() }
   result.append(MeetingFolder(id:String(cString:sqlite3_column_text(stmt,0)),name:String(cString:sqlite3_column_text(stmt,1))))
  }; return result
 }
 func memberships() throws -> [String:String] {
  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db,"SELECT meeting_id,folder_id FROM library_membership JOIN meetings ON meetings.id=meeting_id JOIN library_folders ON library_folders.id=folder_id",-1,&stmt,nil) == SQLITE_OK else { throw failure() }
  defer { sqlite3_finalize(stmt) }; var result: [String:String] = [:]
  while true {
   let status = sqlite3_step(stmt); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw failure() }
   result[String(cString:sqlite3_column_text(stmt,0))] = String(cString:sqlite3_column_text(stmt,1))
  }; return result
 }
 private func executeBound(_ sql: String,_ values: [String]) throws {
  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil) == SQLITE_OK else { throw failure() }
  defer { sqlite3_finalize(stmt) }; for (i,value) in values.enumerated() { bind(value,Int32(i+1),stmt) }
  guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
 }
 func saveFolder(id: String, name: String) throws {
  let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !name.isEmpty, name.count <= 60 else { throw AppFailure(message:"文件夹名称需为 1–60 个字") }
  guard !(try folders()).contains(where:{$0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame}) else { throw AppFailure(message:"已有同名文件夹") }
  try executeBound("INSERT INTO library_folders VALUES(?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name",[id,name])
 }
 func moveMeetings(_ ids: Set<String>, to folder: String?) throws {
  if let folder, !(try folders()).contains(where:{$0.id == folder}) { throw AppFailure(message:"文件夹已不存在") }
  let known = Set(try list().map(\.id))
  guard ids.isSubset(of:known) else { throw AppFailure(message:"部分会议已不存在，请刷新后重试") }
  try execute("BEGIN IMMEDIATE"); var committed = false
  defer { if !committed { try? execute("ROLLBACK") } }
  for id in ids {
   if let folder { try executeBound("INSERT INTO library_membership VALUES(?,?) ON CONFLICT(meeting_id) DO UPDATE SET folder_id=excluded.folder_id",[id,folder]) }
   else { try executeBound("DELETE FROM library_membership WHERE meeting_id=?",[id]) }
  }
  try execute("COMMIT"); committed = true
 }
 func deleteFolder(_ id: String) throws {
  try execute("BEGIN IMMEDIATE"); var committed = false
  defer { if !committed { try? execute("ROLLBACK") } }
  try executeBound("DELETE FROM library_membership WHERE folder_id=?",[id])
  try executeBound("DELETE FROM library_folders WHERE id=?",[id])
  try execute("COMMIT"); committed = true
 }
 func importedAudio(for meeting: Meeting) -> URL? {
  if let file = meeting.mediaFile, !file.contains(".."), !file.hasPrefix("/") { return root.appendingPathComponent(file) }
  return meeting.plaud.flatMap { PlaudImport.audio(in:URL(fileURLWithPath:$0.directory)) }
 }
 func save(_ meeting: Meeting) throws {
  try execute("BEGIN IMMEDIATE"); var committed = false
  defer { if !committed { try? execute("ROLLBACK") } }
  let data = String(decoding: try JSONEncoder().encode(meeting), as: UTF8.self)
  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db, "INSERT INTO meetings VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,notes=excluded.notes,data=excluded.data", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
  defer { sqlite3_finalize(stmt) }
  for (i, value) in [meeting.id,meeting.title,meeting.noteText,data].enumerated() { bind(value, Int32(i+1), stmt) }
  guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
  try indexMeeting(meeting)
  try execute("COMMIT"); committed = true
 }
 // Note typing updates only the notes search document, not every transcript sentence.
 func saveNotes(_ meeting: Meeting) throws {
  try execute("BEGIN IMMEDIATE"); var committed = false
  defer { if !committed { try? execute("ROLLBACK") } }
  let data = String(decoding:try JSONEncoder().encode(meeting),as:UTF8.self)
  try executeBound("UPDATE meetings SET notes=?,data=? WHERE id=?",[meeting.noteText,data,meeting.id])
  try indexDocument(meetingID:meeting.id,kind:"notes",target:"N1",text:meeting.noteText,revision:UUID().uuidString)
  try execute("COMMIT"); committed = true
 }
 func list(query: String = "") throws -> [Meeting] {
  if !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return try search(query).map(\.meeting) }
  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db,"SELECT data FROM meetings ORDER BY json_extract(data,'$.started') DESC",-1,&stmt,nil) == SQLITE_OK else { throw failure() }
  defer { sqlite3_finalize(stmt) }
  var results: [Meeting] = []
  while true {
   let result = sqlite3_step(stmt)
   if result == SQLITE_DONE { break }
   guard result == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { throw failure() }
   results.append(try JSONDecoder().decode(Meeting.self, from: Data(String(cString:text).utf8)))
  }
  return results
 }
 func saveTranscript(_ item: Transcript, meetingID: String, updateIndex: Bool = true) throws {
  try execute("BEGIN IMMEDIATE"); var committed = false
  defer { if !committed { try? execute("ROLLBACK") } }
  let data = String(decoding:try JSONEncoder().encode(item),as:UTF8.self)
  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db,"INSERT INTO transcripts VALUES(?,?,?,?) ON CONFLICT(meeting_id,id) DO UPDATE SET text=excluded.text,data=excluded.data",-1,&stmt,nil) == SQLITE_OK else { throw failure() }
  defer { sqlite3_finalize(stmt) }
  for (i,value) in [meetingID,item.id,item.text,data].enumerated() { bind(value,Int32(i+1),stmt) }
  guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
  if updateIndex { try indexDocument(meetingID:meetingID,kind:"realtime",target:item.id,text:item.text,revision:"") }
  try execute("COMMIT"); committed = true
 }
 func transcripts(_ meetingID: String) throws -> [Transcript] {
  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db,"SELECT data FROM transcripts WHERE meeting_id=?",-1,&stmt,nil) == SQLITE_OK else { throw failure() }
  defer { sqlite3_finalize(stmt) }; bind(meetingID,1,stmt)
  var rows: [Transcript] = []
  while true {
   let status = sqlite3_step(stmt)
   if status == SQLITE_DONE { break }
   guard status == SQLITE_ROW, let text = sqlite3_column_text(stmt,0) else { throw failure() }
   rows.append(try JSONDecoder().decode(Transcript.self,from:Data(String(cString:text).utf8)))
  }
  return rows.sorted { $0.begin == $1.begin ? $0.id < $1.id : $0.begin < $1.begin }
 }
 private func prepareSearch() throws {
  try execute("CREATE TABLE IF NOT EXISTS search_documents(id INTEGER PRIMARY KEY,meeting_id TEXT NOT NULL,kind TEXT NOT NULL,target TEXT NOT NULL,text TEXT NOT NULL,revision TEXT NOT NULL,UNIQUE(meeting_id,kind,target));")
  try execute("CREATE VIRTUAL TABLE IF NOT EXISTS meeting_fts USING fts5(text,content='search_documents',content_rowid='id',tokenize='trigram');")
  try execute("CREATE TRIGGER IF NOT EXISTS search_ai AFTER INSERT ON search_documents BEGIN INSERT INTO meeting_fts(rowid,text) VALUES(new.id,new.text); END;")
  try execute("CREATE TRIGGER IF NOT EXISTS search_ad AFTER DELETE ON search_documents BEGIN INSERT INTO meeting_fts(meeting_fts,rowid,text) VALUES('delete',old.id,old.text); END;")
  try execute("CREATE TRIGGER IF NOT EXISTS search_au AFTER UPDATE ON search_documents WHEN old.text<>new.text BEGIN INSERT INTO meeting_fts(meeting_fts,rowid,text) VALUES('delete',old.id,old.text); INSERT INTO meeting_fts(rowid,text) VALUES(new.id,new.text); END;")
  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&stmt,nil) == SQLITE_OK else { throw failure() }
  let version = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt,0) : 0; sqlite3_finalize(stmt)
  if version < 5 {
   try execute("BEGIN IMMEDIATE"); var committed = false
   defer { if !committed { try? execute("ROLLBACK") } }
   for meeting in try list() {
    try indexMeeting(meeting)
    for item in try transcripts(meeting.id) { try indexDocument(meetingID:meeting.id,kind:"realtime",target:item.id,text:item.text,revision:"") }
   }
   try execute("PRAGMA user_version=5"); try execute("COMMIT"); committed = true
  }
 }
 private func indexDocument(meetingID: String, kind: String, target: String, text: String, revision: String) throws {
  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db,"INSERT INTO search_documents(meeting_id,kind,target,text,revision) VALUES(?,?,?,?,?) ON CONFLICT(meeting_id,kind,target) DO UPDATE SET text=excluded.text,revision=excluded.revision",-1,&stmt,nil) == SQLITE_OK else { throw failure() }
  defer { sqlite3_finalize(stmt) }
  for (i,value) in [meetingID,kind,target,text,revision].enumerated() { bind(value,Int32(i+1),stmt) }
  guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
 }
 private func indexMeeting(_ meeting: Meeting) throws {
  let revision = UUID().uuidString
  let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
  let rows = [("title","",meeting.title),("date","",formatter.string(from:meeting.started)+" "+meeting.started.formatted(date:.complete,time:.omitted)),("notes","N1",meeting.noteText),("minutes","",meeting.post?.minutes ?? "")]
  try indexDocument(meetingID:meeting.id,kind:"keywords",target:"",text:MeetingKeyword.normalize((meeting.keywords ?? []) + (meeting.customKeywords ?? [])).map { $0.category+"："+$0.text }.joined(separator:" "),revision:revision)
  for (kind,target,text) in rows { try indexDocument(meetingID:meeting.id,kind:kind,target:target,text:text,revision:revision) }
  for line in meeting.post?.sentences ?? [] { try indexDocument(meetingID:meeting.id,kind:"final",target:line.id,text:(meeting.post?.name(line.speaker) ?? "")+" "+line.text,revision:revision) }
  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db,"DELETE FROM search_documents WHERE meeting_id=? AND kind<>'realtime' AND revision<>?",-1,&stmt,nil) == SQLITE_OK else { throw failure() }
  defer { sqlite3_finalize(stmt) }; bind(meeting.id,1,stmt); bind(revision,2,stmt)
  guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
 }
 func search(_ query: String) throws -> [MeetingSearchHit] {
  let terms = query.split(whereSeparator:{$0.isWhitespace}).map(String.init)
  guard !terms.isEmpty else { return [] }
  let long = terms.filter{$0.unicodeScalars.count>=3}; let short = terms.filter{$0.unicodeScalars.count<3}
  var clauses: [String] = []; var values: [String] = []
  if !long.isEmpty {
   clauses.append("meeting_fts MATCH ?")
   values.append(long.map { "\""+$0.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }.joined(separator:" AND "))
  }
  for term in short { clauses.append("instr(lower(d.text),lower(?))>0"); values.append(term) }
  let from = long.isEmpty ? "search_documents d" : "meeting_fts JOIN search_documents d ON d.id=meeting_fts.rowid"
  let snippet = "d.text"
  let order = long.isEmpty ? "json_extract(m.data,'$.started') DESC" : "bm25(meeting_fts),json_extract(m.data,'$.started') DESC"
  let sql = "SELECT m.data,d.kind,d.target,\(snippet) FROM \(from) JOIN meetings m ON m.id=d.meeting_id WHERE \(clauses.joined(separator:" AND ")) ORDER BY \(order)"
  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil) == SQLITE_OK else { throw failure() }
  defer { sqlite3_finalize(stmt) }; for (i,value) in values.enumerated() { bind(value,Int32(i+1),stmt) }
  var results: [MeetingSearchHit] = []; var seen = Set<String>()
  while true {
   let status = sqlite3_step(stmt); if status == SQLITE_DONE { break }
   guard status == SQLITE_ROW else { throw failure() }
   func text(_ col: Int32) -> String { sqlite3_column_text(stmt,col).map{String(cString:$0)} ?? "" }
   let meeting = try JSONDecoder().decode(Meeting.self,from:Data(text(0).utf8))
   if seen.insert(meeting.id).inserted {
    var excerpt = SearchExcerpt.clean(text(3))
    if let first = (short + long).first, let range = excerpt.range(of:first,options:.caseInsensitive) {
     let begin = excerpt.index(range.lowerBound,offsetBy:-30,limitedBy:excerpt.startIndex) ?? excerpt.startIndex
     let end = excerpt.index(range.upperBound,offsetBy:70,limitedBy:excerpt.endIndex) ?? excerpt.endIndex
     excerpt = String(excerpt[begin..<end])
    }
    results.append(MeetingSearchHit(meeting:meeting,kind:text(1),target:text(2),excerpt:String(excerpt.prefix(180))))
   }
  }
  return results
 }
 // Commit database removal and a durable cleanup job together; failed file cleanup can be retried.
 func deleteMeeting(_ id: String) throws { try deleteMeetings([id]) }
 func deleteMeetings(_ requested: [String]) throws {
  let ids = Set(requested)
  guard !ids.isEmpty else { return }
  guard ids.allSatisfy({UUID(uuidString:$0) != nil}) else { throw AppFailure(message:"会议编号无效，未删除任何资料") }
  try execute("CREATE TABLE IF NOT EXISTS pending_deletions(id TEXT PRIMARY KEY)")
  try execute("BEGIN IMMEDIATE"); var committed = false
  defer { if !committed { try? execute("ROLLBACK") } }
  for id in ids {
  for sql in ["DELETE FROM library_membership WHERE meeting_id=?", "DELETE FROM search_documents WHERE meeting_id=?", "DELETE FROM transcripts WHERE meeting_id=?", "DELETE FROM meetings WHERE id=?", "INSERT OR IGNORE INTO pending_deletions VALUES(?)"] {
   var stmt: OpaquePointer?
   guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil) == SQLITE_OK else { throw failure() }
   bind(id,1,stmt); let result = sqlite3_step(stmt); sqlite3_finalize(stmt)
   guard result == SQLITE_DONE else { throw failure() }
  }
  }
  try execute("COMMIT"); committed = true
  try cleanDeletedRecordings()
 }
 func cleanDeletedRecordings() throws {
  try execute("CREATE TABLE IF NOT EXISTS pending_deletions(id TEXT PRIMARY KEY)")
  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db,"SELECT id FROM pending_deletions",-1,&stmt,nil) == SQLITE_OK else { throw failure() }
  var ids: [String] = []
  while sqlite3_step(stmt) == SQLITE_ROW { ids.append(String(cString:sqlite3_column_text(stmt,0))) }
  sqlite3_finalize(stmt)
  for id in ids {
   guard UUID(uuidString:id) != nil else { continue }
   let folder = root.appendingPathComponent("Recordings").appendingPathComponent(id)
   do { if FileManager.default.fileExists(atPath:folder.path) { try FileManager.default.removeItem(at:folder) } }
   catch { throw AppFailure(message:"会议记录已删除，但录音文件清理失败；重启应用会重试。") }
   var deletion: OpaquePointer?
   guard sqlite3_prepare_v2(db,"DELETE FROM pending_deletions WHERE id=?",-1,&deletion,nil) == SQLITE_OK else { throw failure() }
   bind(id,1,deletion); let result = sqlite3_step(deletion); sqlite3_finalize(deletion)
   guard result == SQLITE_DONE else { throw failure() }
  }
 }
 func folder(_ id: String) throws -> URL {
  let url = root.appendingPathComponent("Recordings").appendingPathComponent(id)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
 }
}
enum Secrets {
 private struct Request: Codable { var operation: String; var account: String; var value: String? }
 private struct Response: Codable { var status: Int32; var value: String? }
 private static func request(_ operation: String, account: String, value: String? = nil) throws -> Response {
  guard ["asr","llm"].contains(account), let executable = Bundle.main.executableURL else { throw AppFailure(message:"密钥账户无效") }
  let helper = executable.deletingLastPathComponent().appendingPathComponent("MeetingAssistantKeychain")
  guard FileManager.default.isExecutableFile(atPath:helper.path) else { throw AppFailure(message:"钥匙串组件缺失，请重新构建完整 App") }
  let process = Process(); process.executableURL = helper
  let input = Pipe(); let output = Pipe()
  process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
  // Do not pass a caller-controlled loader or diagnostic environment to the credential component.
  process.environment = ["HOME":NSHomeDirectory(),"PATH":"/usr/bin:/bin"]
  do {
   try process.run()
   try input.fileHandleForWriting.write(contentsOf:JSONEncoder().encode(Request(operation:operation,account:account,value:value)))
   try input.fileHandleForWriting.close()
   let data = output.fileHandleForReading.readDataToEndOfFile()
   process.waitUntilExit()
   guard process.terminationStatus == 0, let response = try? JSONDecoder().decode(Response.self,from:data) else { throw AppFailure(message:"钥匙串组件验证失败，请使用固定签名的完整 App") }
   return response
  } catch let error as AppFailure { throw error }
  catch { throw AppFailure(message:"无法连接钥匙串组件") }
 }
 static func read(_ account: String) throws -> String {
  let result = try request("read",account:account)
  if result.status == errSecItemNotFound { return "" }
  guard result.status == errSecSuccess, let value = result.value else { throw AppFailure(message:"钥匙串读取失败（\(result.status)）；首次使用请选择“始终允许”，密码只在系统弹窗输入。") }
  return value
 }
 static func save(_ value: String, account: String) throws {
  let result = try request("save",account:account,value:value)
  guard result.status == errSecSuccess else { throw AppFailure(message:"钥匙串保存失败（\(result.status)）") }
 }
 static func checkAccess() throws -> String {
  var rows: [String] = []
  for account in ["asr","llm"] {
   let result = try request("probe",account:account)
   rows.append("\(account.uppercased())：" + (result.status == errSecSuccess ? "无需弹窗可读取" : result.status == errSecItemNotFound ? "未保存" : "仍需系统授权（\(result.status)）"))
  }
  return rows.joined(separator:"；")
 }
}

struct MeetingSearchHit {
 var meeting: Meeting
 var kind: String
 var target: String
 var excerpt: String
 var label: String { ["keywords":"检索词","title":"标题","date":"日期","notes":"笔记","minutes":"纪要","final":"说话人稿","realtime":"实时稿"][kind] ?? "正文" }
}

// Strip internal source links before selecting a search excerpt, so cut links never leak into the UI.
enum SearchExcerpt {
 static func clean(_ text: String) -> String {
  text.replacingOccurrences(of:#"\[[^\]]*\]\(#[^)]+\)"#,with:"",options:.regularExpression)
   .replacingOccurrences(of:#"<a\s+id=[^>]+></a>"#,with:"",options:.regularExpression)
   .replacingOccurrences(of:#"\s+"#,with:" ",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)
 }
}

extension Meeting {
 var libraryStatus: String {
  if status == "未开始" || status.contains("录音中") || status.contains("暂停") { return status }
  if automaticRepair == true { return "等待补齐转写" }
  if let state = post?.status, state.contains("失败") || state.contains("中断") || state.contains("停止") { return state }
  if post?.minutes.isEmpty == false { return "已有总结" }
  if post?.sentences.isEmpty == false { return "待生成总结" }
  return duration > 0 ? "待转写" : status
 }
}
