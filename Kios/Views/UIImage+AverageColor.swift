import UIKit
import CoreImage

extension UIImage {
    /// Single-pixel average of the entire image via `CIAreaAverage`.
    ///
    /// Used to derive the matte color behind a cover in the gallery so
    /// covers whose native aspect ratio differs from 2:3 still fill the
    /// grid cell without the empty letterbox looking jarring.
    ///
    /// Passing `kCFNull` as the working color space keeps the rendered
    /// bytes in the image's own color space — without it Core Image
    /// re-maps through sRGB twice and the matte drifts.
    func averageColor() -> UIColor? {
        guard let ciImage = CIImage(image: self) else { return nil }
        let extent = ciImage.extent
        let extentVec = CIVector(
            x: extent.origin.x,
            y: extent.origin.y,
            z: extent.size.width,
            w: extent.size.height
        )
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: ciImage,
                kCIInputExtentKey: extentVec,
            ]
        ),
        let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return UIColor(
            red: CGFloat(bitmap[0]) / 255.0,
            green: CGFloat(bitmap[1]) / 255.0,
            blue: CGFloat(bitmap[2]) / 255.0,
            alpha: CGFloat(bitmap[3]) / 255.0
        )
    }
}

extension UIColor {
    /// Linear interpolation in sRGB toward `target`. `amount = 0` returns
    /// self, `1` returns target. Used to mute vivid cover averages toward
    /// the editorial paper background so the gallery doesn't oversaturate.
    func blended(toward target: UIColor, by amount: CGFloat) -> UIColor {
        let t = min(max(amount, 0), 1)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              target.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return self
        }
        return UIColor(
            red: r1 * (1 - t) + r2 * t,
            green: g1 * (1 - t) + g2 * t,
            blue: b1 * (1 - t) + b2 * t,
            alpha: a1 * (1 - t) + a2 * t
        )
    }
}
