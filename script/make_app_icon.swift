#!/usr/bin/env swift
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// 生成 macOS 应用图标（纯 CoreGraphics 绘制，便于脚本化与复现）。
///
/// 遵循 Apple 的 macOS 图标规范：
/// - 1024×1024 画布，圆角矩形主体 824×824（四周各留 100pt）
/// - 连续圆角（squircle，超椭圆）而非普通圆角
/// - 背景不透明、自上而下单一光源、柔和投影，内容不触边
/// - 输出 16/32/128/256/512 的 1x 与 2x，由 iconutil 打包为 .icns
enum IconGenerator {
    static let canvas: CGFloat = 1024
    static let bodySize: CGFloat = 824
    /// 超椭圆指数。取值让轮廓与 Apple 图标网格（824 主体、圆角约 185）吻合：
    /// 指数越大越接近圆角矩形，过小会变成「肥皂」形。
    static let squircleExponent: CGFloat = 9.6

    static func run() {
        let outputDirectory = URL(
            fileURLWithPath: CommandLine.arguments.count > 1
                ? CommandLine.arguments[1]
                : FileManager.default.currentDirectoryPath
        )
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        let variants: [(name: String, size: CGFloat)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]

        for variant in variants {
            guard let image = render(size: variant.size) else {
                FileHandle.standardError.write(Data("渲染 \(variant.name) 失败\n".utf8))
                exit(1)
            }
            let url = iconset.appendingPathComponent("\(variant.name).png")
            guard write(image, to: url) else {
                FileHandle.standardError.write(Data("写入 \(variant.name) 失败\n".utf8))
                exit(1)
            }
        }

        if let preview = render(size: 1024) {
            _ = write(preview, to: outputDirectory.appendingPathComponent("AppIcon-1024.png"))
        }
        print("图标已生成：\(iconset.path)")
    }

    /// 按目标像素尺寸原生渲染，避免缩小导致小尺寸发糊。
    static func render(size: CGFloat) -> CGImage? {
        let pixels = Int(size)
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high
        context.scaleBy(x: size / canvas, y: size / canvas)
        draw(in: context)
        return context.makeImage()
    }

    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    static func draw(in context: CGContext) {
        let inset = (canvas - bodySize) / 2
        let body = CGRect(x: inset, y: inset, width: bodySize, height: bodySize)
        let shape = squirclePath(in: body)

        // 投影：macOS 图标自带柔和的向下阴影，模拟自上而下的光源。
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -10),
            blur: 30,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22)
        )
        context.addPath(shape)
        context.setFillColor(CGColor(red: 0.16, green: 0.37, blue: 0.94, alpha: 1))
        context.fillPath()
        context.restoreGState()

        // 主体渐变：三段式（顶部受光、中段本色、底部加深），
        // 比「底色 + 单独高光层」更平滑，不会留下分层痕迹。
        context.saveGState()
        context.addPath(shape)
        context.clip()

        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(red: 0.51, green: 0.55, blue: 1.00, alpha: 1),
                CGColor(red: 0.29, green: 0.32, blue: 0.88, alpha: 1),
                CGColor(red: 0.13, green: 0.16, blue: 0.62, alpha: 1),
            ] as CFArray,
            locations: [0, 0.48, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: body.midX, y: body.maxY),
                end: CGPoint(x: body.midX, y: body.minY),
                options: []
            )
        }
        context.restoreGState()

        drawYenSymbol(in: body, context: context)
    }

    /// 连续圆角矩形（超椭圆），比普通圆角更接近 Apple 的图标轮廓。
    static func squirclePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let steps = 900
        let a = rect.width / 2
        let b = rect.height / 2
        let n = squircleExponent

        for step in 0...steps {
            let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let cosine = cos(angle)
            let sine = sin(angle)
            let x = rect.midX + a * copysign(pow(abs(cosine), 2 / n), cosine)
            let y = rect.midY + b * copysign(pow(abs(sine), 2 / n), sine)
            if step == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }

    /// 居中的白色人民币符号。
    static func drawYenSymbol(in body: CGRect, context: CGContext) {
        let fontSize = body.height * 0.44
        var font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        if let rounded = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: rounded, size: fontSize) ?? font
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: "¥", attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        // 视觉居中：按字形实际包围盒对齐，而不是按行高。
        let originX = body.midX - bounds.width / 2 - bounds.origin.x
        let originY = body.midY - bounds.height / 2 - bounds.origin.y

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -body.height * 0.012),
            blur: body.height * 0.03,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.18)
        )
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: originX, y: originY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

IconGenerator.run()
