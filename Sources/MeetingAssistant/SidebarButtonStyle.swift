import SwiftUI

/// The entire row, including trailing whitespace, is a hit target.
struct SidebarButtonStyle: ButtonStyle {
 var selected = false
 func makeBody(configuration: Configuration) -> some View {
  Row(configuration:configuration,selected:selected)
 }
 private struct Row: View {
  let configuration: ButtonStyle.Configuration
  let selected: Bool
  @Environment(\.isEnabled) private var enabled
  @State private var hovered = false
  var body: some View {
   configuration.label
    .frame(maxWidth:.infinity,minHeight:22,alignment:.leading)
    .padding(.horizontal,10).padding(.vertical,8)
    .contentShape(Rectangle())
    .background(background,in:RoundedRectangle(cornerRadius:7))
    .foregroundStyle(enabled ? Color.primary : Color.secondary)
    .onHover { hovered = $0 }
  }
  private var background: Color {
   guard enabled else { return .clear }
   if configuration.isPressed { return Color.primary.opacity(0.13) }
   if selected { return Color.accentColor.opacity(hovered ? 0.15 : 0.10) }
   return Color.primary.opacity(hovered ? 0.065 : 0)
  }
 }
}
