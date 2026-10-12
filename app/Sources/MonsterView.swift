import AppKit

extension NSColor {
    static func monsterHex(_ hex: String) -> NSColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: Double((value >> 16) & 255)/255,
                       green: Double((value >> 8) & 255)/255,
                       blue: Double(value & 255)/255, alpha: 1)
    }
    static func monsterHSL(_ hue: Double, _ saturation: Double, _ lightness: Double) -> NSColor {
        let chroma = (1-abs(2*lightness-1))*saturation, h = hue/60
        let x = chroma*(1-abs(h.truncatingRemainder(dividingBy:2)-1)), m = lightness-chroma/2
        let rgb: (Double,Double,Double)
        switch h { case ..<1: rgb = (chroma,x,0); case ..<2: rgb = (x,chroma,0); case ..<3: rgb = (0,chroma,x)
        case ..<4: rgb = (0,x,chroma); case ..<5: rgb = (x,0,chroma); default: rgb = (chroma,0,x) }
        return NSColor(srgbRed:rgb.0+m,green:rgb.1+m,blue:rgb.2+m,alpha:1)
    }
    var monsterHexString: String {
        let rgb = usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02x%02x%02x", Int((rgb.redComponent*255).rounded()),
                      Int((rgb.greenComponent*255).rounded()), Int((rgb.blueComponent*255).rounded()))
    }
}

/// One renderer shared by the window and Dock. All drawing uses a 128-point SVG coordinate system.
final class MonsterView: NSView {
    var style = MonsterAppearance()
    var remaining: Int? { didSet { if oldValue != remaining { cutoff = remaining.map { MonsterGeometry.cutoff(remaining: Double($0)/100) } } } }
    private var cutoff: Double?
    var weekRemaining: Int?
    var shortTime = MonsterTimeWindow(window:nil,now:Date(timeIntervalSince1970:0)) { didSet { if shortTime.progress != oldValue.progress { shortRing = Self.ring(shortTime.progress,inset:6.5,radius:21.5) } } }
    var weekTime = MonsterTimeWindow(window:nil,now:Date(timeIntervalSince1970:0)) { didSet { if weekTime.progress != oldValue.progress { weekRing = Self.ring(weekTime.progress,inset:12,radius:16) } } }
    private var shortRing: NSBezierPath?
    private var weekRing: NSBezierPath?
    private static func ring(_ progress: Double?, inset: Double, radius: Double) -> NSBezierPath? {
        guard let progress, progress > 0 else { return nil }
        let points = MonsterTimeRing.points(progress:progress,inset:inset,radius:radius)
        let path = NSBezierPath(); path.move(to:NSPoint(x:points[0].x,y:points[0].y))
        for point in points.dropFirst() { path.line(to:NSPoint(x:point.x,y:point.y)) }
        if progress >= 1 { path.close() }
        path.lineWidth = 2.4; path.lineCapStyle = .round; path.lineJoinStyle = .round
        return path
    }
    private static let ringTracks = [ring(1,inset:6.5,radius:21.5)!,ring(1,inset:12,radius:16)!]
    var cpu: Double?
    var gpu: Double?
    var proxyEnabled: Bool?
    var stale = false
    /// New API 富足度。非 nil 时启用零钱罐形态与弯眼微笑。
    var prosperity: NewAPI.Prosperity?
    /// 零钱罐形态与原轮廓的混合比例 0...1。1 为完全零钱罐。
    var blend = 0.0
    var phase = 0.0
    var hero = false
    var reduceMotionOverride: Bool?
    override var isFlipped: Bool { true }
    private static func path(_ commands: [MonsterGeometry.Command]) -> NSBezierPath {
        let path = NSBezierPath()
        for command in commands {
            switch command {
            case let .move(x,y): path.move(to:NSPoint(x:x,y:y))
            case let .curve(x1,y1,x2,y2,x3,y3): path.curve(to:NSPoint(x:x3,y:y3), controlPoint1:NSPoint(x:x1,y:y1), controlPoint2:NSPoint(x:x2,y:y2))
            case .close: path.close()
            }
        }
        return path
    }
    private static let body = path(MonsterGeometry.commands)
    /// 零钱罐形态轮廓。仅在 New API 来源下使用。
    private static let piggyBody = path(MonsterGeometry.piggyCommands)
    /// 零钱罐形态下的硬币数量。四档富足度各配一个可辨识的数量，
    /// 让「剩多少钱」在 43pt 下也能读出量级差别，而不是只靠颜色。
    ///
    /// 注意这表达的是**绝对金额**（每枚代表一个固定额度档），不是百分比：
    /// New API 没有可信的周期分母，做成百分比等于伪造。金额档位阈值待实测校准。
    static func coinCount(_ prosperity: NewAPI.Prosperity) -> Int {
        switch prosperity {
        case .abundant: return 8
        case .comfortable: return 6
        case .tight: return 4
        case .drained: return 2
        case .unknown: return 0
        }
    }

