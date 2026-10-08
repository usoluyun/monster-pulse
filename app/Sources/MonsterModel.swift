import Foundation

/// Shared character contour, derived from Resources/AppIcon.svg (artwork all rights reserved).
/// Coordinates follow SVG: y grows downwards. No AppKit required for quota area mapping.
enum MonsterGeometry {
    enum Command { case move(Double, Double), curve(Double, Double, Double, Double, Double, Double), close }
    static let commands: [Command] = [
        .move(20.0000, 6.0000),
        .curve(20.3024, 6.0028, 20.6094, 6.0248, 20.9064, 6.0791),
        .curve(21.2034, 6.1334, 21.5007, 6.2162, 21.7818, 6.3260),
        .curve(22.0629, 6.4358, 22.3365, 6.5781, 22.5930, 6.7377),
        .curve(22.8495, 6.8974, 23.0920, 7.0859, 23.3210, 7.2839),
        .curve(23.5500, 7.4819, 23.7629, 7.7014, 23.9669, 7.9256),
        .curve(24.1709, 8.1498, 24.3606, 8.3884, 24.5453, 8.6292),
        .curve(24.7300, 8.8700, 24.9034, 9.1198, 25.0750, 9.3703),
        .curve(25.2466, 9.6208, 25.4102, 9.8768, 25.5748, 10.1320),
        .curve(25.7394, 10.3872, 25.8990, 10.6456, 26.0627, 10.9014),
        .curve(26.2264, 11.1572, 26.3879, 11.4145, 26.5567, 11.6669),
        .curve(26.7255, 11.9193, 26.8950, 12.1718, 27.0757, 12.4156),
        .curve(27.2565, 12.6594, 27.4411, 12.9019, 27.6412, 13.1296),
        .curve(27.8413, 13.3573, 28.0496, 13.5816, 28.2764, 13.7818),
        .curve(28.5032, 13.9820, 28.7460, 14.1703, 29.0019, 14.3310),
        .curve(29.2578, 14.4917, 29.5361, 14.6205, 29.8121, 14.7461),
        .curve(30.0881, 14.8717, 30.3722, 14.9819, 30.6578, 15.0844),
        .curve(30.9434, 15.1869, 31.2343, 15.2758, 31.5256, 15.3614),
        .curve(31.8169, 15.4470, 32.1119, 15.5201, 32.4055, 15.5978),
        .curve(32.6991, 15.6755, 32.9951, 15.7445, 33.2871, 15.8275),
        .curve(33.5791, 15.9105, 33.8728, 15.9918, 34.1575, 16.0960),
        .curve(34.4422, 16.2002, 34.7266, 16.3134, 34.9951, 16.4527),
        .curve(35.2636, 16.5920, 35.5261, 16.7514, 35.7688, 16.9316),
        .curve(36.0115, 17.1118, 36.2403, 17.3168, 36.4513, 17.5336),
        .curve(36.6623, 17.7504, 36.8551, 17.9884, 37.0350, 18.2322),
        .curve(37.2148, 18.4760, 37.3756, 18.7354, 37.5304, 18.9963),
        .curve(37.6852, 19.2572, 37.8221, 19.5291, 37.9637, 19.7977),
        .curve(38.1053, 20.0663, 38.2432, 20.3370, 38.3799, 20.6081),
        .curve(38.5166, 20.8792, 38.6512, 21.1514, 38.7841, 21.4245),
        .curve(38.9170, 21.6976, 39.0480, 21.9716, 39.1771, 22.2465),
        .curve(39.3062, 22.5214, 39.4335, 22.7971, 39.5588, 23.0737),
        .curve(39.6841, 23.3503, 39.8076, 23.6278, 39.9291, 23.9061),
        .curve(40.0506, 24.1844, 40.1702, 24.4637, 40.2877, 24.7437),
        .curve(40.4052, 25.0237, 40.5207, 25.3046, 40.6339, 25.5864),
        .curve(40.7471, 25.8682, 40.8582, 26.1509, 40.9667, 26.4345),
        .curve(41.0752, 26.7181, 41.1816, 27.0026, 41.2851, 27.2881),
        .curve(41.3886, 27.5736, 41.4897, 27.8600, 41.5875, 28.1475),
        .curve(41.6853, 28.4350, 41.7807, 28.7234, 41.8721, 29.0130),
        .curve(41.9636, 29.3026, 42.0521, 29.5931, 42.1362, 29.8849),
        .curve(42.2203, 30.1767, 42.3011, 30.4695, 42.3766, 30.7636),
        .curve(42.4521, 31.0577, 42.5240, 31.3529, 42.5891, 31.6495),
        .curve(42.6542, 31.9460, 42.7150, 32.2439, 42.7674, 32.5429),
        .curve(42.8198, 32.8419, 42.8671, 33.1424, 42.9034, 33.4437),
        .curve(42.9397, 33.7450, 42.9712, 34.0480, 42.9849, 34.3509),
        .curve(42.9987, 34.6538, 43.0131, 34.9605, 42.9859, 35.2613),
        .curve(42.9587, 35.5621, 42.9078, 35.8669, 42.8217, 36.1557),
        .curve(42.7356, 36.4445, 42.6143, 36.7296, 42.4692, 36.9939),
        .curve(42.3241, 37.2582, 42.1446, 37.5096, 41.9509, 37.7413),
        .curve(41.7572, 37.9730, 41.5360, 38.1867, 41.3068, 38.3842),
        .curve(41.0776, 38.5817, 40.8290, 38.7605, 40.5755, 38.9264),
        .curve(40.3220, 39.0923, 40.0555, 39.2413, 39.7857, 39.3797),
        .curve(39.5159, 39.5181, 39.2375, 39.6421, 38.9568, 39.7571),
        .curve(38.6761, 39.8721, 38.3895, 39.9749, 38.1013, 40.0699),
        .curve(37.8131, 40.1649, 37.5208, 40.2495, 37.2274, 40.3271),
        .curve(36.9340, 40.4047, 36.6378, 40.4733, 36.3407, 40.5357),
        .curve(36.0436, 40.5981, 35.7446, 40.6526, 35.4449, 40.7013),
        .curve(35.1452, 40.7500, 34.8441, 40.7919, 34.5427, 40.8281),
        .curve(34.2413, 40.8643, 33.9388, 40.8940, 33.6362, 40.9185),
        .curve(33.3336, 40.9430, 33.0302, 40.9618, 32.7269, 40.9752),
        .curve(32.4236, 40.9886, 32.1198, 40.9960, 31.8162, 40.9990),
        .curve(31.5126, 41.0021, 31.2088, 40.9995, 30.9052, 40.9935),
        .curve(30.6016, 40.9875, 30.2979, 40.9783, 29.9947, 40.9629),
        .curve(29.6915, 40.9475, 29.3882, 40.9282, 29.0858, 40.9009),
        .curve(28.7834, 40.8736, 28.4811, 40.8412, 28.1805, 40.7992),
        .curve(27.8799, 40.7572, 27.5799, 40.7075, 27.2820, 40.6490),
        .curve(26.9841, 40.5905, 26.6886, 40.5196, 26.3934, 40.4484),
        .curve(26.0982, 40.3772, 25.8065, 40.2915, 25.5110, 40.2217),
        .curve(25.2155, 40.1519, 24.9197, 40.0796, 24.6206, 40.0298),
        .curve(24.3215, 39.9800, 24.0188, 39.9444, 23.7163, 39.9230),
        .curve(23.4138, 39.9016, 23.1091, 39.8971, 22.8057, 39.9016),
        .curve(22.5023, 39.9061, 22.1984, 39.9232, 21.8961, 39.9500),
        .curve(21.5938, 39.9768, 21.2922, 40.0165, 20.9922, 40.0625),
        .curve(20.6922, 40.1085, 20.3938, 40.1667, 20.0960, 40.2260),
        .curve(19.7982, 40.2853, 19.5023, 40.3538, 19.2055, 40.4182),
        .curve(18.9087, 40.4826, 18.6128, 40.5516, 18.3153, 40.6123),
        .curve(18.0178, 40.6730, 17.7198, 40.7330, 17.4203, 40.7825),
        .curve(17.1208, 40.8320, 16.8200, 40.8762, 16.5183, 40.9096),
        .curve(16.2166, 40.9430, 15.9134, 40.9680, 15.6103, 40.9827),
        .curve(15.3072, 40.9974, 15.0028, 41.0048, 14.6995, 40.9980),
        .curve(14.3962, 40.9912, 14.0923, 40.9719, 13.7904, 40.9422),
        .curve(13.4885, 40.9125, 13.1869, 40.8708, 12.8878, 40.8199),
        .curve(12.5887, 40.7690, 12.2905, 40.7080, 11.9955, 40.6369),
        .curve(11.7005, 40.5658, 11.4070, 40.4851, 11.1177, 40.3935),
        .curve(10.8284, 40.3019, 10.5412, 40.2008, 10.2598, 40.0874),
        .curve(9.9784, 39.9740, 9.6998, 39.8506, 9.4295, 39.7131),
        .curve(9.1592, 39.5756, 8.8927, 39.4269, 8.6381, 39.2626),
        .curve(8.3834, 39.0983, 8.1339, 38.9215, 7.9016, 38.7273),
        .curve(7.6693, 38.5331, 7.4450, 38.3238, 7.2442, 38.0977),
        .curve(7.0434, 37.8716, 6.8552, 37.6279, 6.6968, 37.3709),
        .curve(6.5384, 37.1138, 6.4000, 36.8378, 6.2940, 36.5554),
        .curve(6.1880, 36.2730, 6.1098, 35.9740, 6.0610, 35.6762),
        .curve(6.0122, 35.3784, 5.9988, 35.0709, 6.0014, 34.7684),
        .curve(6.0040, 34.4659, 6.0370, 34.1616, 6.0768, 33.8610),
        .curve(6.1166, 33.5604, 6.1755, 33.2614, 6.2405, 32.9650),
        .curve(6.3055, 32.6686, 6.3838, 32.3746, 6.4668, 32.0826),
        .curve(6.5498, 31.7906, 6.6423, 31.5010, 6.7384, 31.2130),
        .curve(6.8346, 30.9250, 6.9377, 30.6392, 7.0437, 30.3547),
        .curve(7.1497, 30.0702, 7.2610, 29.7875, 7.3744, 29.5058),
        .curve(7.4878, 29.2241, 7.6052, 28.9440, 7.7242, 28.6646),
        .curve(7.8431, 28.3852, 7.9651, 28.1071, 8.0881, 27.8294),
        .curve(8.2111, 27.5517, 8.3364, 27.2751, 8.4621, 26.9986),
        .curve(8.5878, 26.7221, 8.7151, 26.4464, 8.8424, 26.1707),
        .curve(8.9697, 25.8950, 9.0980, 25.6197, 9.2257, 25.3442),
        .curve(9.3534, 25.0687, 9.4816, 24.7933, 9.6084, 24.5174),
        .curve(9.7352, 24.2415, 9.8620, 23.9655, 9.9865, 23.6885),
        .curve(10.1109, 23.4115, 10.2349, 23.1342, 10.3551, 22.8553),
        .curve(10.4753, 22.5764, 10.5944, 22.2970, 10.7077, 22.0153),
        .curve(10.8210, 21.7336, 10.9327, 21.4508, 11.0349, 21.1650),
        .curve(11.1371, 20.8791, 11.2372, 20.5918, 11.3210, 20.3002),
        .curve(11.4048, 20.0086, 11.4734, 19.7123, 11.5379, 19.4157),
        .curve(11.6024, 19.1191, 11.6524, 18.8192, 11.7079, 18.5206),
        .curve(11.7634, 18.2220, 11.8156, 17.9228, 11.8706, 17.6242),
        .curve(11.9256, 17.3255, 11.9802, 17.0268, 12.0380, 16.7287),
        .curve(12.0958, 16.4306, 12.1546, 16.1326, 12.2171, 15.8354),
        .curve(12.2796, 15.5382, 12.3442, 15.2414, 12.4132, 14.9457),
        .curve(12.4822, 14.6500, 12.5540, 14.3548, 12.6311, 14.0611),
        .curve(12.7082, 13.7674, 12.7888, 13.4744, 12.8756, 13.1835),
        .curve(12.9624, 12.8926, 13.0537, 12.6027, 13.1521, 12.3155),
        .curve(13.2505, 12.0283, 13.3541, 11.7425, 13.4662, 11.4604),
        .curve(13.5783, 11.1783, 13.6966, 10.8981, 13.8248, 10.6230),
        .curve(13.9530, 10.3479, 14.0885, 10.0753, 14.2356, 9.8100),
        .curve(14.3827, 9.5447, 14.5385, 9.2828, 14.7076, 9.0310),
        .curve(14.8766, 8.7793, 15.0561, 8.5324, 15.2499, 8.2995),
        .curve(15.4437, 8.0666, 15.6501, 7.8409, 15.8707, 7.6335),
        .curve(16.0913, 7.4261, 16.3262, 7.2292, 16.5738, 7.0553),
        .curve(16.8213, 6.8814, 17.0845, 6.7233, 17.3560, 6.5902),
        .curve(17.6275, 6.4571, 17.9134, 6.3447, 18.2027, 6.2567),
        .curve(18.4920, 6.1687, 18.7922, 6.1051, 19.0918, 6.0623),
        .curve(19.3913, 6.0195, 19.6976, 5.9972, 20.0000, 6.0000),
        .close,
    ]
    static let polygon: [CGPoint] = {
        var points: [CGPoint] = [], p = CGPoint.zero
        for command in commands {
            switch command {
            case let .move(x,y): p = CGPoint(x:x,y:y); points.append(p)
            case let .curve(x1,y1,x2,y2,x3,y3):
                let origin = p
                for i in 1...12 {
                    let t = Double(i)/12, u = 1-t
                    points.append(CGPoint(x:u*u*u*origin.x + 3*u*u*t*x1 + 3*u*t*t*x2 + t*t*t*x3,
                                          y:u*u*u*origin.y + 3*u*u*t*y1 + 3*u*t*t*y2 + t*t*t*y3))
                }
                p = CGPoint(x:x3,y:y3)
            case .close: break
            }
        }
        return points
    }()
    static func area(_ points: [CGPoint]) -> Double {
        guard points.count > 2 else { return 0 }
        return abs(points.indices.reduce(0) { sum, i in
            let a = points[i], b = points[(i+1)%points.count]
            return sum + a.x*b.y-b.x*a.y
        })/2
    }
    static func whiteFraction(cutoff: Double) -> Double {
        var clipped: [CGPoint] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i+1)%polygon.count]
            if a.y <= cutoff { clipped.append(a) }
            if (a.y <= cutoff) != (b.y <= cutoff) {
                let t = (cutoff-a.y)/(b.y-a.y)
                clipped.append(CGPoint(x:a.x+t*(b.x-a.x),y:cutoff))
            }
        }
        return area(clipped)/area(polygon)
    }
    /// Binary search by contour area, rather than character height.
    static func cutoff(remaining: Double) -> Double {
        let fraction = min(1,max(0,remaining))
        if fraction == 0 { return 6 }; if fraction == 1 { return 41.01 }
        var lower = 6.0, upper = 41.01
        for _ in 0..<24 {
            let middle = (lower+upper)/2
            if whiteFraction(cutoff:middle) < fraction { lower = middle } else { upper = middle }
        }
        return (lower+upper)/2
    }
}

