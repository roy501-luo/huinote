import Foundation

struct MeetingKeyword: Codable, Hashable, Identifiable {
 var category: String
 var text: String
 var id: String { category + ":" + text.lowercased() }
 static let categories = ["人", "时间", "地点", "项目", "组织／学校", "主题", "自定义"]
 static func normalize(_ values: [Self]) -> [Self] {
  var seen = Set<String>()
  return values.compactMap { item in
   let word = item.text.trimmingCharacters(in:.whitespacesAndNewlines)
   guard categories.contains(item.category), !word.isEmpty, word.count <= 40, !word.contains("\n") else { return nil }
   let clean = Self(category:item.category,text:word)
   return seen.insert(clean.id).inserted ? clean : nil
  }
 }
 static func grounded(_ values: [Self], in lines: [EvidenceLine]) -> [Self] {
  let text = lines.map(\.text).joined(separator:"\n")
  return curated(values).filter { $0.category != "自定义" && !$0.text.hasPrefix("说话人") && text.localizedCaseInsensitiveContains($0.text) }
 }
 // Curate only machine-generated terms. User-authored terms bypass this policy.
 static func curated(_ values: [Self]) -> [Self] {
  let noise: Set<String> = ["四条","会议","讨论","方案","基座","基础组","大基座","实验室","自评","质检","编辑状态","生产失败","裂图","结构与视觉成品","随机性问题","三个地图","工作流","教学内容","教育原则","词条","知识对象","声音功能网站","声音工学科","scale","workflow","bad case"]
  var seen = Set<String>()
  let cleaned = normalize(values).compactMap { item -> Self? in
   let word = item.text
   guard item.category != "时间", !noise.contains(word.lowercased()), word.count >= 2,
         word.range(of:"^(图|表|第)\\s*[0-9０-９一二三四五六七八九十]+",options:.regularExpression) == nil,
         word.range(of:"^[A-Za-z0-9\\s._-]+$",options:.regularExpression) == nil,
         !word.hasPrefix("说话人"), seen.insert(word.lowercased()).inserted else { return nil }
   var result = item
   if result.category == "项目", !["项目","平台","系统","图谱","网站","计划","工程","中心","雷达","实验室"].contains(where:word.contains) { result.category = "主题" }
   if result.category == "组织／学校", word.hasSuffix("学科") { result.category = "主题" }
   return result
  }
  let limits = ["人":6,"项目":6,"组织／学校":5,"地点":2,"主题":5]
  var counts: [String:Int] = [:]
  return cleaned.filter { item in
   let count = counts[item.category,default:0]
   guard count < (limits[item.category] ?? 2) else { return false }
   counts[item.category] = count+1; return true
  }
 }
 static func featured(automatic: [Self], manual: [Self]) -> [Self] {
  let all = normalize(manual + automatic)
  var result = normalize(manual)
  for category in ["人","项目","组织／学校","主题","地点"] {
   result += all.filter { $0.category == category && !result.contains($0) }.prefix(2)
  }
  return Array(normalize(result + all).prefix(8))
 }
 static let instruction = """
 同时提取精选检索词，JSON 增加 keywords 数组，每项 {"category":"人|地点|项目|组织／学校|主题","text":"检索词"}。每段最多6项，宁缺毋滥。优先明确姓名、正式项目名称、明确学校组织和核心议题。仅从原文逐字摘取，不编造简称、别名、身份或日期；日期由会议元数据检索，不重复提取。项目必须是明确项目或产品专名，普通器具、课程概念不算项目。忽略章节编号、图表编号、临时操作、错误提示、泛词、零散英文和疑似转写错词。不确定的学校、项目或人名直接省略，不纠正或补全。不要把原文所有名词列成标签，不输出句子，不把说话人编号当姓名。
 """
}

extension Store {
 // One-time conversion of retired organizational folders; audio/library directories are unrelated.
 func migrateLegacyKeywords() throws {
  let old = root.appendingPathComponent("folders.json")
  guard FileManager.default.fileExists(atPath:old.path) else { return }
  struct Legacy: Decodable {
   struct Entry: Decodable { var id: String; var name: String }
   var folders: [Entry]; var locations: [String:String]
  }
  let legacy = try JSONDecoder().decode(Legacy.self,from:Data(contentsOf:old))
  for var meeting in try list() {
   guard let id = legacy.locations[meeting.id], let name = legacy.folders.first(where:{$0.id == id})?.name else { continue }
   meeting.customKeywords = MeetingKeyword.normalize((meeting.customKeywords ?? []) + [.init(category:"自定义",text:name)])
   try save(meeting)
  }
  let backup = root.appendingPathComponent("maintenance-backups",isDirectory:true)
  try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:true)
  try FileManager.default.moveItem(at:old,to:backup.appendingPathComponent("retired-folders-"+UUID().uuidString+".json"))
 }
}

extension Store {
 func curateHistoricalKeywords() throws {
  let marker = root.appendingPathComponent("keyword-curation-v2.json")
  guard !FileManager.default.fileExists(atPath:marker.path) else { return }
  let meetings = try list()
  let backup = root.appendingPathComponent("maintenance-backups/keyword-curation-"+UUID().uuidString+".json")
  try FileManager.default.createDirectory(at:backup.deletingLastPathComponent(),withIntermediateDirectories:true)
  try JSONEncoder().encode(meetings).write(to:backup,options:.atomic)
  var changed = 0
  for var meeting in meetings where meeting.keywordsManuallyEdited != true {
   guard let old = meeting.keywords else { continue }
   let cleaned = MeetingKeyword.curated(old)
   guard cleaned != old else { continue }
   meeting.keywords = cleaned
   try save(meeting)
   changed += 1
  }
  try JSONSerialization.data(withJSONObject:["changed":changed,"total":meetings.count,"backup":backup.lastPathComponent],options:.sortedKeys).write(to:marker,options:.atomic)
 }
}