    /// 富足度 → 微笑程度 0...1。
    ///
    /// §20.2 禁止嘴、鼻、耳，所以「微笑」只能落在眼形上：
    /// §20.3 已认可 happy 用「向上弯起的弯眼」，这里复用同一条通道，
    /// 不新增任何面部结构。
    static func smile(_ prosperity: NewAPI.Prosperity) -> Double {
        switch prosperity {
        case .abundant: return 1.0
        case .comfortable: return 0.78
        case .tight: return 0.5
        case .drained: return 0.0
        case .unknown: return 0.5
        }
    }

    override func draw(_ dirtyRect: NSRect) { drawScene(in: bounds) }

    /// 眼睛。`prosperity` 为 nil 时是 Codex 的竖椭圆眼；
    /// 非 nil 时按微笑程度把上缘向上弯——§20.2 禁止嘴鼻耳，
    /// 「微笑」只能走 §20.3 已认可的弯眼通道。
    private func drawEyes(in context: CGContext, prosperity: NewAPI.Prosperity?) {
        let bodyColor = NSColor.monsterHex((remaining ?? 0) < 40 ? style.usedColor : style.remainingColor)
        let rgb = bodyColor.usingColorSpace(.sRGB) ?? .white
        let light = rgb.redComponent*0.2126 + rgb.greenComponent*0.7152 + rgb.blueComponent*0.0722
        (light > 0.5 ? NSColor.monsterHex("#171b21") : .white).setFill()
        // 零钱罐形态的眼睛位置与原形不同，硬套原坐标会让眼睛掉出身体。
        typealias Anatomy = MonsterGeometry.PiggyAnatomy
        let eyes: [(x: Double, y: Double)] = prosperity == nil ? [(20, 17), (26, 17)] : Anatomy.eyes
        let eyeWidth = prosperity == nil ? 4.0 : Anatomy.eyeWidth
        let eyeHeight = prosperity == nil ? 8.0 : Anatomy.eyeHeight
        for (index, eye) in eyes.enumerated() {
            let x = eye.x, y0 = eye.y
            guard let prosperity else {
                NSBezierPath(roundedRect: NSRect(x: x, y: y0, width: eyeWidth, height: eyeHeight),
                             xRadius: 2, yRadius: 2).fill()
                continue
            }
            let amount = Self.smile(prosperity)
            let y1 = y0 + eyeHeight, w = eyeWidth
            // 弯度：0 为竖椭圆（与 Codex 眼一致），1 为明显上弯的弯眼。
            //
            // 上缘向上拱、下缘压平，两者同时随 amount 变化——只弯一条边会读成
            // 「眼睛歪了」，两条边一起弯才是「眯眼笑」。两只眼按 index 轻微
            // 错开，避免整排弯眼看着像机械复制。
            let skew = amount * (index == 0 ? 1.0 : 0.86)
            let rise = eyeHeight * 0.62 * skew
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: y0))
            // 下缘：由中间高点回落到两端，弧顶高度随笑度上升
            path.curve(to: NSPoint(x: x + w, y: y0),
                       controlPoint1: NSPoint(x: x + w*0.18, y: y0 + rise*0.92),
                       controlPoint2: NSPoint(x: x + w*0.82, y: y0 + rise*0.92))
            // 上缘：由两端拱到中间，与下缘合成弧形而非斜块
            path.curve(to: NSPoint(x: x, y: y1),
                       controlPoint1: NSPoint(x: x + w*0.82, y: y1 + rise*0.55),
                       controlPoint2: NSPoint(x: x + w*0.18, y: y1 + rise*0.55))
            path.close()
            path.fill()
        }
    }

    /// 零钱罐形态。仅在 New API 来源且拿到钱包时绘制。
    ///
    /// 单独一层而不是替换身体：§20.4 要求「身体连续重塑为物品」，
    /// 但那只描述造型意图；实际绘制上，形态之间不应该出现跳变，
    /// 否则切来源的瞬间会闪一下。所以这里的零钱罐与原轮廓是**叠加**
    /// 在同一坐标里，形态切换留给后续的变形动画，中间态由 blend 控制。
    private func drawPiggy(in context: CGContext) {
        // 调用方已处于角色变换内（与原身体同一坐标），这里不要再做定位。
        guard let prosperity else { return }
        context.saveGState()
        // 从原形「长」成零钱罐：以身体底边中心为锚点轻微放大，
        // 让形态变化看起来是生长而不是贴图切换。
        let grow = 1 + (1-blend)*0.06
        context.translateBy(x: 24.5, y: 41)
        context.scaleBy(x: blend*grow, y: blend*grow)
        context.translateBy(x: -24.5, y: -41)

        typealias Anatomy = MonsterGeometry.PiggyAnatomy
        let color = NSColor.monsterHex(style.remainingColor)
        color.setFill()
        Self.piggyBody.fill()

        // 投币口：画在背脊上缘偏左，居中会被读成嘴。
        NSColor.monsterHex("#171b21").withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: Anatomy.slot.x, y: Anatomy.slot.y,
                                        width: Anatomy.slot.width, height: Anatomy.slot.height),
                     xRadius: Anatomy.slot.height/2, yRadius: Anatomy.slot.height/2).fill()

        // 硬币：表达绝对金额的数量，不表达百分比。
        let coins = Self.coinCount(prosperity)
        if coins > 0 {
            let rgb = color.usingColorSpace(.sRGB) ?? .white
            let light = rgb.redComponent*0.2126 + rgb.greenComponent*0.7152 + rgb.blueComponent*0.0722
            NSColor.monsterHex(light > 0.5 ? "#c9a34b" : "#e2b95f").setFill()
            NSColor.monsterHex("#171b21").withAlphaComponent(0.3).setStroke()
            // 自投币口向上堆，两列交错；硬币不得超出 48×48 画布上沿，
            // 超出就跳过而不是画到图标外面。
            for i in 0..<coins {
                let column = i % 2, rank = i / 2
                let cx = Anatomy.coinCenter.x + Double(column)*Anatomy.coinColumnGap
                let cy = Anatomy.coinCenter.y - Double(rank)*Anatomy.coinSpacing
                guard cy - Anatomy.coinRadius > 1 else { continue }
                let coin = NSBezierPath(ovalIn: NSRect(x: cx - Anatomy.coinRadius, y: cy - Anatomy.coinRadius,
                                            width: Anatomy.coinRadius*2, height: Anatomy.coinRadius*2))
                coin.lineWidth = 0.35
                coin.fill(); coin.stroke()
            }
        }
        context.restoreGState()
    }
    func drawScene(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x:rect.minX,y:rect.minY)
        context.scaleBy(x:rect.width/128,y:rect.height/128)
        // The instrument Dock view is not flipped; convert it to the same scene coordinates.
        if !NSGraphicsContext.current!.isFlipped { context.translateBy(x:0,y:128); context.scaleBy(x:1,y:-1) }
        NSBezierPath(roundedRect:NSRect(x:0,y:0,width:128,height:128),xRadius:25.6,yRadius:25.6).addClip()
        let week = Double(weekRemaining ?? 50)/100
        NSColor.monsterHSL(220-week*18,0.24+week*0.08,0.12+week*0.12).setFill()
        NSRect(x:0,y:0,width:128,height:128).fill()
        if weekRemaining != nil {
            NSColor.monsterHSL(25+week*18,0.75,0.62+week*0.12).setFill()
            NSBezierPath(ovalIn:NSRect(x:93,y:115-week*90-10,width:20,height:20)).fill()
        }
        let ground = NSBezierPath()
        ground.move(to:NSPoint(x:0,y:105))
        ground.curve(to:NSPoint(x:64,y:105),controlPoint1:NSPoint(x:21,y:101),controlPoint2:NSPoint(x:43,y:101))
        ground.curve(to:NSPoint(x:128,y:105),controlPoint1:NSPoint(x:85,y:109),controlPoint2:NSPoint(x:107,y:109))
        ground.line(to:NSPoint(x:128,y:128)); ground.line(to:NSPoint(x:0,y:128)); ground.close()
        NSColor.monsterHex(proxyEnabled.map { $0 ? style.groundOnColor : style.groundOffColor } ?? "#45464b").setFill(); ground.fill()
        NSColor(calibratedWhite:0.03,alpha:0.45).setFill()
        NSBezierPath(ovalIn:NSRect(x:30,y:105,width:60,height:6)).fill()
        context.saveGState()
        let c = min(1,max(0,cpu ?? 0)), g = min(1,max(0,gpu ?? 0)), gain = style.intensity/100
        let moving = style.motion && !(reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let pulse = moving ? sin(phase*(1+c*5)) : 0
        let squeeze = moving ? sin(phase*(1.4+g*5))*(0.003+g*0.09)*gain : 0
        let stretch = min(1.2,1+c*0.16+pulse*c*0.035*gain)
        let wide = 1+g*0.1+squeeze
        let scale = (hero ? 2.05 : 1.85)*style.size/100
        context.translateBy(x:57-24.5*scale,y:107-41*scale)
        context.scaleBy(x:scale,y:scale)
        context.translateBy(x:24.5,y:41+max(-2.5,min(2.5,pulse*c*2.5*gain)))
        context.scaleBy(x:wide,y:stretch*(1-squeeze*0.25))
        context.translateBy(x:-24.5,y:-41)
        // 零钱罐形态与原轮廓必须画在**同一个变换里**。
        //
        // 之前把 drawPiggy 放在角色变换之外（restoreGState 之后），结果零钱罐
        // 用未经缩放的 48×48 坐标直接画，而原身体经过了 scale/wide/stretch，
        // 两者根本不在同一位置——渲染出来是白色零钱罐浮在灰色身体左上角，
        // 完全脱开。形态是「身体重塑」，不是「旁边多一个东西」。
        let piggyForm = blend > 0.01 && prosperity != nil
        let echoAlpha = piggyForm ? 0.28*(1-blend) : 0.28
        context.saveGState()
        context.translateBy(x:3,y:-0.7)
        if weekRemaining != nil {
            // Keep the original contour echo behind the sun, including at the maximum size/load.
            let sx = scale*wide, sy = scale*stretch*(1-squeeze*0.25)
            let vertical = max(-2.5,min(2.5,pulse*c*2.5*gain))*scale
            context.addRect(CGRect(x:-1000,y:-1000,width:2000,height:2000))
            context.addEllipse(in:CGRect(x:(93-57)/sx+24.5-3,
                y:(115-week*90-10-107-vertical)/sy+41+0.7,width:20/sx,height:20/sy))
            context.clip(using:.evenOdd)
        }
        NSColor(calibratedWhite:0.65,alpha:echoAlpha).setStroke()
        Self.body.lineWidth = 0.85; Self.body.stroke()
        context.restoreGState()
        NSColor.monsterHex(remaining == nil ? "#90969d" : style.remainingColor)
            .withAlphaComponent(piggyForm ? 1-blend : 1).setFill()
        Self.body.fill()
        if let cutoff, !piggyForm {
            context.saveGState(); Self.body.addClip()
            NSColor.monsterHex(style.usedColor).setFill()
            NSRect(x:0,y:cutoff,width:48,height:48-cutoff).fill(); context.restoreGState()
        }
        if piggyForm { drawPiggy(in: context) }
        drawEyes(in: context, prosperity: blend > 0.5 ? prosperity : nil)
        context.restoreGState()
        // 时间环与太阳只属于 Codex 形态：New API 没有 5h/周窗口，
        // 画出来等于伪造一个不存在的周期预算。轨道同样不画——空轨道会让人
        // 以为「时间进度还没开始」。
        if !piggyForm {
            // The tracks and both corner arcs stay inside the icon's rounded clipping mask.
            NSColor.monsterHex(style.shortRingColor).withAlphaComponent(0.12).setStroke(); Self.ringTracks[0].stroke()
            NSColor.monsterHex(style.weekRingColor).withAlphaComponent(0.12).setStroke(); Self.ringTracks[1].stroke()
            NSColor.monsterHex(style.shortRingColor).withAlphaComponent(0.72).setStroke(); shortRing?.stroke()
            NSColor.monsterHex(style.weekRingColor).withAlphaComponent(0.52).setStroke(); weekRing?.stroke()
        }
        // Unknown quota and old snapshots have an explicit neutral/stale marker, never a fake zero.
        //
        // 零钱罐形态下 remaining/weekRemaining 本来就是 nil（New API 没有百分比），
        // 这不是「数据未知」，不能画问号——那会变成「零钱罐数据不明」，
        // 而实际是额度来源没有这个口径。问号只在 blend 为 0 的 Codex 形态出现。
        if blend <= 0.01 && (remaining == nil || weekRemaining == nil || stale) {
            let mark = stale ? "旧" : "?"
            context.saveGState()
            context.translateBy(x:18,y:18)
            if !NSGraphicsContext.current!.isFlipped { context.translateBy(x:0,y:17); context.scaleBy(x:1,y:-1) }
            (mark as NSString).draw(at:.zero,withAttributes:[.font:NSFont.systemFont(ofSize:14,weight:.medium),.foregroundColor:stale ? NSColor.systemOrange : NSColor.white])
            context.restoreGState()
        }
    }
}

