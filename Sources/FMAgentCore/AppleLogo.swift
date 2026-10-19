import Foundation

// A pixel apple drawn with half-block characters (two pixels per terminal cell), which can spin on itself.
public enum AppleLogo {
    static let pixels: [[Character]] = [
        "........LL....",
        ".......LLL....",
        "......LL......",
        "...AAAA.AAAA..",
        "..AAAAAAAAAAA.",
        ".AAAAAAAAAAA..",
        ".AAAAAAAAAA...",
        "AAAAAAAAAA....",
        "AAAAAAAAAA....",
        ".AAAAAAAAAA...",
        ".AAAAAAAAAAAA.",
        "..AAAAAAAAAA..",
        "...AAAA.AAAA..",
        "....AA...AA...",
    ].map(Array.init)
    public static let width = 14
    public static let height = 7  // terminal rows

    /// The bitmap turned by `angle` around its vertical axis: squeezed by cos(angle), mirrored when facing away.
    public static func pixelGrid(angle: Double) -> [[Character]] {
        let center = Double(width - 1) / 2
        var scale = cos(angle)
        if abs(scale) < 0.1 { scale = scale < 0 ? -0.1 : 0.1 }  // edge-on: keep a sliver visible
        return pixels.map { row in
            (0..<width).map { x in
                let source = (center + (Double(x) - center) / scale).rounded()
                return source >= 0 && source < Double(width) ? row[Int(source)] : "."
            }
        }
    }

    /// One frame as `height` lines of exactly `width` cells, colored with 24-bit ANSI codes.
    public static func frame(angle: Double = 0) -> [String] {
        let grid = pixelGrid(angle: angle)
        let shade = cos(angle) < 0 ? 0.7 : 1.0  // the back side is darker, which sells the rotation
        func color(_ pixel: Character, _ y: Int) -> String? {
            let rgb: (Double, Double, Double)
            switch pixel {
            case "L": rgb = (110, 200, 80)
            case "A": let t = Double(y) / 13; rgb = (255 - 65 * t, 85 - 65 * t, 80 - 40 * t)
            default: return nil
            }
            return "\(Int(rgb.0 * shade));\(Int(rgb.1 * shade));\(Int(rgb.2 * shade))"
        }
        return (0..<height).map { row in
            (0..<width).map { x in
                switch (color(grid[2 * row][x], 2 * row), color(grid[2 * row + 1][x], 2 * row + 1)) {
                case (nil, nil): " "
                case let (top?, nil): "\u{1B}[38;2;\(top)m▀\u{1B}[0m"
                case let (nil, bottom?): "\u{1B}[38;2;\(bottom)m▄\u{1B}[0m"
                case let (top?, bottom?): "\u{1B}[38;2;\(top)m\u{1B}[48;2;\(bottom)m▀\u{1B}[0m"
                }
            }.joined()
        }
    }
}
