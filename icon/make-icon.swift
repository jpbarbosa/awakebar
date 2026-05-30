#!/usr/bin/env swift
// make-icon.swift — render AwakeBar's app icon: a coffee cup on a Liquid-Glass-
// style squircle tile. The tile (squircle, gloss, sheen) is drawn in Core
// Graphics; the cup is the 3D-rendered black-coffee-cup.png composited on top
// with a drop shadow. If that PNG is absent it falls back to a drawn vector cup.
// Deliberately NOT the SF Symbol cup.and.saucer — Apple's SF Symbols licence
// forbids using their symbols in app icons.
//
// Usage: swift make-icon.swift <style> <size> <out.png>
//   style: aqua | espresso | graphite   (tile palette)
//
// Renders one PNG. build-iconset.sh drives this across all iconset sizes.

import AppKit

// The foreground cup. A 3D-rendered PNG (transparent background, baked shadow)
// living next to this script; resolved relative to the source file so it works
// from any cwd. If absent, render() falls back to the drawn vector cup.
let cupImagePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("black-coffee-cup.png").path

// MARK: - Style

struct Style {
    let bgTop, bgBottom: NSColor   // tile gradient
    let rim: NSColor               // bright top edge of the tile
    let cupTop, cupBottom: NSColor // cup body gradient
    let cupShade: NSColor          // inside-of-cup / underside

    static func named(_ name: String) -> Style {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
        }
        switch name {
        case "espresso":
            return Style(bgTop: c(196, 132, 84), bgBottom: c(120, 70, 38),
                         rim: c(255, 226, 192),
                         cupTop: c(255, 250, 244), cupBottom: c(228, 214, 200),
                         cupShade: c(180, 150, 128))
        case "graphite":
            return Style(bgTop: c(150, 160, 170), bgBottom: c(70, 80, 92),
                         rim: c(232, 240, 248),
                         cupTop: c(255, 255, 255), cupBottom: c(214, 222, 230),
                         cupShade: c(150, 162, 175))
        default: // aqua
            return Style(bgTop: c(96, 186, 250), bgBottom: c(10, 96, 210),
                         rim: c(224, 244, 255),
                         cupTop: c(255, 255, 255), cupBottom: c(216, 232, 246),
                         cupShade: c(150, 186, 222))
        }
    }
}

// MARK: - Geometry helpers

// A continuous-corner "squircle" (superellipse, n≈5) — the macOS app-tile shape,
// rather than a plain rounded rect.
func squircle(in rect: CGRect, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = a * copysign(pow(abs(ct), 2 / n), ct)
        let y = b * copysign(pow(abs(st), 2 / n), st)
        let p = CGPoint(x: cx + x, y: cy + y)
        if i == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.close()
    return path
}

// MARK: - Cup

// An original cup + saucer + handle, centred in `tile`. Returns the body path so
// callers can clip highlights to it.
@discardableResult
func drawCup(in tile: CGRect, style: Style) -> NSBezierPath {
    let T = tile.width
    let cx = tile.midX
    let cy0 = tile.midY + T * 0.005   // group centre

    // Cup metrics.
    let topW = T * 0.42, botW = T * 0.30, cornerR = T * 0.055
    let cupH = T * 0.30
    let saucerW = T * 0.64, saucerH = T * 0.125
    let saucerY = cy0 - T * 0.155
    let yBot = saucerY + T * 0.035    // cup rests in the saucer well
    let yTop = yBot + cupH
    let xLt = cx - topW/2, xRt = cx + topW/2
    let xLb = cx - botW/2, xRb = cx + botW/2
    let cupGrad = NSGradient(colors: [style.cupTop, style.cupBottom])!

    // Saucer — a flat ellipse with a thin rim below it for thickness.
    let saucerRim = NSBezierPath(ovalIn: CGRect(x: cx - saucerW/2, y: saucerY - saucerH/2 - T*0.020,
                                                width: saucerW, height: saucerH))
    style.cupShade.setFill(); saucerRim.fill()
    let saucer = NSBezierPath(ovalIn: CGRect(x: cx - saucerW/2, y: saucerY - saucerH/2,
                                             width: saucerW, height: saucerH))
    cupGrad.draw(in: saucer, angle: -90)

    // Handle — a ring on the right, drawn before the body so the body overlaps it.
    let handle = NSBezierPath()
    let hcx = xRt + T*0.028, hcy = yTop - cupH*0.46
    handle.appendOval(in: CGRect(x: hcx - T*0.090, y: hcy - T*0.105,
                                 width: T*0.18, height: T*0.21))
    handle.append(NSBezierPath(ovalIn: CGRect(x: hcx - T*0.042, y: hcy - T*0.060,
                                              width: T*0.084, height: T*0.12)))
    handle.windingRule = .evenOdd   // cut the hole
    NSGraphicsContext.saveGraphicsState()
    handle.addClip()
    cupGrad.draw(in: handle.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Cup body — straight tapered sides, flat bottom with rounded corners.
    let body = NSBezierPath()
    body.move(to: CGPoint(x: xLt, y: yTop))
    body.line(to: CGPoint(x: xLb, y: yBot + cornerR))
    body.curve(to: CGPoint(x: xLb + cornerR, y: yBot),
               controlPoint1: CGPoint(x: xLb, y: yBot + cornerR*0.45),
               controlPoint2: CGPoint(x: xLb + cornerR*0.45, y: yBot))
    body.line(to: CGPoint(x: xRb - cornerR, y: yBot))
    body.curve(to: CGPoint(x: xRb, y: yBot + cornerR),
               controlPoint1: CGPoint(x: xRb - cornerR*0.45, y: yBot),
               controlPoint2: CGPoint(x: xRb, y: yBot + cornerR*0.45))
    body.line(to: CGPoint(x: xRt, y: yTop))
    body.close()
    cupGrad.draw(in: body, angle: -90)

    // Left-side sheen on the cup, clipped to the body — reads as glossy glass.
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    let sheen = NSBezierPath(ovalIn: CGRect(x: xLt - topW*0.10, y: yBot,
                                            width: topW*0.5, height: cupH*1.1))
    NSGraphicsContext.saveGraphicsState()
    sheen.addClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.55), NSColor(white: 1, alpha: 0)])!
        .draw(in: sheen.bounds, angle: 0)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    // Rim + coffee surface — a dark inside ellipse with darker coffee inset.
    let rimW = topW, rimH = T * 0.072
    let rim = NSBezierPath(ovalIn: CGRect(x: cx - rimW/2, y: yTop - rimH/2,
                                          width: rimW, height: rimH))
    style.cupShade.setFill(); rim.fill()
    let inset: CGFloat = T * 0.020
    let coffee = NSBezierPath(ovalIn: CGRect(x: cx - rimW/2 + inset, y: yTop - rimH/2 + inset*0.5,
                                             width: rimW - inset*2, height: rimH - inset))
    NSColor(srgbRed: 0.27, green: 0.16, blue: 0.10, alpha: 1).setFill()
    coffee.fill()

    return body
}

