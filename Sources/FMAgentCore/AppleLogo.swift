import Foundation

// A 3D apple rendered as shaded grey Braille dots (like donut.c): a cloud of surface points with normals is rotated
// around the vertical axis, projected with a z-buffer and lit, then drawn with dot characters.
public enum AppleLogo {
    public static let width = 34
    public static let height = 18  // terminal rows

    struct Point { var p: SIMD3<Double>, n: SIMD3<Double>, twoSided = false }

    /// Apple profile: a sphere pinched at the stem and the bottom, wider at the shoulders.
    static func radius(_ theta: Double) -> Double {
        1 - 0.42 * exp(-pow(theta / 0.5, 2)) - 0.22 * exp(-pow((.pi - theta) / 0.45, 2)) + 0.1 * cos(theta)
    }

    static let squash = 0.88  // apples are wider than tall

    static func insideApple(_ q: SIMD3<Double>) -> Bool {
        let unsquashed = SIMD3(q.x, q.y / squash, q.z)
        let length = (unsquashed * unsquashed).sum().squareRoot()
        return length < radius(acos(max(-1, min(1, unsquashed.y / max(length, 1e-9)))))
    }

    // The bite is a cylinder along z, so it reads as a notch from the side and as a hollow from the front.
    static let biteX = 1.12, biteY = 0.12, biteRadius = 0.5
    static func inBite(_ p: SIMD3<Double>) -> Bool { pow(p.x - biteX, 2) + pow(p.y - biteY, 2) < biteRadius * biteRadius }

    static let points: [Point] = {
        var points: [Point] = []
        func normalized(_ v: SIMD3<Double>) -> SIMD3<Double> { v / (v * v).sum().squareRoot() }

        // skin, minus the bite
        for i in 0...140 {
            let theta = Double.pi * Double(i) / 140, r = radius(theta)
            let slope = (radius(theta + 0.01) - radius(theta - 0.01)) / 0.02
            for j in 0..<280 {
                let phi = 2 * Double.pi * Double(j) / 280
                let dir = SIMD3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
                let p = dir * r * SIMD3(1, squash, 1)
                if inBite(p) { continue }
                let thetaDir = SIMD3(cos(theta) * cos(phi), -sin(theta), cos(theta) * sin(phi))
                let n = normalized(dir - thetaDir * (slope / r))
                points.append(Point(p: p, n: normalized(SIMD3(n.x, n.y / squash, n.z))))
            }
        }
        // the hollow left by the bite: the part of the bite cylinder inside the apple, facing its axis
        for i in 0..<200 {
            let a = 2 * Double.pi * Double(i) / 200, dir = SIMD3(cos(a), sin(a), 0)
            for k in -40...40 {
                let q = SIMD3(biteX, biteY, Double(k) / 40) + dir * biteRadius
                if insideApple(q) { points.append(Point(p: q, n: -dir)) }
            }
        }
        // stem
        for i in 0...24 {
            let t = Double(i) / 24, center = SIMD3(0.1 * t, 0.62 + 0.5 * t, 0)
            for j in 0..<12 {
                let a = 2 * Double.pi * Double(j) / 12, n = SIMD3(cos(a), 0, sin(a))
                points.append(Point(p: center + n * 0.05, n: n))
            }
        }
        // leaf: an ellipse in a tilted plane next to the stem, lit on both sides
        let u = normalized(SIMD3(1, 0.55, 0.15)), v = normalized(SIMD3(-0.1, 0.25, 1))
        let normal = normalized(SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x))
        let leafCenter = SIMD3(0.36, 0.86, 0.0)
        for i in -20...20 {
            for j in -10...10 {
                let s = Double(i) / 20, t = Double(j) / 10
                if s * s + t * t <= 1 { points.append(Point(p: leafCenter + u * (s * 0.3) + v * (t * 0.13), n: normal, twoSided: true)) }
            }
        }
        return points
    }()

    /// One frame as `height` lines of exactly `width` cells, the apple turned by `angle` radians.
    /// Each cell is a Braille character holding 2×4 dots; brightness is dot density (ordered dithering) plus grey.
    public static func frame(angle: Double = 0) -> [String] {
        let dotsX = width * 2, dotsY = height * 4
        let tilt = 0.12, distance = 4.0  // seen almost from the side, camera on -z
        let (sinA, cosA, sinT, cosT) = (sin(angle), cos(angle), sin(tilt), cos(tilt))
        let light = SIMD3<Double>(-0.5, 0.75, -0.65) / 1.1
        var depth = [[Double]](repeating: [Double](repeating: 0, count: dotsX), count: dotsY)
        var shade = [[Double]](repeating: [Double](repeating: -1, count: dotsX), count: dotsY)

        func view(_ v: SIMD3<Double>) -> SIMD3<Double> {
            let x = v.x * cosA + v.z * sinA, z = -v.x * sinA + v.z * cosA
            return SIMD3(x, v.y * cosT - z * sinT, v.y * sinT + z * cosT)
        }
        for point in points {
            let p = view(point.p), n = view(point.n)
            if !point.twoSided && n.z > 0.15 { continue }  // facing away from the camera
            let ooz = 1 / (p.z + distance)
            let x = Int(Double(dotsX) / 2 + 120 * p.x * ooz)
            let y = Int(Double(dotsY) / 2 - 128 * (p.y - 0.06) * ooz)
            guard (0..<dotsX).contains(x), (0..<dotsY).contains(y), ooz > depth[y][x] else { continue }
            depth[y][x] = ooz
            let lit = (n * light).sum()
            shade[y][x] = max(0.22, point.twoSided ? abs(lit) : lit)  // the dark side stays faintly dotted
        }

        let bayer: [[Double]] = [[0, 4], [6, 2], [1, 5], [7, 3]].map { $0.map { ($0 + 0.5) / 8 } }
        let bits: [[UInt32]] = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]]
        return (0..<height).map { row in
            (0..<width).map { col in
                var mask: UInt32 = 0, total = 0.0, count = 0
                for dy in 0..<4 {
                    for dx in 0..<2 {
                        let b = shade[row * 4 + dy][col * 2 + dx]
                        if b > bayer[dy][dx] { mask |= bits[dy][dx]; total += b; count += 1 }
                    }
                }
                guard count > 0 else { return " " }
                let grey = 238 + Int(total / Double(count) * 17)  // 256-color grey ramp
                return "\u{1B}[38;5;\(grey)m\(Character(UnicodeScalar(0x2800 + mask)!))\u{1B}[0m"
            }.joined()
        }
    }
}
