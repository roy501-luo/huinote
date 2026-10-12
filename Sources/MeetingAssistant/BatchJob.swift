import Foundation

struct BatchJob: Codable {
 var id = UUID().uuidString
 var template: MinutesTemplate
 var pending: [String]
 var completed: [String] = []
 var failures: [String:String] = [:]
 var skipped: [String] = []
 mutating func retryFailures() {
  pending += failures.keys.filter { !pending.contains($0) && !completed.contains($0) }.sorted()
  failures = [:]
 }
 func save(root: URL) throws { try JSONEncoder().encode(self).write(to:root.appendingPathComponent("batch-job.json"),options:.atomic) }
 static func load(root: URL) throws -> Self? {
  let url = root.appendingPathComponent("batch-job.json")
  guard FileManager.default.fileExists(atPath:url.path) else { return nil }
  return try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
 }
}