// MARK: - Cup image

// Composite the rendered cup PNG into the tile: scaled to `scale` of the tile
// width, centred (nudged by `dy` tile-widths). The PNG carries its own shadow,
// so no extra NSShadow is added.
func drawCupImage(path: String, in tile: CGRect, scale: CGFloat, dy: CGFloat) {
    guard let img = NSImage(contentsOfFile: path) else { return }
    let side = tile.width * scale
    let rect = CGRect(x: tile.midX - side/2,
                      y: tile.midY - side/2 + tile.width * dy,
                      width: side, height: side)
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0,
             respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}

// MARK: - Render

func render(style: Style, size S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    ctx.cgContext.setAllowsAntialiasing(true)

    // Tile: the squircle fills ~80.5% of the canvas (the macOS icon grid), with
    // a soft drop shadow under it.
    let tileSide = S * 0.806
    let margin = (S - tileSide) / 2
    let tileRect = CGRect(x: margin, y: margin - S*0.006, width: tileSide, height: tileSide)
    let tile = squircle(in: tileRect)

    // Drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowBlurRadius = S * 0.022
    shadow.shadowOffset = NSSize(width: 0, height: -S * 0.012)
    shadow.set()
    NSColor.black.setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Tile background gradient.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [style.bgTop, style.bgBottom])!.draw(in: tileRect, angle: -90)

    // Glass specular: a broad soft highlight across the top third.
    let glossRect = CGRect(x: tileRect.minX, y: tileRect.midY,
                           width: tileRect.width, height: tileRect.height/2)
    let gloss = NSGradient(colors: [NSColor(white: 1, alpha: 0.32),
                                    NSColor(white: 1, alpha: 0.0)])!
    gloss.draw(in: glossRect, angle: -90)

    // A bright crescent sheen hugging the top-left curve.
    let sheen = NSBezierPath(ovalIn: CGRect(x: tileRect.minX - tileSide*0.1,
                                            y: tileRect.midY + tileSide*0.06,
                                            width: tileSide*0.9, height: tileSide*0.5))
    let sheenGrad = NSGradient(colors: [NSColor(white: 1, alpha: 0.22),
                                        NSColor(white: 1, alpha: 0.0)])!
    NSGraphicsContext.saveGraphicsState()
    sheen.addClip()
    sheenGrad.draw(in: sheen.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The cup: the rendered PNG if present (carries its own shadow), else the
    // drawn vector cup with a soft shadow so it lifts off the glass.
    if FileManager.default.fileExists(atPath: cupImagePath) {
        NSGraphicsContext.saveGraphicsState()
        let cupShadow = NSShadow()
        cupShadow.shadowColor = NSColor(white: 0, alpha: 0.33)
        cupShadow.shadowBlurRadius = S * 0.024
        cupShadow.shadowOffset = NSSize(width: 0, height: -S * 0.014)
        cupShadow.set()
        drawCupImage(path: cupImagePath, in: tileRect, scale: 0.95, dy: 0.02)
        NSGraphicsContext.restoreGraphicsState()
    } else {
        NSGraphicsContext.saveGraphicsState()
        let cupShadow = NSShadow()
        cupShadow.shadowColor = NSColor(white: 0, alpha: 0.22)
        cupShadow.shadowBlurRadius = S * 0.012
        cupShadow.shadowOffset = NSSize(width: 0, height: -S * 0.006)
        cupShadow.set()
        drawCup(in: tileRect, style: style)
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState() // tile clip

    // Inner top-edge light + bottom shade, for glass thickness.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let edge = squircle(in: tileRect.insetBy(dx: S*0.006, dy: S*0.006))
    edge.lineWidth = S * 0.006
    style.rim.withAlphaComponent(0.55).setStroke(); edge.stroke()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - main

let args = CommandLine.arguments
let style = Style.named(args.count > 1 ? args[1] : "aqua")
let size = CGFloat(args.count > 2 ? Double(args[2]) ?? 1024 : 1024)
let out = args.count > 3 ? args[3] : "preview.png"
let rep = render(style: style, size: size)
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG encode failed\n".data(using: .utf8)!); exit(1)
}
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(Int(size))px)")
