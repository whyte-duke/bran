import AVKit
import SwiftUI

/// Lecteur vidéo.
///
/// **Il vérifie d'abord que le fichier est là.** Un `AVPlayer` sur une URL
/// absente ne proteste pas : il affiche un rectangle noir muet, avec des
/// contrôles qui ne répondent pas. C'est le cas d'une session encore en
/// compression, d'un fichier supprimé dans le Finder ou d'un dossier
/// débranché — trois situations fréquentes, aucune évidente à l'écran.
struct PlayerView: View {
    let url: URL

    var body: some View {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            VideoSurface(url: url)
        } else {
            ContentUnavailableView(
                "Vidéo introuvable",
                systemImage: "film.slash",
                description: Text("Le fichier n'est pas à sa place : il est peut-être encore en cours de compression, ou il a été déplacé depuis le Finder.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// `VideoPlayer` (la vue SwiftUI d'AVKit) fait crasher le processus au moment
/// d'instancier ses métadonnées génériques quand le binaire est produit par
/// SwiftPM : `getSuperclassMetadata` échoue dans `_AVKit_SwiftUI`.
///
/// `AVPlayerView` est de toute façon le bon lecteur sur macOS — contrôles
/// natifs, image dans l'image, navigation à la molette — là où `VideoPlayer`
/// n'expose presque rien.
private struct VideoSurface: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard (view.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        view.player = AVPlayer(url: url)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
