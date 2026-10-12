import Foundation

struct PlaybackCue: Equatable {
 var id: String
 var begin: Double
 var end: Double
}
enum PlaybackTimeline {
 // Half-open intervals avoid highlighting both adjacent sentences at their shared boundary.
 // Overlapping speech may correctly highlight more than one sentence; silence highlights none.
 static func anchor(_ cues: [PlaybackCue], at time: Double) -> String? {
  guard time.isFinite else { return nil }
  if let current = active(cues,at:time).first { return current }
  let ordered = cues.filter { $0.begin.isFinite && $0.end.isFinite && $0.end > $0.begin }.sorted { $0.begin < $1.begin }
  return ordered.last(where:{$0.begin <= time})?.id ?? ordered.first?.id
 }
 static func active(_ cues: [PlaybackCue], at time: Double) -> [String] {
  guard time.isFinite else { return [] }
  return cues.filter { $0.begin.isFinite && $0.end.isFinite && $0.begin <= time && time < $0.end }.sorted { $0.begin < $1.begin }.map(\.id)
 }
}
