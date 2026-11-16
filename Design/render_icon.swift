import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let reference = NSImage(contentsOf: directory.appendingPathComponent("RTranslate-reference.png"))!
let iconset = directory.appendingPathComponent("RSpeech.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func icon(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels)/512, y: CGFloat(pixels)/512)
    reference.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512))
    NSColor.white.setFill()
    NSRect(x: 74, y: 108, width: 177, height: 296).fill()
    let blue = NSColor(srgbRed: 40/255, green: 62/255, blue: 171/255, alpha: 1)
    blue.setStroke()
    let page = NSBezierPath()
    page.move(to: NSPoint(x: 111, y: 148))
    page.line(to: NSPoint(x: 213, y: 148))
    page.curve(to: NSPoint(x: 225, y: 160), controlPoint1: NSPoint(x: 222, y: 148), controlPoint2: NSPoint(x: 225, y: 152))
    page.line(to: NSPoint(x: 225, y: 326))
    page.line(to: NSPoint(x: 187, y: 364))
    page.line(to: NSPoint(x: 111, y: 364))
    page.curve(to: NSPoint(x: 99, y: 352), controlPoint1: NSPoint(x: 102, y: 364), controlPoint2: NSPoint(x: 99, y: 360))
    page.line(to: NSPoint(x: 99, y: 160))
    page.curve(to: NSPoint(x: 111, y: 148), controlPoint1: NSPoint(x: 99, y: 152), controlPoint2: NSPoint(x: 102, y: 148))
    page.close(); page.lineWidth = 12; page.lineJoinStyle = .round; page.stroke()
    let fold = NSBezierPath(); fold.move(to: NSPoint(x: 187, y: 362)); fold.line(to: NSPoint(x: 187, y: 328)); fold.line(to: NSPoint(x: 222, y: 328)); fold.lineWidth = 10; fold.lineJoinStyle = .round; fold.lineCapStyle = .round; fold.stroke()
    for y in [282, 242, 202] {
        let line = NSBezierPath(); line.move(to: NSPoint(x: 125, y: y)); line.line(to: NSPoint(x: 197, y: y)); line.lineWidth = 11; line.lineCapStyle = .round; line.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16,32,128,256,512] {
    try icon(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try icon(size*2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("Rendered document icon with the original right side and frame")
