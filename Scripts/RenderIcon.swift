import AppKit
import CoreGraphics
import Foundation

// Rend l'icône de bran à chaque taille, en la DESSINANT à cette taille plutôt
// qu'en réduisant une grande image. C'est le défaut que Scripts/make-icon.sh
// documente lui-même : « une icône dont les petites tailles sont de simples
// réductions est floue à 16 px ».
//
// Deux simplifications par palier :
//   ≥ 128 px  l'œil ambre, le reflet du bec, le dégradé complet
//   ≥  32 px  l'œil sombre sans l'ambre, dégradé simplifié
//   <  32 px  la silhouette seule, aucun détail interne

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// La grille d'icône de macOS depuis Big Sur : sur une toile de 1024, la forme
/// occupe 824 points centrés, avec un rayon de 185,4. Respecter ce gabarit est
/// ce qui fait qu'une icône s'aligne avec ses voisines dans le Dock au lieu de
/// paraître plus grosse ou plus petite qu'elles.
let shapeRatio: CGFloat = 824.0 / 1024.0
let radiusRatio: CGFloat = 185.4 / 824.0

/// Le corbeau, tracé dans un carré de 100 × 100 posé sur la forme.
///
/// Tête de profil tournée vers la droite, bec marqué. Le bec est ce qui rend un
/// oiseau reconnaissable à seize pixels : une tête ronde sans bec devient un
/// point, une tête avec bec reste un oiseau.
func ravenPath(in box: CGRect) -> CGPath {
    let s = box.width / 100
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + x * s, y: box.maxY - y * s)
    }

    // **Les tangentes sont continues au sommet du crâne**, et c'est la seule
    // subtilité du tracé. La première version y laissait un cusp : la tangente
    // arrivait en oblique et repartait à l'horizontale, ce qui creusait une
    // encoche nette au point le plus visible de la forme. Les deux points de
    // contrôle qui encadrent le sommet sont donc à la même hauteur que lui.
    let path = CGMutablePath()
    // Sommet du crâne.
    path.move(to: p(46, 10))
    // Crâne vers l'arrière, puis nuque.
    path.addCurve(to: p(14, 46), control1: p(28, 10), control2: p(15, 24))
    // Nuque vers la poitrine.
    path.addCurve(to: p(26, 82), control1: p(13, 62), control2: p(16, 75))
    // Poitrine, base du cou.
    path.addCurve(to: p(57, 72), control1: p(38, 90), control2: p(51, 83))
    // Gorge qui remonte vers la mandibule inférieure.
    path.addCurve(to: p(61, 50), control1: p(61, 66), control2: p(60, 57))
    // Mandibule inférieure vers la pointe. Un angle franc, et il est voulu :
    // c'est la commissure, et c'est elle qui fait lire « bec » plutôt que
    // « museau ».
    path.addLine(to: p(96, 43))
    // Pointe du bec.
    path.addLine(to: p(97, 39))
    // Mandibule supérieure, qui revient vers le front.
    path.addCurve(to: p(63, 28), control1: p(85, 33), control2: p(73, 29))
    // Front, retour au sommet.
    path.addCurve(to: p(46, 10), control1: p(57, 27), control2: p(52, 10))
    path.closeSubpath()
    return path
}

func render(size: Int) -> Data? {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // La forme, sur le gabarit d'Apple.
    let side = dimension * shapeRatio
    let shape = CGRect(
        x: (dimension - side) / 2,
        y: (dimension - side) / 2,
        width: side,
        height: side
    )
    let squircle = CGPath(
        roundedRect: shape,
        cornerWidth: side * radiusRatio,
        cornerHeight: side * radiusRatio,
        transform: nil
    )

    context.saveGState()
    context.addPath(squircle)
    context.clip()

    // Indigo profond. Assez sombre pour que le corbeau pâle ressorte, assez
    // coloré pour ne pas se confondre avec les icônes noires du Dock — c'était
    // tout le défaut de l'icône précédente, noir sur noir.
    let top = CGColor(srgbRed: 0.180, green: 0.204, blue: 0.404, alpha: 1)
    let bottom = CGColor(srgbRed: 0.063, green: 0.071, blue: 0.153, alpha: 1)
    if size >= 32 {
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [top, bottom] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: dimension),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    } else {
        // Sous 32 px un dégradé sur seize pixels ne se voit pas et coûte du
        // contraste. Une teinte pleine, prise au milieu du dégradé.
        context.setFillColor(CGColor(srgbRed: 0.121, green: 0.137, blue: 0.278, alpha: 1))
        context.fill(shape)
    }
    context.restoreGState()

    // Le corbeau. Sa boîte occupe 62 % de la forme, calée légèrement à gauche
    // pour que le bec ne touche pas le bord droit.
    let birdWidth = side * 0.62
    let birdBox = CGRect(
        x: shape.minX + side * 0.17,
        y: shape.minY + side * 0.21,
        width: birdWidth,
        height: birdWidth * 0.94
    )
    let bird = ravenPath(in: birdBox)

    context.saveGState()
    context.addPath(bird)
    context.setFillColor(CGColor(srgbRed: 0.957, green: 0.949, blue: 0.933, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // L'œil. En dessous de 32 px il disparaît : deux pixels sombres au milieu
    // d'une silhouette claire se lisent comme une salissure, pas comme un œil.
    if size >= 32 {
        let s = birdBox.width / 100
        let eye = CGPoint(
            x: birdBox.minX + 50 * s,
            y: birdBox.maxY - 38 * s
        )
        let eyeRadius = birdBox.width * 0.075
        context.setFillColor(CGColor(srgbRed: 0.063, green: 0.071, blue: 0.153, alpha: 1))
        context.fillEllipse(in: CGRect(
            x: eye.x - eyeRadius, y: eye.y - eyeRadius,
            width: eyeRadius * 2, height: eyeRadius * 2
        ))

        // L'ambre, seulement quand il reste assez de pixels pour qu'il soit une
        // couleur et pas un artefact.
        if size >= 128 {
            let irisRadius = eyeRadius * 0.46
            context.setFillColor(CGColor(srgbRed: 0.941, green: 0.659, blue: 0.235, alpha: 1))
            context.fillEllipse(in: CGRect(
                x: eye.x - irisRadius + eyeRadius * 0.16,
                y: eye.y - irisRadius + eyeRadius * 0.16,
                width: irisRadius * 2, height: irisRadius * 2
            ))
        }
    }

    guard let image = context.makeImage() else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: image)
    return bitmap.representation(using: .png, properties: [:])
}

// Les dix paliers réclamés par iconutil.
let plan: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, size) in plan {
    guard let data = render(size: size) else {
        FileHandle.standardError.write("échec du rendu : \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(name).png")
    try! data.write(to: url)
    print("  \(name).png  (\(size)×\(size), \(data.count) octets)")
}
