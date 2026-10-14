import SwiftUI

/// AvatarConfig を絵にする。Web 版の CSS / SVG に当たる部分で、
/// 200×220 の座標系にパーツを奥から順に重ねて描いている。
struct AvatarView: View {
    let config: AvatarConfig

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 200, size.height / 220)
            context.translateBy(
                x: (size.width - 200 * scale) / 2,
                y: (size.height - 220 * scale) / 2
            )
            context.scaleBy(x: scale, y: scale)
            AvatarPainter(c: config).draw(&context)
        }
        .aspectRatio(200.0 / 220.0, contentMode: .fit)
    }
}

private struct AvatarPainter {
    let c: AvatarConfig

    // 基準点
    let cx: CGFloat = 100
    let cy: CGFloat = 100

    /// 顔の半幅・半高
    var face: (w: CGFloat, h: CGFloat) {
        switch c.faceShape {
        case .round: return (56, 56)
        case .oval: return (50, 60)
        case .long: return (46, 66)
        case .square: return (52, 58)
        }
    }
    var faceTop: CGFloat { cy - face.h }
    var chinY: CGFloat { cy + face.h }
    var eyeY: CGFloat { cy + 2 }
    var eyeDX: CGFloat { face.w * 0.42 }
    var hasHair: Bool { c.hairLength != .none }

    var volume: CGFloat {
        switch c.hairVolume {
        case .low: 2
        case .normal: 6
        case .high: 11
        }
    }
    /// 髪の左右端（耳の上あたり）と頭頂
    var hairLeft: CGPoint { CGPoint(x: cx - face.w - volume * 0.6 - 2, y: cy - 6) }
    var hairRight: CGPoint { CGPoint(x: cx + face.w + volume * 0.6 + 2, y: cy - 6) }
    var hairTop: CGFloat { faceTop - 6 - volume }

    var skin: Color { c.skinTone.color }
    var hair: Color { c.hairColor.color }
    let ink = Color(hex: 0x2B2B30)

    func draw(_ ctx: inout GraphicsContext) {
        if hasHair { backHair(&ctx) }
        body(&ctx)
        ears(&ctx)
        ctx.fill(facePath, with: .color(skin))
        cheeks(&ctx)
        beard(&ctx)
        mouth(&ctx)
        nose(&ctx)
        eye(&ctx, isLeft: true)
        eye(&ctx, isLeft: false)
        brow(&ctx, isLeft: true)
        brow(&ctx, isLeft: false)
        mustache(&ctx)
        if c.longSideburns { sideburns(&ctx) }
        if hasHair { frontHair(&ctx) }
        if c.earrings { earrings(&ctx) }
        glasses(&ctx)
        hat(&ctx)
    }

    // MARK: 形のヘルパー

    var facePath: Path {
        let rect = CGRect(x: cx - face.w, y: faceTop, width: face.w * 2, height: face.h * 2)
        return c.faceShape == .square ? Path(roundedRect: rect, cornerRadius: 26) : Path(ellipseIn: rect)
    }

    /// left から right へ、頂点が topY になるドームを描く（path は left に移動済みの前提）
    func addDome(_ p: inout Path, from left: CGPoint, to right: CGPoint, topY: CGFloat) {
        // 3 次ベジェの頂点は制御点の高さの 3/4 に来るので逆算する
        let controlY = left.y + (topY - left.y) / 0.75
        p.addCurve(
            to: right,
            control1: CGPoint(x: left.x, y: controlY),
            control2: CGPoint(x: right.x, y: controlY)
        )
    }

    func circle(_ center: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }

