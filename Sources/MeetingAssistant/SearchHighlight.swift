import SwiftUI

/// Literal matching mirrors the whitespace-separated search terms, without interpreting markup.
struct SearchHighlight: View {
 let text: String
 let query: String
 private var highlighted: AttributedString {
  var result = AttributedString(text)
  for term in Set(query.split(whereSeparator: { $0.isWhitespace }).map(String.init)) {
   var start = text.startIndex
   while start < text.endIndex, let range = text.range(of:term,options:[.caseInsensitive,.diacriticInsensitive],range:start..<text.endIndex) {
    if let lower = AttributedString.Index(range.lowerBound,within:result), let upper = AttributedString.Index(range.upperBound,within:result) {
     result[lower..<upper].backgroundColor = Color.yellow.opacity(0.45)
     result[lower..<upper].foregroundColor = Color.primary
    }
    start = range.upperBound
   }
  }
  return result
 }
 var body: some View { Text(highlighted) }
}
