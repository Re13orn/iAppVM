import AppKit
let dir=URL(fileURLWithPath:CommandLine.arguments[1])
for (size,name) in [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),(64,"icon_32x32@2x"),(128,"icon_128x128"),(256,"icon_128x128@2x"),(256,"icon_256x256"),(512,"icon_256x256@2x"),(512,"icon_512x512"),(1024,"icon_512x512@2x")] {
    let s=CGFloat(size)
    let image=NSImage(size:NSSize(width:s,height:s));image.lockFocus()
    NSColor(calibratedRed:0.12,green:0.35,blue:0.94,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:s*0.06,y:s*0.06,width:s*0.88,height:s*0.88),xRadius:s*0.2,yRadius:s*0.2).fill()
    let configuration=NSImage.SymbolConfiguration(pointSize:s*0.49,weight:.medium).applying(.init(paletteColors:[.white]))
    let symbol=NSImage(systemSymbolName:"iphone.and.arrow.forward",accessibilityDescription:nil)!.withSymbolConfiguration(configuration)!
    let ratio=min(s*0.62/symbol.size.width,s*0.62/symbol.size.height)
    let w=symbol.size.width*ratio,h=symbol.size.height*ratio
    symbol.draw(in:NSRect(x:(s-w)/2,y:(s-h)/2,width:w,height:h));image.unlockFocus()
    let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
    try rep.representation(using:.png,properties:[:])!.write(to:dir.appendingPathComponent(name+".png"))
}
