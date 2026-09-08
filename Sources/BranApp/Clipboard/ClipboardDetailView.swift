import BranCore
import SwiftUI

/// Une surface de lecture pour le contenu complet d'une entrée du
/// presse-papiers. La liste reste compacte ; le clic ouvre ce qui demande de la
/// place au lieu de transformer une ligne de 34 points en document.
struct ClipboardDetailView: View {
    let entry: ClipboardEntry
    let store: ClipboardStore
    let thumbnails: ThumbnailCache
    let onCopy: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var image: Image?
    @State private var didFinishLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.small) {
                Label(title, systemImage: ClipboardPanelVocabulary.symbolName(entry))
                    .font(Type.sheetTitle)

                Spacer()

                Button("Copier", systemImage: "doc.on.doc", action: onCopy)
                    .disabled(entry.canPaste == false)
                Button("Fermer", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Space.gutter)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 440)
        .task(id: entry.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let text {
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.gutter)
            }
        } else if let image {
            ScrollView([.horizontal, .vertical]) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 960, maxHeight: 720)
                    .padding(Space.gutter)
                    .accessibilityLabel("Image copiée")
            }
        } else if didFinishLoading {
            ContentUnavailableView(
                "Contenu indisponible",
                systemImage: "clock.badge.xmark",
                description: Text("Le contenu lourd a été purgé ou le fichier n'est plus lisible.")
            )
        } else {
            ProgressView("Ouverture…")
        }
    }

    private var title: String {
        switch entry.kind {
        case .text, .richText: "Texte du presse-papiers"
        case .image: "Image du presse-papiers"
        case .file: "Fichier du presse-papiers"
        }
    }

    private func load() async {
        switch entry.kind {
        case .text, .richText:
            if let inline = entry.plainText {
                text = inline
            } else if let reference = entry.blobs?.first(where: { $0.ext == "txt" }),
                      let url = store.blobURL(for: reference, of: entry) {
                text = await Self.readText(at: url)
            }

        case .image, .file:
            if let rendered = await thumbnails.thumbnail(for: entry, size: .detail) {
                image = Image(rendered, scale: 1, label: Text("Image copiée"))
            }
        }
        didFinishLoading = true
    }

    private nonisolated static func readText(at url: URL) async -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}
