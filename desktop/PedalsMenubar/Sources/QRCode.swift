import AppKit
import CoreImage

enum QRCode {
    /// Renders `string` as a crisp (nearest-neighbor upscaled) QR code image.
    static func image(for string: String, sidePixels: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = sidePixels / output.extent.width
        let scaled = output.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
