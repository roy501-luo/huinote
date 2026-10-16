import SwiftUI
import AppKit

/// Let the text view finish native selection before deciding whether this was a single click.
struct TranscriptTextClick: NSViewRepresentable {
 let text: String
 let query: String
 let highlighted: Bool
 let action: () -> Void
 func makeNSView(context: Context) -> ClickTextView {
  let view = ClickTextView()
  view.isEditable = false
  view.isSelectable = true
  view.drawsBackground = false
  view.textContainerInset = .zero
  view.textContainer?.lineFragmentPadding = 0
  view.textContainer?.widthTracksTextView = true
  view.isHorizontallyResizable = false
  view.isVerticallyResizable = true
  view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
  return view
 }
 func updateNSView(_ view: ClickTextView, context: Context) {
  view.action = action
  let style = NSMutableParagraphStyle(); style.lineSpacing = 5
  let value = NSMutableAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:NSFont.systemFontSize,weight:highlighted ? .semibold : .regular),.foregroundColor:highlighted ? NSColor.systemBlue : NSColor.labelColor,.paragraphStyle:style])
  let source = text as NSString
  for term in Set(query.split(whereSeparator:{$0.isWhitespace}).map(String.init)) {
   var range = NSRange(location:0,length:source.length)
   while range.length > 0 {
    let found = source.range(of:term,options:[.caseInsensitive,.diacriticInsensitive],range:range)
    guard found.location != NSNotFound else { break }
    value.addAttribute(.backgroundColor,value:NSColor.systemYellow.withAlphaComponent(0.45),range:found)
    range = NSRange(location:NSMaxRange(found),length:source.length-NSMaxRange(found))
   }
  }
  if view.attributedString() != value {
   let selection = view.selectedRange()
   view.textStorage?.setAttributedString(value)
   if NSMaxRange(selection) <= value.length { view.setSelectedRange(selection) }
   view.invalidateIntrinsicContentSize()
  }
 }
 func sizeThatFits(_ proposal: ProposedViewSize, nsView: ClickTextView, context: Context) -> CGSize? {
  guard let width = proposal.width, let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
  container.containerSize = NSSize(width:max(1,width),height:.greatestFiniteMagnitude)
  layout.ensureLayout(for:container)
  return CGSize(width:width,height:ceil(layout.usedRect(for:container).height))
 }
 static func dismantleNSView(_ view: ClickTextView, coordinator: ()) { view.pendingClick?.cancel(); view.action = nil }
 final class ClickTextView: NSTextView {
  var action: (() -> Void)?
  var pendingClick: DispatchWorkItem?
  override func mouseDown(with event: NSEvent) {
   pendingClick?.cancel()
   super.mouseDown(with:event)
   guard event.clickCount == 1, selectedRange().length == 0,
         !event.modifierFlags.contains(.shift) else { return }
   let task = DispatchWorkItem { [weak self] in
    guard let self, self.selectedRange().length == 0 else { return }
    self.action?()
   }
   pendingClick = task
   DispatchQueue.main.asyncAfter(deadline:.now()+NSEvent.doubleClickInterval,execute:task)
  }
 }
}
