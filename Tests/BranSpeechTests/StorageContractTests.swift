import Foundation
import Testing
@testable import BranSpeech

@Suite("Raccourcis")
struct HotkeyBindingTests {

    @Test("Command droite et Command gauche sont deux touches distinctes")
    func rightCommandIsNotLeftCommand() {
        #expect(HotkeyBinding.rightCommand.keyCode == 54)
        #expect(HotkeyBinding.rightCommand != HotkeyBinding(keyCode: 55, isModifierOnly: true))
    }

    @Test("Une touche modificatrice seule est signalée comme telle")
    func modifierOnlyIsFlagged() {
        #expect(HotkeyBinding.rightCommand.isModifierOnly)
        #expect(HotkeyBinding.escape.isModifierOnly == false)
    }

    @Test("Aller-retour JSON sans perte")
    func codableRoundTrip() throws {
        let original = HotkeyBinding(keyCode: 100, modifiers: 0x10_0000, isModifierOnly: false)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(HotkeyBinding.self, from: data) == original)
    }

    @Test("Les noms affichés sont lisibles")
    func displayNames() {
        #expect(HotkeyBinding.rightCommand.displayName == "⌘ droite")
        #expect(HotkeyBinding.escape.displayName == "Échap")
        #expect(HotkeyBinding(keyCode: 96, modifiers: 0x10_0000).displayName == "⌘F5")
    }

    /// Accepter Espace comme raccourci rendrait toute saisie de texte
    /// impossible : chaque espace démarrerait une dictée. Mieux vaut refuser
    /// que laisser quelqu'un se verrouiller hors de son clavier.
    @Test("Espace et Entrée seuls sont refusés")
    func refusesKeysThatWouldBreakTyping() {
        #expect(HotkeyBinding(keyCode: 49).isAcceptableAsTrigger == false)
        #expect(HotkeyBinding(keyCode: 36).isAcceptableAsTrigger == false)
    }

    @Test("Ces mêmes touches redeviennent acceptables avec un modificateur")
    func acceptsThemWithAModifier() {
        #expect(HotkeyBinding(keyCode: 49, modifiers: 0x10_0000).isAcceptableAsTrigger)
    }

    @Test("Une touche modificatrice seule est toujours acceptable")
    func modifierAloneIsAlwaysFine() {
        #expect(HotkeyBinding.rightCommand.isAcceptableAsTrigger)
    }
}

@Suite("Contrat du fichier de transcription")
struct TranscriptEntryTests {

    /// La leçon de `RecordingMetadata.segmentCount`, transformée en test.
    ///
    /// Le `Decodable` synthétisé ignore les valeurs par défaut. Le jour où un
    /// champ non optionnel est ajouté à `TranscriptEntry`, toutes les
    /// transcriptions déjà écrites deviennent illisibles d'un coup. Ce test
    /// échoue avant que ça n'arrive.
    @Test("Un fichier écrit par une version antérieure reste lisible")
    func decodesLegacyFileWithOnlyRequiredFields() throws {
        let legacy = """
        {
          "id": "9F2B4C1E-0000-4000-8000-000000000001",
          "createdAt": 771000000,
          "duration": 12.5,
          "text": "bonjour"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entry = try decoder.decode(TranscriptEntry.self, from: Data(legacy.utf8))

        #expect(entry.text == "bonjour")
        #expect(entry.audioFileName == nil)
        #expect(entry.canRetry == false)
    }

    @Test("Réessayer n'est possible que si l'audio existe encore")
    func retryRequiresAudio() {
        let withAudio = TranscriptEntry(createdAt: .now, duration: 3, text: "a", audioFileName: "a.wav")
        let purged = TranscriptEntry(createdAt: .now, duration: 3, text: "a")

        #expect(withAudio.canRetry)
        #expect(purged.canRetry == false)
    }

    @Test("Une entrée en échec affiche sa raison plutôt qu'un blanc")
    func failedEntryShowsReason() {
        let failed = TranscriptEntry(
            createdAt: .now, duration: 3, text: "", failure: "modèle indisponible"
        )
        #expect(failed.isFailed)
        #expect(failed.previewText == "modèle indisponible")
    }

    @Test("Les durées se lisent en français")
    func durationReadsWell() {
        #expect(TranscriptEntry(createdAt: .now, duration: 12, text: "").durationDescription == "12 s")
        #expect(TranscriptEntry(createdAt: .now, duration: 95, text: "").durationDescription == "1 min 35 s")
    }

    @Test("Le compte de mots ignore les espaces multiples")
    func wordCountIgnoresWhitespace() {
        #expect(TranscriptEntry(createdAt: .now, duration: 1, text: "  un   deux \n trois ").wordCount == 3)
    }
}

@Suite("Langue")
struct SpeechLanguageTests {

    @Test("Le français porte le code attendu par FluidAudio")
    func frenchCode() {
        #expect(SpeechLanguage.french.code == "fr")
    }

    @Test("La détection automatique n'impose aucun code")
    func automaticHasNoCode() {
        #expect(SpeechLanguage.automatic.code == nil)
    }

    @Test("Chaque langue proposée porte une étiquette et un code, sauf l'automatique")
    func everyLanguageIsComplete() {
        for language in SpeechLanguage.allCases {
            #expect(language.label.isEmpty == false)
            if language != .automatic { #expect(language.code != nil) }
        }
    }
}
