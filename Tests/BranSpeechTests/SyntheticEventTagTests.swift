import Testing
@testable import BranSpeech

/// La marque des événements que bran s'envoie à lui-même.
///
/// Trois lignes de logique, et pourtant le seul endroit du programme où une
/// erreur ne casserait **rien** : une marque à zéro, ou changée d'un seul côté,
/// laisse tout compiler et tout tourner — bran se remet simplement à déclencher
/// ses propres raccourcis sur son propre ⌘V, un collage sur deux, chez
/// quelqu'un d'autre.
@Suite("Marque des événements synthétiques")
struct SyntheticEventTagTests {

    @Test("La marque se reconnaît elle-même")
    func tagRecognisesItself() {
        #expect(SyntheticEventTag.isOurs(SyntheticEventTag.value))
    }

    /// Mesuré : tout ce que bran n'a pas fabriqué porte `0` dans ce champ.
    /// C'est la valeur qu'il ne faut jamais reconnaître, sous peine de devenir
    /// sourd à tout le clavier.
    @Test("Zéro n'est pas la marque")
    func zeroIsNotTheTag() {
        #expect(SyntheticEventTag.isOurs(0) == false)
        #expect(SyntheticEventTag.value != 0)
    }

    @Test("Une valeur voisine n'est pas la marque")
    func neighbouringValuesAreNotTheTag() {
        #expect(SyntheticEventTag.isOurs(SyntheticEventTag.value - 1) == false)
        #expect(SyntheticEventTag.isOurs(SyntheticEventTag.value + 1) == false)
        #expect(SyntheticEventTag.isOurs(-1) == false)
    }

    /// La signature, et le contrat qui va avec : les 32 bits de poids fort sont
    /// « bran » en ASCII et ne bougent pas. Ce test est là pour qu'on ne les
    /// change pas sans le vouloir — les 32 bits de poids faible, eux, sont
    /// disponibles pour une version future de la marque.
    @Test("La signature est « bran »")
    func signatureIsBran() {
        let signature = UInt64(bitPattern: SyntheticEventTag.value) >> 32
        #expect(signature == 0x6272_616E)
        // « bran » relu octet par octet, pour que l'intention soit lisible
        // même par qui ne connaît pas la table ASCII par cœur.
        let rebuilt = "bran".utf8.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        #expect(rebuilt == signature)
    }
}
