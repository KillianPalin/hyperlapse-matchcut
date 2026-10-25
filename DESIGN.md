# HYPERLAPSE · design

Style : **achromatic ledger** (taste, app style, seed 1827753565), passé en sombre parce qu'on juge des photos sur un entourage gris neutre. Jetons dans `Sources/Theme.swift`.

## Couleur
- L'interface n'a aucune teinte : fond `#111111`, panneaux `#181818`, puits photo `#0B0B0B`, contrôles `#242424`, bord `#272727`, texte `#EDEDED`, secondaire `#929292`.
- La couleur est réservée aux données : **orange signal `#FF7A1A`** pour le repère et ce qui est placé à la main, **rouge `#FF5A4E`** pour ce qui est à vérifier, **gris encre `#A6A6A6`** pour ce que le suivi a trouvé. La cible de référence est en blanc.
- Action principale : bouton presque blanc à texte noir (Exporter). Secondaire : gris `#242424`. Pas de couleur de marque dans le chrome.

## Type
- Geist (embarquée, licence OFL dans `Resources/Fonts`). 13 px pour le texte, 12 px pour les notes, 13/600 pour les titres de section, 26/600 pour l'écran vide, 28/600 pour le compteur de photos alignées.
- Chiffres en tabulaires. Casse de phrase partout, sauf le mot-symbole HYPERLAPSE.

## Structure
- Barre de 52 px dessinée par l'app (feux tricolores centrés) : marque, nom de la série, pastilles d'état, puis à droite Placer/Aligné, ↶ ↷, lecture, Importer, Exporter.
- Trois panneaux à 12 px du bord et entre eux, rayon 8, bord 1 px, sans ombre : photo, pellicule, inspecteur (300 px).
- Inspecteur en sections séparées par un filet, bouton Exporter épinglé en bas.

## Élément propre au produit
- **La piste de fiabilité** sous la pellicule : une barre par photo, dont la hauteur est la fiabilité du suivi et la couleur l'état. On voit d'un coup d'œil où le suivi a tenu et où il a glissé.

## Interdits
- Pas de dégradé, de verre, de lueur, d'ombre au repos (seule la notification flottante en a une), d'emoji, de petites capitales espacées, de couleur décorative.
