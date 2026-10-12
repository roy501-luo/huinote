import SwiftUI
import AppKit

// Observe actual user input inside this transcript viewport. Programmatic scrollTo never
// emits these events, so automatic scrolling cannot turn itself off.
struct TranscriptScrollObserver: NSViewRepresentable {
 var onManualScroll: () -> Void
 func makeNSView(context: Context) -> NSView {
  let view = NSView(); context.coordinator.view = view
  context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching:[.scrollWheel,.leftMouseDown,.keyDown]) { [weak coordinator = context.coordinator] event in
   guard let coordinator, let view = coordinator.view, let window = view.window, event.window === window else { return event }
   let point = view.convert(event.locationInWindow,from:nil)
   let inside = view.bounds.contains(point)
   let scrollbar = event.type == .leftMouseDown && inside && point.x >= view.bounds.maxX-18
   let scroll = event.type == .scrollWheel && inside && (event.scrollingDeltaY != 0 || event.phase == .began)
   let keyScroll = event.type == .keyDown && inside && !(window.firstResponder is NSTextView) && [116,121,115,119,125,126].contains(Int(event.keyCode))
   if scroll || scrollbar || keyScroll { coordinator.onManualScroll() }
   return event
  }
  return view
 }
 func updateNSView(_ view: NSView,context: Context) { context.coordinator.onManualScroll = onManualScroll }
 func makeCoordinator() -> Coordinator { Coordinator(onManualScroll) }
 static func dismantleNSView(_ view: NSView,coordinator: Coordinator) { if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }; coordinator.monitor = nil }
 final class Coordinator {
  weak var view: NSView?
  var monitor: Any?
  var onManualScroll: () -> Void
  init(_ action: @escaping () -> Void) { onManualScroll = action }
 }
}
