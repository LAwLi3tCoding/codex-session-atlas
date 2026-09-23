import AppKit
import Foundation

let width = 1280, height = 980
let output = URL(fileURLWithPath: "build/icon-candidates/comparison.png")
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
func color(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
        blue: CGFloat(value & 255) / 255, alpha: 1)
}
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: CGFloat(height) - y - h, width: w, height: h)
}
func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
           _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ hex: UInt32 = 0x252b2a) {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(hex), .paragraphStyle: paragraph]
    NSAttributedString(string: text, attributes: attributes).draw(in: rect(x, y, w, h))
}
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
context.imageInterpolation = .high
color(0xf2f3f1).setFill(); NSBezierPath(rect: rect(0, 0, CGFloat(width), CGFloat(height))).fill()
label("Codex Session Atlas", 40, 30, 950, 46, 31, .semibold)
label("四个图标方向 · 同一套配色，比较图形含义与小尺寸辨识度", 40, 82, 1150, 30, 18, .regular, 0x626c66)
let options: [(String,String,String,String)] = [
    ("a-session-monitor", "A  会话监控", "多个对话窗口\n＋执行节点", "表达：会话、监控、轨迹\n更适合代表整个软件"),
    ("b-execution-trace", "B  执行轨迹", "执行主线\n＋子任务分支", "表达：工具执行与协作\n容易让人联想到开发工具"),
    ("c-context-analysis", "C  上下文分析", "内容分层\n＋占用分段", "表达：上下文组成与容量\n更突出分析功能"),
    ("d-session-inspector", "D  会话观察", "对话气泡\n＋放大镜", "表达：查看与排查会话\n用途直观，识别门槛较低")
]
for (index, option) in options.enumerated() {
    let x: CGFloat = index % 2 == 0 ? 40 : 652
    let y: CGFloat = index < 2 ? 140 : 548
    color(0xffffff).setFill(); NSBezierPath(roundedRect: rect(x, y, 588, 382), xRadius: 18, yRadius: 18).fill()
    label(option.1, x+26, y+25, 430, 37, 24, .semibold)
    if index == 0 {
        color(0xe9f1ec).setFill(); NSBezierPath(roundedRect: rect(x+488,y+25,72,30), xRadius: 15, yRadius: 15).fill()
        label("推荐",x+509,y+29,44,25,14,.medium,0x3c765e)
    }
    let image = NSImage(contentsOfFile: "build/icon-candidates/\(option.0).png")!
    image.draw(in: rect(x+15,y+83,264,264),from:.zero,operation:.sourceOver,fraction:1)
    label(option.2,x+300,y+84,255,70,20,.medium)
    label(option.3,x+300,y+168,255,61,15,.regular,0x68716d)
    label("缩小预览",x+300,y+237,235,22,12,.medium,0x7a837d)
    for (offset,size) in [(CGFloat(0),CGFloat(64)),(CGFloat(94),CGFloat(48)),(CGFloat(173),CGFloat(32))] {
        image.draw(in:rect(x+296+offset,y+324-size,size,size),from:.zero,operation:.sourceOver,fraction:1)
        label("\(Int(size)) px",x+296+offset,y+330,70,22,11,.regular,0x7a837d)
    }
}
label("候选预览 · 尚未替换应用图标",40,948,1150,26,14,.regular,0x757e78)
context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:output)
print(output.path)
