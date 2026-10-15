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
  return normalize(values).filter { $0.category != "自定义" && !$0.text.hasPrefix("说话人") && text.localizedCaseInsensitiveContains($0.text) }
 }
 static let instruction = """
 同时提取检索词，JSON 增加 keywords 数组，每项 {"category":"人|时间|地点|项目|组织／学校|主题","text":"检索词"}。每段最多18项。仅从原文逐字摘取明确出现的姓名、时间表达、地点、项目名称、组织学校、核心主题短词，不编造简称、别名、身份或日期；不把说话人编号当姓名。不确定的省略。不要输出句子或泛化词如会议、讨论、方案。
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