    func pen(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    // MARK: 体・耳

    func body(_ ctx: inout GraphicsContext) {
        let shoulders = Path(roundedRect: CGRect(x: 28, y: 176, width: 144, height: 80), cornerRadius: 38)
        ctx.fill(shoulders, with: .color(c.clothColor.color))
        let neck = Path(roundedRect: CGRect(x: cx - 15, y: cy + 36, width: 30, height: 52), cornerRadius: 13)
        ctx.fill(neck, with: .color(skin))
        ctx.fill(neck, with: .color(.black.opacity(0.08)))
    }

    func ears(_ ctx: inout GraphicsContext) {
        for side: CGFloat in [-1, 1] {
            let ear = Path(ellipseIn: CGRect(x: cx + side * face.w - 8, y: cy - 7, width: 16, height: 22))
            ctx.fill(ear, with: .color(skin))
            ctx.fill(ear, with: .color(.black.opacity(0.05)))
        }
    }

    func earrings(_ ctx: inout GraphicsContext) {
        for side: CGFloat in [-1, 1] {
            ctx.fill(circle(CGPoint(x: cx + side * (face.w + 3), y: cy + 17), 3.2), with: .color(Color(hex: 0xF2C43D)))
        }
    }

    // MARK: 髪

    func backHair(_ ctx: inout GraphicsContext) {
        let color = GraphicsContext.Shading.color(hair)
        let left = hairLeft, right = hairRight

        if c.hairLength != .short {
            let bottom: CGFloat = c.hairLength == .long ? 198 : chinY + 6
            let rect = CGRect(x: left.x - 2, y: hairTop + 10, width: right.x - left.x + 4, height: bottom - hairTop - 10)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 30), with: color)
            if c.hairTexture != .straight {
                // 毛先にふくらみを足す
                let r: CGFloat = c.hairTexture == .curly ? 10 : 7
                for i in 0...4 {
                    let x = rect.minX + rect.width * CGFloat(i) / 4
                    ctx.fill(circle(CGPoint(x: x, y: bottom - 4), r), with: color)
                }
            }
        }

