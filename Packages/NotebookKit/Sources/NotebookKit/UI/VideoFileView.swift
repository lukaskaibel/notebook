import AVKit
import SwiftUI

/// A video, played by AVKit right in the window as QuickTime Player plays it: fitted to the column on black, with
/// the system's controls over it. It waits at its first frame until you play it, and stops when you go elsewhere. A
/// video AVFoundation can't play (AVI, MKV and the like) goes to Quick Look (see `FileLoadingView`).
struct VideoFileView: View {
    let url: URL

    var body: some View {
        FileLoadingView(url: url, background: FileKind.video.pageBackground, rereads: false) { url -> AVPlayer? in
            guard FileLoading.read(url, { _ in true }) == true else { return nil }
            let asset = AVURLAsset(url: url)
            guard (try? await asset.load(.isPlayable)) == true, (try? await asset.loadTracks(withMediaType: .video))?.isEmpty == false else { return nil }
            return AVPlayer(playerItem: AVPlayerItem(asset: asset))
        } content: { player in
            PlayerView(player: player)
        }
    }
}

#if os(macOS)
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
#else
/// The system's player, as Files and Photos play a video: fitted on black, with its controls.
private struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}
#endif
