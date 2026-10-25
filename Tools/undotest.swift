// Checks Cmd-Z and that each anchor kind keeps its own anchors.  ./Tools/undotest.sh
import Foundation

@main
struct UndoTest {
    @MainActor static func main() {
        let p = Project()
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "ÉCHEC", what); if !ok { failures += 1 } }
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let urls = (try! FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }.prefix(5)
        p.importURLs(Array(urls))
        check(p.frames.count == 5, "5 photos importées")

        p.setPoints([CGPoint(x: 0.5, y: 0.5)], at: 0)
        p.setPoints([CGPoint(x: 0.6, y: 0.5)], at: 1)
        check(p.anchoredCount == 2 && p.canUndo, "deux points placés")
        p.undo()
        check(p.anchoredCount == 1 && p.frames[1].points == nil, "⌘Z retire le dernier point")
        p.redo()
        check(p.frames[1].points == [CGPoint(x: 0.6, y: 0.5)], "⇧⌘Z le remet")

        p.settings.kind = .line
        check(p.anchoredCount == 0, "en mode règle, pas de point affiché")
        p.setPoints([CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.25)], at: 0)
        p.settings.kind = .frame
        p.settings.kind = .point
        check(p.anchoredCount == 2 && p.frames[0].points == [CGPoint(x: 0.5, y: 0.5)], "retour en point : les points sont toujours là")
        p.settings.kind = .line
        check(p.frames[0].points?.count == 2, "retour en règle : la règle est toujours là")

        p.undo()  // back to point
        check(p.settings.kind == .point && p.anchoredCount == 2, "⌘Z annule le changement de mode")
        p.clearPoints(after: 0)
        check(p.anchoredCount == 1, "effacer la suite")
        p.undo()
        check(p.anchoredCount == 2, "⌘Z annule l'effacement")
        p.makeReference()  // already the reference: no-op
        p.current = 1
        p.makeReference()
        check(p.refIndex == 1, "référence déplacée")
        p.undo()
        check(p.refIndex == 0, "⌘Z remet la référence")

        // Lines for the orientation: keyframes, undo, kept across kinds, rotation from them.
        p.settings.kind = .point
        p.current = 0
        p.editTarget = .horizontal
        let tilted = [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 1.2, y: 0.5 + tan(2 * .pi / 180))]  // 2° down to the right
        p.setPoints(tilted, at: 0)
        check(p.frames[0].guide(.horizontal)?.status == .manual && p.isRotationKey(0), "ligne horizontale posée = image clé")
        check(p.frames[0].points == [CGPoint(x: 0.5, y: 0.5)], "le point n'a pas bougé")
        check(abs(p.rotations[0] * 180 / .pi + 2) < 1e-6 && abs(p.rotations[4] * 180 / .pi + 2) < 1e-6,
              "rotation de -2° sur la photo, tenue jusqu'à la dernière")
        p.current = 4
        p.setPoints([CGPoint(x: 0.2, y: 0.5), CGPoint(x: 1.2, y: 0.5)], at: 4)
        check(abs(p.rotations[2] * 180 / .pi + 1) < 0.01, "entre deux images clés, la rotation est interpolée (-1° au milieu)")
        p.undo()
        check(p.frames[4].guide(.horizontal) == nil, "⌘Z retire la ligne")
        p.settings.kind = .line
        check(p.rotations.allSatisfy { $0 == 0 } && p.editTarget == .anchor, "en mode règle, les lignes ne tournent rien")
        p.settings.kind = .point
        check(p.frames[0].guide(.horizontal) != nil && p.rotations[0] != 0, "retour en point : la ligne est toujours là")
        p.settings.rotation = .off
        check(p.rotations.allSatisfy { $0 == 0 }, "rotation désactivée")
        p.settings.rotation = .follow
        p.editTarget = .horizontal
        p.current = 0
        p.rotateGuide(by: 0.5)
        check(abs(p.rotations[0] * 180 / .pi + 2.5) < 1e-6, "⌥] tourne la ligne de 0,5°, la photo suit")
        // Symmetric lines: +3° and -3° around the vertical axis cancel, only their common lean is corrected.
        p.clearPoints(after: -1)
        p.editTarget = .horizontal; p.clearPoints(at: 0)
        p.editTarget = .mirrorA
        p.setPoints([CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.3 + tan(3 * .pi / 180) * 0.6, y: 0.8)], at: 0)
        p.editTarget = .mirrorB
        p.setPoints([CGPoint(x: 1.0, y: 0.2), CGPoint(x: 1.0 - tan(3 * .pi / 180) * 0.6, y: 0.8)], at: 0)
        check(abs(p.rotations[0]) < 1e-9, "deux lignes symétriques : pas de rotation, la perspective s'annule")
        // Rotation keyframes by hand around the point.
        p.editTarget = .anchor
        p.current = 0
        p.setRotationKey(0)
        p.current = 4
        p.rotateGuide(by: 2)
        check(abs(p.rotations[4] * 180 / .pi - 2) < 1e-6 && abs(p.rotations[2] * 180 / .pi - 1) < 1e-6,
              "clés de rotation à la main : 0° puis 2°, 1° au milieu")
        p.undo()
        check(p.frames[4].rotationKey == nil, "⌘Z retire la clé de rotation")
        p.clearPoints(at: 0)
        check(p.frames[0].guide(.mirrorA) != nil, "effacer le point ne touche pas à la ligne")
        // A missed photo taken out of the series, then put back.
        let ids = p.frames.map(\.id), refID = p.frames[p.refIndex].id
        p.current = 2
        p.removeCurrentPhoto()
        check(p.frames.count == 4 && !p.frames.contains { $0.id == ids[2] } && p.current == 2, "retirer la photo 3")
        check(p.frames[p.refIndex].id == refID, "la référence reste la même photo")
        p.current = p.refIndex
        p.removeCurrentPhoto()
        check(p.frames.count == 3 && p.frames.indices.contains(p.refIndex), "retirer la référence : une autre la remplace")
        p.undo(); p.undo()
        check(p.frames.map(\.id) == ids && p.frames[p.refIndex].id == refID, "⌘Z remet les photos à leur place, avec la référence")
        p.redo()
        check(p.frames.count == 4 && !p.frames.contains { $0.id == ids[2] }, "⇧⌘Z la retire à nouveau")
        p.undo()
        exit(failures == 0 ? 0 : 1)
    }
}