        switch c.hairTie {
        case .down:
            break
        case .ponytail:
            ctx.fill(Path(ellipseIn: CGRect(x: right.x - 6, y: cy - 50, width: 28, height: 70)), with: color)
        case .twinTails:
            for x in [left.x - 20, right.x - 2] {
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: cy - 14, width: 22, height: 70)), with: color)
            }
        case .bun:
            ctx.fill(circle(CGPoint(x: cx, y: hairTop - 4), 17), with: color)
        }
    }

    func frontHair(_ ctx: inout GraphicsContext) {
        let color = GraphicsContext.Shading.color(hair)
        let left = hairLeft, right = hairRight

        // 立てた髪・くせ毛は頭の輪郭に飾りを足す
        if c.spiky {
            for i in -2...2 {
                let x = cx + CGFloat(i) * 18
                var spike = Path()
                spike.move(to: CGPoint(x: x - 11, y: hairTop + 14))
                spike.addLine(to: CGPoint(x: x + CGFloat(i) * 3, y: hairTop - 16))
                spike.addLine(to: CGPoint(x: x + 11, y: hairTop + 14))
                spike.closeSubpath()
                ctx.fill(spike, with: color)
            }
        }
        if c.hairTexture != .straight {
            let r: CGFloat = c.hairTexture == .curly ? 10 : 6.5
            let rx = (right.x - left.x) / 2, ry = left.y - hairTop
            for i in 0...8 {
                let angle = Double.pi + Double.pi * Double(i) / 8
                let point = CGPoint(x: cx + CGFloat(cos(angle)) * rx, y: left.y + CGFloat(sin(angle)) * ry)
                ctx.fill(circle(point, r), with: color)
            }
        }

        // 頭頂のドーム + 前髪のライン
        var cap = Path()
        cap.move(to: left)
        addDome(&cap, from: left, to: right, topY: hairTop)
        switch c.bangs {
        case .none:
            // おでこを出す: 生え際を高く
            cap.addQuadCurve(to: left, control: CGPoint(x: cx, y: 2 * (faceTop + 12) - left.y))
        case .down:
            // 眉の少し上まで下ろす
            cap.addQuadCurve(to: left, control: CGPoint(x: cx, y: 2 * (eyeY - 22) - left.y))
        case .side:
            // 片側は低く、反対側は高く
            cap.addCurve(
                to: left,
                control1: CGPoint(x: right.x - 8, y: eyeY - 30),
                control2: CGPoint(x: cx - face.w * 0.3, y: faceTop + 4)
            )
        }
        cap.closeSubpath()
        ctx.fill(cap, with: color)

        if c.earsHidden {
            for x in [left.x, right.x - 15] {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: cy - 12, width: 15, height: 36), cornerRadius: 7), with: color)
            }
        }

        if c.parting != .none {
            let offset: CGFloat = c.parting == .left ? -18 : (c.parting == .right ? 18 : 0)
            var line = Path()
            line.move(to: CGPoint(x: cx + offset, y: hairTop + 3))
            line.addLine(to: CGPoint(x: cx + offset * 1.3, y: faceTop + 8))
            ctx.stroke(line, with: .color(.black.opacity(0.28)), style: pen(1.6))
        }
    }

    func sideburns(_ ctx: inout GraphicsContext) {
        for side: CGFloat in [-1, 1] {
            let x = side < 0 ? cx - face.w + 1 : cx + face.w - 8
            ctx.fill(Path(roundedRect: CGRect(x: x, y: cy - 8, width: 7, height: 30), cornerRadius: 3), with: .color(hair))
        }
    }

    // MARK: 顔のパーツ

    func cheeks(_ ctx: inout GraphicsContext) {
        for side: CGFloat in [-1, 1] {
            let center = CGPoint(x: cx + side * face.w * 0.6, y: cy + 22)
            if c.blush {
                let rect = CGRect(x: center.x - 9, y: center.y - 5, width: 18, height: 10)
                ctx.fill(Path(ellipseIn: rect), with: .color(Color(hex: 0xF27B8A).opacity(0.45)))
            }
            if c.freckles {
                let dots: [(CGFloat, CGFloat)] = [(-5, -8), (0, -5), (5, -8), (-2.5, -11)]
                for (dx, dy) in dots {
                    ctx.fill(circle(CGPoint(x: center.x + dx, y: center.y + dy), 1.1), with: .color(Color(hex: 0x9B5B34).opacity(0.7)))
                }
            }
        }
    }

    func beard(_ ctx: inout GraphicsContext) {
        guard c.beard != .none else { return }
        var clipped = ctx
        clipped.clip(to: facePath)
        // 口の両脇から顎を覆う U 字より下の領域
        var area = Path()
        area.move(to: CGPoint(x: cx - face.w, y: cy + 10))
        area.addQuadCurve(to: CGPoint(x: cx + face.w, y: cy + 10), control: CGPoint(x: cx, y: cy + 44))
        area.addLine(to: CGPoint(x: cx + face.w, y: chinY + 6))
        area.addLine(to: CGPoint(x: cx - face.w, y: chinY + 6))
        area.closeSubpath()
        clipped.fill(area, with: .color(hair.opacity(c.beard == .full ? 1 : 0.28)))
    }

    func mustache(_ ctx: inout GraphicsContext) {
        guard c.mustache != .none else { return }
        let y = cy + 27
        var path = Path()
        path.move(to: CGPoint(x: cx - 11, y: y + 1.5))
        path.addQuadCurve(to: CGPoint(x: cx + 11, y: y + 1.5), control: CGPoint(x: cx, y: y - 3))
        ctx.stroke(path, with: .color(hair), style: pen(c.mustache == .thick ? 6 : 2.5))
    }

    func mouth(_ ctx: inout GraphicsContext) {
        let y = cy + 36
        let lip = Color(hex: 0xB9544F)
        let inside = Color(hex: 0x6E2A2A)
        let width: CGFloat
        switch c.lipThickness {
        case .thin: width = 2
        case .normal: width = 3
        case .thick: width = 4.5
        }

        var path = Path()
        switch (c.mouthOpen, c.smiling) {
        case (true, true):
            path.move(to: CGPoint(x: cx - 12, y: y - 2))
            path.addLine(to: CGPoint(x: cx + 12, y: y - 2))
            path.addQuadCurve(to: CGPoint(x: cx - 12, y: y - 2), control: CGPoint(x: cx, y: y + 18))
            path.closeSubpath()
            ctx.fill(path, with: .color(inside))
        case (true, false):
            path = Path(ellipseIn: CGRect(x: cx - 7, y: y - 5, width: 14, height: 12))
            ctx.fill(path, with: .color(inside))
        case (false, true):
            path.move(to: CGPoint(x: cx - 12, y: y - 2))
            path.addQuadCurve(to: CGPoint(x: cx + 12, y: y - 2), control: CGPoint(x: cx, y: y + 9))
        case (false, false):
            path.move(to: CGPoint(x: cx - 10, y: y))
            path.addQuadCurve(to: CGPoint(x: cx + 10, y: y), control: CGPoint(x: cx, y: y + 2))
        }
        ctx.stroke(path, with: .color(lip), style: pen(width))
    }

    func nose(_ ctx: inout GraphicsContext) {
        let s: CGFloat
        switch c.noseSize {
        case .small: s = 3
        case .normal: s = 4.5
        case .large: s = 6.5
        }
        let y = cy + 17
        var path = Path()
        path.move(to: CGPoint(x: cx - s, y: y))
        path.addQuadCurve(to: CGPoint(x: cx + s, y: y), control: CGPoint(x: cx, y: y + s * 1.3))
        ctx.stroke(path, with: .color(.black.opacity(0.3)), style: pen(1.8))
    }

    func eye(_ ctx: inout GraphicsContext, isLeft: Bool) {
        let side: CGFloat = isLeft ? -1 : 1 // 目尻のある側
        let rx: CGFloat
        switch c.eyeSize {
        case .small: rx = 6
        case .normal: rx = 7.5
        case .large: rx = 9
        }
        let ry = rx * (c.singleLid ? 0.62 : 0.8)
        let tilt: Double
        switch c.eyeTilt {
        case .droopy: tilt = -9
        case .normal: tilt = 0
        case .upturned: tilt = 9
        }

        // 目の中心を原点にして描く。正の回転は時計回りなので、左目は +、右目は − でつり目になる
        var e = ctx
        e.translateBy(x: cx + side * eyeDX, y: eyeY)
        e.rotate(by: .degrees(isLeft ? tilt : -tilt))

        let white = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
        e.fill(white, with: .color(.white))
        var iris = e
        iris.clip(to: white)
        iris.fill(circle(.zero, rx * 0.62), with: .color(c.eyeColor.color))
        iris.fill(circle(.zero, rx * 0.3), with: .color(.black))
        iris.fill(circle(CGPoint(x: -rx * 0.2, y: -rx * 0.22), rx * 0.14), with: .color(.white))

        // 上まぶたのライン
        var lid = Path()
        lid.move(to: CGPoint(x: -rx, y: 0))
        lid.addQuadCurve(to: CGPoint(x: rx, y: 0), control: CGPoint(x: 0, y: -ry * 2))
        e.stroke(lid, with: .color(ink), style: pen(1.8))

        if !c.singleLid {
            var crease = Path()
            crease.move(to: CGPoint(x: -rx * 0.8, y: -ry * 0.9))
            crease.addQuadCurve(to: CGPoint(x: rx * 0.8, y: -ry * 0.9), control: CGPoint(x: 0, y: -ry * 2.3))
            e.stroke(crease, with: .color(ink.opacity(0.4)), style: pen(0.9))
        }
        if c.longLashes {
            let lashes: [(CGFloat, CGFloat)] = [(1, -0.2), (0.8, -0.75), (0.45, -1.05)]
            for (dx, dy) in lashes {
                var lash = Path()
                let start = CGPoint(x: side * rx * dx, y: ry * dy)
                lash.move(to: start)
                lash.addLine(to: CGPoint(x: start.x + side * 3.5, y: start.y - 3))
                e.stroke(lash, with: .color(ink), style: pen(1.3))
            }
        }
    }

    func brow(_ ctx: inout GraphicsContext, isLeft: Bool) {
        let side: CGFloat = isLeft ? -1 : 1
        let ex = cx + side * eyeDX
        let y = eyeY - 16
        var inner = CGPoint(x: ex - side * 11, y: y)
        var outer = CGPoint(x: ex + side * 11, y: y)
        var control = CGPoint(x: ex, y: y)
        switch c.browShape {
        case .straight:
            break
        case .arched:
            control.y = y - 7
        case .angled:
            inner.y = y + 2; outer.y = y - 5; control.y = y - 3
        case .down:
            inner.y = y - 2; outer.y = y + 4; control.y = y - 1
        }
        let width: CGFloat
        switch c.browThickness {
        case .thin: width = 2
        case .normal: width = 3.5
        case .thick: width = 5.5
        }
        var path = Path()
        path.move(to: inner)
        path.addQuadCurve(to: outer, control: control)
        // 髪なし・明るい髪でも眉が消えないよう、少し暗くする
        ctx.stroke(path, with: .color(hair), style: pen(width))
        ctx.stroke(path, with: .color(.black.opacity(0.2)), style: pen(width))
    }

    // MARK: 小物

    func glasses(_ ctx: inout GraphicsContext) {
        guard c.glasses != .none else { return }
        let frame = GraphicsContext.Shading.color(ink)
        let half: CGFloat = 14
        for side: CGFloat in [-1, 1] {
            let ex = cx + side * eyeDX
            let rect = CGRect(x: ex - half, y: eyeY - 11, width: half * 2, height: 22)
            switch c.glasses {
            case .round:
                ctx.stroke(circle(CGPoint(x: ex, y: eyeY), 13), with: frame, style: pen(2.5))
            case .sunglasses:
                ctx.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(ink.opacity(0.93)))
            default:
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 5), with: frame, style: pen(2.5))
            }
            // つる
            var temple = Path()
            temple.move(to: CGPoint(x: ex + side * half, y: eyeY - 3))
            temple.addLine(to: CGPoint(x: cx + side * face.w, y: eyeY - 5))
            ctx.stroke(temple, with: frame, style: pen(2.2))
        }
        var bridge = Path()
        bridge.move(to: CGPoint(x: cx - eyeDX + half, y: eyeY - 2))
        bridge.addQuadCurve(to: CGPoint(x: cx + eyeDX - half, y: eyeY - 2), control: CGPoint(x: cx, y: eyeY - 6))
        ctx.stroke(bridge, with: frame, style: pen(2.2))
    }

    func hat(_ ctx: inout GraphicsContext) {
        guard c.hat != .none else { return }
        let main = Color(hex: 0x3B5BA5)
        let dark = Color(hex: 0x2A4380)
        let baseY = faceTop + 16
        let left = CGPoint(x: hairLeft.x - 2, y: baseY)
        let right = CGPoint(x: hairRight.x + 2, y: baseY)
        let width = right.x - left.x

        var dome = Path()
        dome.move(to: left)
        addDome(&dome, from: left, to: right, topY: hairTop - 10)
        dome.closeSubpath()

        switch c.hat {
        case .none:
            break
        case .cap:
            ctx.fill(dome, with: .color(main))
            ctx.fill(Path(ellipseIn: CGRect(x: left.x + 6, y: baseY - 7, width: width - 12, height: 16)), with: .color(dark))
        case .beanie:
            ctx.fill(circle(CGPoint(x: cx, y: hairTop - 12), 9), with: .color(dark))
            ctx.fill(dome, with: .color(main))
            ctx.fill(Path(roundedRect: CGRect(x: left.x - 2, y: baseY - 13, width: width + 4, height: 15), cornerRadius: 7), with: .color(dark))
        case .hat:
            ctx.fill(Path(ellipseIn: CGRect(x: left.x - 26, y: baseY - 9, width: width + 52, height: 18)), with: .color(dark))
            ctx.fill(dome, with: .color(main))
        }
    }
}

#Preview {
    AvatarView(config: AvatarConfig(hairLength: .medium, hairColor: .darkBrown, bangs: .side, glasses: .square))
        .padding(40)
}
