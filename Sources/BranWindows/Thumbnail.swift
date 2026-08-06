import CoreGraphics
import Foundation

/// Une fenêtre réduite en niveaux de gris. Rien d'autre n'est conservé de
/// l'image : ni couleur, ni texte, ni résolution utile à un humain. C'est ce qui
/// permet de dire honnêtement que le veilleur ne lit pas vos écrans — il ne
/// garde jamais qu'une liste de moyennes de blocs.
///
/// Le tracé Core Graphics est ici ; l'arithmétique qui en tire un verdict est
/// dans `MotionMeasure`, côté logique pure, où elle se teste sans image.
public struct Thumbnail: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = context.data else { return nil }

        let buffer = raw.bindMemory(to: UInt8.self, capacity: width * height)
        self.width = width
        self.height = height
        self.pixels = Array(UnsafeBufferPointer(start: buffer, count: width * height))
    }
}
