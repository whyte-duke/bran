import AVKit
import SwiftUI

/// Lecteur vidéo.
///
/// `VideoPlayer` (la vue SwiftUI d'AVKit) fait crasher le processus au moment
/// d'instancier ses métadonnées génériques quand le binaire est produit par
/// SwiftPM : `getSuperclassMetadata` échoue dans `_AVKit_SwiftUI`.
///
/// `AVPlayerView` est de toute façon le bon lecteur sur macOS — contrôles
/// natifs, image dans l'image, navigation à la molette — là où `VideoPlayer`
/// n'expose presque rien.
struct PlayerView: NSViewRepresentable {
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