/// Appearance controls stay in a compact separate window so the general settings remain usable.
final class MonsterSettingsController: NSObject, NSWindowDelegate {
    private var timer: Timer?
    let window: NSWindow
    private var value: MonsterAppearance
    private let onChange: (MonsterAppearance) -> Void
    private let preview = MonsterView(frame:NSRect(x:130,y:286,width:140,height:140))
    private let previewProxy = NSButton(checkboxWithTitle:"预览代理开启",target:nil,action:nil)
    private let motion = NSButton(checkboxWithTitle:"播放角色律动",target:nil,action:nil)
    private var wells: [NSColorWell] = []
    private var sliders: [NSSlider] = []
    private var labels: [NSTextField] = []
    init(appearance: MonsterAppearance, onChange: @escaping (MonsterAppearance) -> Void) {
        value = appearance; self.onChange = onChange
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:458),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        super.init()
        window.title = "Monster 外观"; window.isReleasedWhenClosed = false; window.delegate = self
        let content = window.contentView!
        preview.remaining = 70; preview.weekRemaining = 68; preview.cpu = 0.8; preview.gpu = 0.95; preview.proxyEnabled = true
        let now = Date(timeIntervalSince1970:1_700_000_000)
        preview.shortTime = MonsterTimeWindow(window:QuotaWindow(used:30,minutes:300,resetsAt:now.addingTimeInterval(180*60)),now:now)
        preview.weekTime = MonsterTimeWindow(window:QuotaWindow(used:32,minutes:10080,resetsAt:now.addingTimeInterval(10080*60*0.72)),now:now)
        content.addSubview(preview)
        let hint = NSTextField(labelWithString:"示例 · 5h 70% / 周 68% · CPU 80% / GPU 95%")
        hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor
        hint.alignment = .center; hint.frame = NSRect(x:20,y:264,width:360,height:18); content.addSubview(hint)
        previewProxy.frame = NSRect(x:20,y:14,width:180,height:22)
        previewProxy.state = .on; previewProxy.target = self; previewProxy.action = #selector(changePreviewProxy)
        content.addSubview(previewProxy)
        let keys = ["剩余额度色","已用额度色","代理开启地面色","代理关闭地面色","5h 外圈色","周 内圈色"]
        for (i,title) in keys.enumerated() {
            let x = CGFloat(i%2)*188+20, y = CGFloat(2-i/2)*42+148
            let label = NSTextField(labelWithString:title); label.frame = NSRect(x:x,y:y+6,width:130,height:20); content.addSubview(label)
            let well = NSColorWell(frame:NSRect(x:x+130,y:y,width:34,height:28)); well.tag = i; well.target = self; well.action = #selector(changed); content.addSubview(well); wells.append(well)
        }
        for i in 0..<2 {
            let y = CGFloat(1-i)*30+76
            let label = NSTextField(labelWithString:""); label.frame = NSRect(x:20,y:y,width:150,height:20); content.addSubview(label); labels.append(label)
            let slider = NSSlider(value:100,minValue:i == 0 ? 85 : 0,maxValue:i == 0 ? 110 : 150,target:self,action:#selector(changed)); slider.frame = NSRect(x:170,y:y,width:210,height:20); slider.isContinuous = true; content.addSubview(slider); sliders.append(slider)
        }
        motion.frame = NSRect(x:20,y:44,width:180,height:22); motion.target = self; motion.action = #selector(changed); content.addSubview(motion)
        let reset = NSButton(title:"恢复默认外观",target:self,action:#selector(reset)); reset.frame = NSRect(x:250,y:12,width:130,height:28); content.addSubview(reset)
        refresh()
    }
    func show() {
        window.center(); window.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        let animation = Timer(timeInterval:0.1,repeats:true) { [weak self] _ in
            guard let self, self.value.motion, self.value.intensity > 0,
                  self.window.occlusionState.contains(.visible),
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            self.preview.phase = ProcessInfo.processInfo.systemUptime; self.preview.needsDisplay = true
        }
        animation.tolerance = 0.02; RunLoop.main.add(animation,forMode:.common); timer = animation
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
    private func refresh() {
        for (well,color) in zip(wells,[value.remainingColor,value.usedColor,value.groundOnColor,value.groundOffColor,value.shortRingColor,value.weekRingColor]) { well.color = .monsterHex(color) }
        sliders[0].doubleValue = value.size; sliders[1].doubleValue = value.intensity
        motion.state = value.motion ? .on : .off
        labels[0].stringValue = "角色大小 \(Int(value.size))%"; labels[1].stringValue = "动作强度 \(Int(value.intensity))%"
        preview.style = value; preview.needsDisplay = true
    }
    @objc private func changePreviewProxy() {
        preview.proxyEnabled = previewProxy.state == .on; preview.needsDisplay = true
    }
    @objc private func changed() {
        value.remainingColor = wells[0].color.monsterHexString; value.usedColor = wells[1].color.monsterHexString
        value.groundOnColor = wells[2].color.monsterHexString; value.groundOffColor = wells[3].color.monsterHexString
        value.shortRingColor = wells[4].color.monsterHexString; value.weekRingColor = wells[5].color.monsterHexString
        value.size = sliders[0].doubleValue; value.intensity = sliders[1].doubleValue; value.motion = motion.state == .on
        refresh(); onChange(value)
    }
    @objc private func reset() { let enabled = value.enabled; value = MonsterAppearance(); value.enabled = enabled; refresh(); onChange(value) }
}
