import Foundation

/// Renders a QR code as ANSI half-block characters, two vertical modules per
/// character row (ARCHITECTURE.md: "render with ANSI half-block characters").
enum QRRenderer {
    /// Dark modules print black, light modules white, with a 2-module quiet zone.
    static func ansi(text: String) throws -> String {
        let qr = try QRCode.encode(text: text, ecl: .medium)
        let quiet = 2
        let size = qr.size + quiet * 2

        func dark(_ x: Int, _ y: Int) -> Bool {
            let mx = x - quiet
            let my = y - quiet
            guard mx >= 0, my >= 0, mx < qr.size, my < qr.size else { return false }
            return qr.getModule(x: mx, y: my)
        }

        var out = ""
        var y = 0
        while y < size {
            for x in 0..<size {
                let top = dark(x, y)
                let bottom = y + 1 < size ? dark(x, y + 1) : false
                // ▀ paints the top half with the foreground color, the bottom
                // half with the background color.
                out += top ? "\u{1b}[30m" : "\u{1b}[37m"
                out += bottom ? "\u{1b}[40m" : "\u{1b}[47m"
                out += "▀"
            }
            out += "\u{1b}[0m\n"
            y += 2
        }
        return out
    }
}
