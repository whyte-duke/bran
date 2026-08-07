import Foundation
import IOKit.pwr_mgt

/// **Le seul appel système de l'éveil.** Rien à tester ici : tout le résultat
/// vient du gestionnaire d'énergie. Ce qui se décide — quand, combien de temps,
/// ce qu'on affiche — vit dans `BranCore/AwakeSession.swift`, sur des dates.
///
/// ```
///   IOPMAssertionCreateWithName(PreventUserIdleDisplaySleep) ──▶ ID
///                                                                │
///   IOPMAssertionRelease(ID) ◀──────────────────────────────────┘
/// ```
///
/// **Pourquoi `PreventUserIdleDisplaySleep` et pas `PreventUserIdleSystemSleep`.**
/// C'est l'assertion que prend Caffeine, et elle est plus large qu'elle n'en a
/// l'air : empêcher l'écran de s'éteindre par inactivité empêche du même coup la
/// veille système par inactivité et le démarrage de l'économiseur d'écran. La
/// variante « système » laisserait l'écran s'éteindre — ce qui n'est pas ce
/// qu'on demande à une application qui s'appelle « garder le Mac éveillé ».
///
/// **Ce que ça ne fait pas, et bran le dit dans ses réglages** : refermer le
/// capot endort la machine malgré l'assertion. Aucune API publique ne le
/// contredit ; le prétendre serait une promesse que le matériel ne tient pas.
///
/// **Vérifiable de l'extérieur**, et c'est pour ça que l'assertion porte un
/// nom : `pmset -g assertions` liste `PreventUserIdleDisplaySleep` avec la
/// raison ci-dessous et le PID de bran. Une fonction qui prétend tenir le Mac
/// éveillé doit pouvoir être prise en défaut sans la croire sur parole.
@MainActor
final class SleepBlocker {

    /// Ce que `pmset -g assertions` affichera.
    ///
    /// **En ASCII, et c'est mesuré, pas prudent.** La première version disait
    /// « bran — éveil demandé par l'utilisateur ». `pmset` transcode le nom en
    /// **MacRoman** avant de l'écrire : le tiret cadratin en sort en `0xD1` et
    /// le « é » en `0x8E`, soit du charabia dans n'importe quel terminal UTF-8.
    /// C'est la seule chaîne de bran qui traverse un outil système au lieu
    /// d'être affichée par bran, et donc la seule qui n'a pas le droit d'être
    /// écrite en français accentué.
    private static let reason = "bran: keep-awake requested by the user"

    private var assertion: IOPMAssertionID?

    var isEngaged: Bool { assertion != nil }

    /// Prend l'assertion. Rend `false` si le gestionnaire d'énergie refuse — un
    /// échec qui doit remonter jusqu'à l'utilisateur : un interrupteur qui reste
    /// allumé sur une assertion qui n'existe pas est exactement le genre de
    /// mensonge qu'on découvre en retrouvant son Mac endormi.
    @discardableResult
    func engage() -> Bool {
        guard assertion == nil else { return true }

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.reason as CFString,
            &id
        )

        guard result == kIOReturnSuccess else { return false }
        assertion = id
        return true
    }

    /// Rend l'assertion. Idempotent : appelé à l'extinction, à l'expiration et à
    /// la fermeture de l'application, qui peuvent se suivre de près.
    func release() {
        guard let id = assertion else { return }
        IOPMAssertionRelease(id)
        assertion = nil
    }

    deinit {
        // Le système libère les assertions d'un processus qui meurt, mais bran
        // peut vivre longtemps après qu'on a éteint l'éveil : on ne compte pas
        // là-dessus.
        if let id = assertion { IOPMAssertionRelease(id) }
    }
}
