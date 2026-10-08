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
    var phase = 0.0
    var hero = false
    var reduceMotionOverride: Bool?
    override var isFlipped: Bool { true }
    private static let body: NSBezierPath = {
        let path = NSBezierPath()
        for command in MonsterGeometry.commands {
            switch command {
            case let .move(x,y): path.move(to:NSPoint(x:x,y:y))
            case let .curve(x1,y1,x2,y2,x3,y3): path.curve(to:NSPoint(x:x3,y:y3), controlPoint1:NSPoint(x:x1,y:y1), controlPoint2:NSPoint(x:x2,y:y2))
            case .close: path.close()
            }
        }
        return path
    }()
    override func draw(_ dirtyRect: NSRect) { drawScene(in: bounds) }
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
        NSColor(calibratedWhite:0.65,alpha:0.28).setStroke()
        Self.body.lineWidth = 0.85; Self.body.stroke()
        context.restoreGState()
        NSColor.monsterHex(remaining == nil ? "#90969d" : style.remainingColor).setFill(); Self.body.fill()
        if let cutoff {
            context.saveGState(); Self.body.addClip()
            NSColor.monsterHex(style.usedColor).setFill()
            NSRect(x:0,y:cutoff,width:48,height:48-cutoff).fill(); context.restoreGState()
        }
        let bodyColor = NSColor.monsterHex((remaining ?? 0) < 40 ? style.usedColor : style.remainingColor)
        let rgb = bodyColor.usingColorSpace(.sRGB) ?? .white
        let light = rgb.redComponent*0.2126 + rgb.greenComponent*0.7152 + rgb.blueComponent*0.0722
        (light > 0.5 ? NSColor.monsterHex("#171b21") : .white).setFill()
        for x in [20.0,26.0] { NSBezierPath(roundedRect:NSRect(x:x,y:17,width:4,height:8),xRadius:2,yRadius:2).fill() }
        context.restoreGState()
        // The tracks and both corner arcs stay inside the icon's rounded clipping mask.
        NSColor.monsterHex(style.shortRingColor).withAlphaComponent(0.12).setStroke(); Self.ringTracks[0].stroke()
        NSColor.monsterHex(style.weekRingColor).withAlphaComponent(0.12).setStroke(); Self.ringTracks[1].stroke()
        NSColor.monsterHex(style.shortRingColor).withAlphaComponent(0.72).setStroke(); shortRing?.stroke()
        NSColor.monsterHex(style.weekRingColor).withAlphaComponent(0.52).setStroke(); weekRing?.stroke()
        // Unknown quota and old snapshots have an explicit neutral/stale marker, never a fake zero.
        if remaining == nil || weekRemaining == nil || stale {
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