struct MonsterAppearance: Codable, Equatable {
    var enabled = false
    var motion = true
    var size = 100.0
    var intensity = 100.0
    var remainingColor = "#f6f4ef"
    var usedColor = "#758897"
    var groundOnColor = "#365e59"
    var groundOffColor = "#594638"
    var shortRingColor = "#f6f4ef"
    var weekRingColor = "#f6f4ef"
    enum CodingKeys: String, CodingKey {
        case enabled, motion, size, intensity, remainingColor, usedColor, groundOnColor, groundOffColor, shortRingColor, weekRingColor
    }
    static func validColor(_ value: String) -> Bool {
        value.count == 7 && value.first == "#" && UInt32(value.dropFirst(),radix:16) != nil
    }
    func validated() -> MonsterAppearance {
        var result = self
        result.size = size.isFinite ? min(110,max(85,size)) : 100
        result.intensity = intensity.isFinite ? min(150,max(0,intensity)) : 100
        let fallback = MonsterAppearance()
        if !Self.validColor(remainingColor) { result.remainingColor = fallback.remainingColor }
        if !Self.validColor(usedColor) { result.usedColor = fallback.usedColor }
        if !Self.validColor(groundOnColor) { result.groundOnColor = fallback.groundOnColor }
        if !Self.validColor(groundOffColor) { result.groundOffColor = fallback.groundOffColor }
        if !Self.validColor(shortRingColor) { result.shortRingColor = fallback.shortRingColor }
        if !Self.validColor(weekRingColor) { result.weekRingColor = fallback.weekRingColor }
        return result
    }
}

