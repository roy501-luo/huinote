import AppKit
import Foundation

// Reproducible vector-drawn icon: a voice bubble on a jade macOS tile.
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".build/HuiNote.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ pixels: Int, name: String) throws {
 let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState()
 NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
 let context = NSGraphicsContext.current!.cgContext
 context.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
 let tile = NSBezierPath(roundedRect:NSRect(x:80,y:80,width:864,height:864),xRadius:192,yRadius:192)
 NSGraphicsContext.saveGraphicsState()
 let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18); shadow.shadowOffset = NSSize(width:0,height:-12); shadow.shadowBlurRadius = 22; shadow.set()
 NSColor(calibratedRed:0.10,green:0.36,blue:0.28,alpha:1).setFill(); tile.fill()
 NSGraphicsContext.restoreGraphicsState()
 NSGradient(starting:NSColor(calibratedRed:0.16,green:0.53,blue:0.40,alpha:1),ending:NSColor(calibratedRed:0.06,green:0.30,blue:0.23,alpha:1))!.draw(in:tile,angle:-70)
 NSColor.white.withAlphaComponent(0.16).setStroke(); tile.lineWidth=2; tile.stroke()
 let bubble = NSBezierPath(roundedRect:NSRect(x:238,y:308,width:548,height:430),xRadius:116,yRadius:116)
 NSColor(calibratedRed:0.96,green:0.99,blue:0.96,alpha:1).setFill(); bubble.fill()
 let tail = NSBezierPath(); tail.move(to:NSPoint(x:304,y:355)); tail.line(to:NSPoint(x:304,y:237)); tail.curve(to:NSPoint(x:415,y:326),controlPoint1:NSPoint(x:340,y:250),controlPoint2:NSPoint(x:391,y:297)); tail.close(); tail.fill()
 let heights:[CGFloat] = [80,154,224,154,80]
 NSColor(calibratedRed:0.12,green:0.43,blue:0.32,alpha:1).setFill()
 for (i,h) in heights.enumerated() {
  NSBezierPath(roundedRect:NSRect(x:346+CGFloat(i)*72,y:528-h/2,width:44,height:h),xRadius:22,yRadius:22).fill()
 }
 NSGraphicsContext.restoreGraphicsState()
 try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name))
}
for size in [16,32,128,256,512] {
 try render(size,name:"icon_\(size)x\(size).png")
 try render(size*2,name:"icon_\(size)x\(size)@2x.png")
}
