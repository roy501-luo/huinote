import SwiftUI
import AppKit

struct NoteComposer: NSViewRepresentable {
 let text: String
 let enabled: Bool
 let onChange: (String) -> Void
 let onSubmit: () -> Void
 let onImage: (Data) -> Void
 func makeCoordinator() -> Coordinator { Coordinator(self) }
 func makeNSView(context: Context) -> NSScrollView {
  let scroll = NSScrollView(); let view = Editor(); view.isRichText = false; view.drawsBackground = false; view.font = .systemFont(ofSize:13); view.textContainerInset = NSSize(width:6,height:6); view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.delegate = context.coordinator
  view.setAccessibilityLabel("速记内容，可粘贴图片"); scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
  return scroll
 }
 func updateNSView(_ scroll: NSScrollView, context: Context) {
  context.coordinator.parent = self
  guard let view = scroll.documentView as? Editor else { return }
  view.applyExternalText(text)
  view.committed = onChange
  view.isEditable = enabled; view.submit = onSubmit; view.image = onImage
 }
 final class Coordinator: NSObject, NSTextViewDelegate {
  var parent: NoteComposer; init(_ parent: NoteComposer) { self.parent = parent }
  func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView, !view.hasMarkedText() { parent.onChange(view.string) } }
 }
 final class Editor: NSTextView {
  func applyExternalText(_ text: String) {
   // Composition belongs to the input method; timer/ASR updates must not replace it.
   guard !hasMarkedText(), string != text else { return }
   let selection = selectedRange()
   string = text
   setSelectedRange(NSRange(location:min(selection.location,(text as NSString).length),length:0))
  }
  var committed: ((String) -> Void)?
  override func unmarkText() {
   super.unmarkText()
   committed?(string)
  }
  var submit: (() -> Void)?; var image: ((Data) -> Void)?
  override func keyDown(with event: NSEvent) {
   if event.keyCode == 36 && event.modifierFlags.contains(.command) && !hasMarkedText() { submit?() } else { super.keyDown(with:event) }
  }
  override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.png,.tiff] + super.readablePasteboardTypes }
  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
   if item.action == #selector(paste(_:)), isEditable, NSPasteboard.general.availableType(from:[.png,.tiff]) != nil { return true }
   return super.validateUserInterfaceItem(item)
  }
  override func paste(_ sender: Any?) {
   guard isEditable else { return }
   if let text = NSPasteboard.general.string(forType:.string), !text.isEmpty { super.paste(sender); return }
   if let data = NSPasteboard.general.data(forType:.png) ?? NSPasteboard.general.data(forType:.tiff) { image?(data) }
   else { super.paste(sender) }
  }
 }
}
