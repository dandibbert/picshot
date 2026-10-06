import AppKit
let output=CommandLine.arguments[1]
let set=URL(fileURLWithPath:output).deletingPathExtension().appendingPathExtension("iconset")
try FileManager.default.createDirectory(at:set,withIntermediateDirectories:true)
for size in [16,32,64,128,256,512,1024]{
 let image=NSImage(size:NSSize(width:size,height:size));image.lockFocus();let s=CGFloat(size)/1024
 let ctx=NSGraphicsContext.current!.cgContext;ctx.scaleBy(x:s,y:s)
 NSColor(calibratedRed:0.13,green:0.30,blue:0.94,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:54,y:54,width:916,height:916),xRadius:210,yRadius:210).fill()
 NSColor.white.setStroke();let p=NSBezierPath();p.lineWidth=62;p.lineCapStyle = .round;p.lineJoinStyle = .round
 for (x,y,dx,dy) in [(270.0,270.0,1.0,1.0),(754.0,270.0,-1.0,1.0),(270.0,754.0,1.0,-1.0),(754.0,754.0,-1.0,-1.0)]{p.move(to:NSPoint(x:x+dx*110,y:y));p.line(to:NSPoint(x:x,y:y));p.line(to:NSPoint(x:x,y:y+dy*110))};p.stroke()
 NSColor(calibratedRed:1,green:0.70,blue:0.22,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:400,y:400,width:224,height:224),xRadius:55,yRadius:55).fill();image.unlockFocus()
 let data=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
 if size<=512 {try data.write(to:set.appendingPathComponent("icon_\(size)x\(size).png"))}
 if size>=32 {try data.write(to:set.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png"))}
}
