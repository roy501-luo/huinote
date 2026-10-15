import AppKit
import SwiftUI

@main struct VerifyNoteEditor {
 @MainActor static func main() throws {
  _ = NSApplication.shared
  let editor = NoteComposer.Editor()
  editor.string = "已有文字"
  editor.setSelectedRange(NSRange(location:4,length:0))
  editor.setMarkedText("zhongwen",selectedRange:NSRange(location:8,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
  precondition(editor.hasMarkedText())
  for _ in 0..<100 { editor.applyExternalText("已有文字") }
  precondition(editor.string == "已有文字zhongwen", "刷新破坏了输入法组合")
  precondition(editor.hasMarkedText())
  var saved = ""
  editor.committed = { saved = $0 }
  editor.setMarkedText("中文",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
  editor.unmarkText()
  precondition(saved == "已有文字中文", "中文提交未保存")
  editor.setSelectedRange(NSRange(location:2,length:0))
  editor.applyExternalText(saved)
  precondition(editor.selectedRange().location == 2, "无变化刷新移动光标")
  editor.applyExternalText("")
  precondition(editor.string.isEmpty)
  print("PASS 原生 NSTextView 组合输入在 100 次刷新中保留、提交中文、光标与清空")
 }
}
