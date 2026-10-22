// Draws BotChu's app icon into an .iconset folder: a violet tile holding two chat bubbles, the bot's
// with two eyes. build.sh runs this and turns the folder into AppIcon.icns.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func bubble(_ ctx: CGContext, _ rect: CGRect, tailLeft: Bool, color: CGColor) {
    let path = CGMutablePath()
    path.addRoundedRect(in: rect, cornerWidth: rect.height * 0.42, cornerHeight: rect.height * 0.42)
    let tx = tailLeft ? rect.minX + rect.width * 0.18 : rect.maxX - rect.width * 0.18
    let dir: CGFloat = tailLeft ? -1 : 1
    path.move(to: CGPoint(x: tx - 34 * dir, y: rect.minY + 10))
    path.addLine(to: CGPoint(x: tx + 40 * dir, y: rect.minY - 58))
    path.addLine(to: CGPoint(x: tx + 34 * dir, y: rect.minY + 10))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func draw(_ px: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: an 824pt tile centred on a 1024pt canvas, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x5B3FD6))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: cs, colors: [rgb(0x8B6CFF), rgb(0x4A2FC2)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])

    // The person's bubble, behind and to the right.
    bubble(ctx, CGRect(x: 430, y: 560, width: 380, height: 210), tailLeft: false, color: rgb(0xFFFFFF, 0.35))
    // The bot's bubble, in front, with two eyes.
    let bot = CGRect(x: 214, y: 270, width: 470, height: 290)
    bubble(ctx, bot, tailLeft: true, color: rgb(0xFFFFFF))
    ctx.setFillColor(rgb(0x4A2FC2))
    for x in [bot.midX - 82, bot.midX + 82] {
        ctx.fillEllipse(in: CGRect(x: x - 34, y: bot.midY - 34, width: 68, height: 68))
    }
    ctx.restoreGState()

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