extension MonsterAppearance {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy:CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self,forKey:.enabled) ?? enabled
        motion = try values.decodeIfPresent(Bool.self,forKey:.motion) ?? motion
        size = try values.decodeIfPresent(Double.self,forKey:.size) ?? size
        intensity = try values.decodeIfPresent(Double.self,forKey:.intensity) ?? intensity
        remainingColor = try values.decodeIfPresent(String.self,forKey:.remainingColor) ?? remainingColor
        usedColor = try values.decodeIfPresent(String.self,forKey:.usedColor) ?? usedColor
        groundOnColor = try values.decodeIfPresent(String.self,forKey:.groundOnColor) ?? groundOnColor
        groundOffColor = try values.decodeIfPresent(String.self,forKey:.groundOffColor) ?? groundOffColor
        shortRingColor = try values.decodeIfPresent(String.self,forKey:.shortRingColor) ?? shortRingColor
        weekRingColor = try values.decodeIfPresent(String.self,forKey:.weekRingColor) ?? weekRingColor
    }
}


/// Time comes from the server window and wall clock, independently of quota consumption.
struct MonsterTimeWindow {
    let progress: Double?
    let reset: Date?
    init(window: QuotaWindow?, now: Date) {
        guard let reset = window?.resetsAt, reset.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite, let minutes = window?.minutes,
              let progress = QuotaFormat.windowProgress(resetsAt:reset,windowMinutes:minutes,now:now) else {
            self.progress = nil; self.reset = nil; return
        }
        self.progress = progress; self.reset = reset
    }
    func text(title: String, now: Date) -> String {
        guard let progress, let reset else { return "\(title) · 时间未知" }
        if reset <= now { return "\(title) · 已到期，等待刷新" }
        return "\(title) · 已过 \(Int(progress*100))% · \(QuotaFormat.countdown(to:reset,now:now))重置"
    }
}

/// Closed rounded rings start at the top center and travel clockwise; arc length drives progress.
enum MonsterTimeRing {
    struct Point { let x: Double; let y: Double }
    static func points(progress: Double, inset: Double, radius: Double) -> [Point] {
        let low = inset, high = 128-inset, a = low+radius, b = high-radius
        let straight = high-low-2*radius
        var remaining = min(1,max(0,progress))*(4*straight+2*Double.pi*radius)
        var result = [Point(x:64,y:low)]
        func line(_ x: Double, _ y: Double) {
            let last = result.last!, length = hypot(x-last.x,y-last.y)
            guard remaining > 0, length > 0 else { return }
            let fraction = min(1,remaining/length)
            result.append(Point(x:last.x+(x-last.x)*fraction,y:last.y+(y-last.y)*fraction))
            remaining -= length
        }
        func arc(_ x: Double, _ y: Double, _ angle: Double) {
            guard remaining > 0 else { return }
            let length = min(remaining,Double.pi*radius/2), count = max(1,Int(ceil(length/0.8)))
            for i in 1...count {
                let theta = angle+length/radius*Double(i)/Double(count)
                result.append(Point(x:x+radius*cos(theta),y:y+radius*sin(theta)))
            }
            remaining -= Double.pi*radius/2
        }
        line(b,low); arc(b,a,-Double.pi/2); line(high,b); arc(b,b,0)
        line(a,high); arc(a,b,Double.pi/2); line(low,a); arc(a,a,Double.pi)
        line(64,low)
        return result
    }
}

enum MonsterSummary {
    static func text(remaining: Int?, week: Int?, cpu: Double?, gpu: Double?, showCPU: Bool = true,
                     showGPU: Bool = true, proxy: Bool?, stale: Bool) -> String {
        func percentage(_ value: Int?) -> String { value.map { "\($0)%" } ?? "—" }
        return "5h \(percentage(remaining))   周 \(percentage(week))\nCPU \(showCPU ? percentage(cpu.map { Int($0*100) }) : "隐藏")   GPU \(showGPU ? percentage(gpu.map { Int($0*100) }) : "隐藏")   系统代理 \(proxy.map { $0 ? "开启" : "关闭" } ?? "未知")" + (stale ? " · 旧快照" : "")
    }
}
