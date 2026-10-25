# Hyperlapse/Match cut

App Mac gratuite et open source pour les monteurs et photographes, avec deux outils :

- **Hyperlapse** : un point (et des lignes pour garder l'horizon droit) posé sur la première photo est suivi sur toute la
  série, qui est alignée dessus.
- **Match cut** : un logo, une forme ou un texte photographié dans des lieux différents est retrouvé sur chaque photo
  et placé exactement au même endroit, à la même taille (ou en zoom progressif).

Une photo = une image de la vidéo. Export ProRes, H.264, HEVC, séquences TIFF ou JPEG. RAW, JPG, HEIC, TIFF, PNG.

## Installer

**L'app toute prête** (Mac à puce Apple, macOS 14 ou plus) : télécharger `Hyperlapse-Match-cut.zip` dans la page
[Releases](../../releases), décompresser, glisser l'app dans Applications.
L'app n'est pas notarisée par Apple : au premier lancement, **clic droit sur l'app > Ouvrir > Ouvrir**
(ou Réglages Système > Confidentialité et sécurité > « Ouvrir quand même »). Une seule fois suffit.

**Mises à jour automatiques** (à partir de la 1.1) : l'app vérifie au lancement puis toutes les 6 h s'il y a une nouvelle
version sur GitHub, la télécharge, vérifie qu'elle est signée par le même développeur, prévient (bandeau en haut et
notification) et s'installe à la fermeture de l'app, ou tout de suite avec « Redémarrer ». Menu de l'app :
« Rechercher les mises à jour… » et « Mises à jour automatiques ». Une copie compilée depuis le code n'est jamais
remplacée : elle signale seulement la nouvelle version (`git pull` puis `./Tools/build.sh`).

**Depuis le code** (pour le modifier) :
```sh
xcode-select --install        # outils de développement Apple, une seule fois (pas besoin de Xcode complet)
git clone <ce dépôt> && cd <ce dépôt>
./Tools/build.sh              # compile et installe l'app dans /Applications
./Tools/selftest.sh           # optionnel : vérifie le suivi, l'alignement et l'export sur une fausse série
```
Sans certificat Apple Developer, l'app est signée localement (« ad hoc ») : elle marche sur le Mac qui l'a compilée.

Corrections et idées bienvenues : ouvre une *issue* ou une *pull request*. Licence MIT (voir `LICENSE`).
La police Geist (`Resources/Fonts`) est sous licence SIL Open Font License (`Resources/Fonts/OFL.txt`).

## Utilisation

1. Glisser les photos (RAW, JPG, HEIC, TIFF, PNG) ou un dossier. Rangées par nom de fichier.
2. Vue **Placer** : poser le repère sur la première photo (loupe ×4 pendant le placement).
3. **Suivre à partir de cette photo** (⌘T) : le repère est retrouvé sur les suivantes.
   Le suivi s'arrête s'il perd le repère. Le replacer à la main et relancer.
   Pour un match cut (scènes différentes), activer **Clic = photo suivante** et cliquer photo après photo.
4. Vue **Aligné** : contrôle avec la pelure d'oignon, **Lecture** (espace) pour voir l'hyperlapse.
5. **Zoom auto** retire les bords noirs, puis **Exporter** (⌘E) : ProRes 422 HQ / 4444, H.264, HEVC, séquence TIFF 16 bits ou JPEG.

- **Zoom dans la photo** : pincement ou molette (autour du pointeur), deux doigts pour se déplacer, ⌘+ / ⌘− / ⌘0.
  **⌥ + flèches** déplace le repère d'un pixel (⇧⌥ : 10 pixels).
- **Photo masquée ou incertaine** (quelqu'un passe devant, deux endroits qui se ressemblent) : le suivi saute la photo,
  retrouve le repère jusqu'à 3 photos plus loin, puis cherche la photo sautée autour de la position estimée entre
  l'image d'avant et celle d'après. Vu nettement : position réelle. Toujours masqué : position estimée, en rouge.
  Le suivi privilégie la position précédente dans le cadre (en hyperlapse, le sujet reste au même endroit).
- **Orientation** (repère Point) : le point tient la position, des lignes tiennent la rotation. La photo tourne autour du point.
  - Horizontale, Verticale, ou **Symétrie** (deux lignes qui penchent en miroir, comme les bords d'une porte vue d'en bas :
    leur axe reste droit, la perspective s'annule). Une ligne tracée s'aimante au bord droit le plus proche.
  - **⇧⌘T** suit les lignes : le bord droit est recherché autour de la position prédite par le point (même contraste,
    6° maximum d'une photo à l'autre), avec repli sur le suivi par motifs s'il n'y a pas de bord.
  - Une ligne tracée à la main est une **image clé** (losange orange) : le suivi repart d'elle. Mode « Clés seulement » :
    rotation interpolée entre les lignes tracées à la main.
  - **Clés de rotation à la main** : avec Point choisi, ⌥[ / ⌥] ou les boutons ±0,1° / ±1° tournent la photo autour du point
    et posent une clé, interpolée jusqu'à la suivante, ajoutée à la rotation des lignes.
  - En tournant autour d'un sujet, une horizontale penche avec la perspective : préférer une verticale ou une symétrie.
- **Bords** (Cadrage de sortie, dans les deux outils) : **Noir** (le zoom auto cache les bandes) ou **Motion Tile** (la photo
  alignée est répétée tout autour, comme l'effet d'After Effects), avec **Miroir** pour retourner chaque copie et
  rendre les raccords invisibles. Aperçu, lecture et export suivent le réglage.
- **⌘Z / ⇧⌘Z** annulent et rétablissent : placement, effacement, référence, changement de mode, et un suivi entier d'un coup.
- **Point, Règle et Cadre gardent chacun leurs repères** : passer de l'un à l'autre ne supprime rien.
- Piste de fiabilité sous la pellicule : orange = à la main, gris = suivi (hauteur = fiabilité), rouge = à vérifier.
- La session est enregistrée automatiquement (`~/Library/Application Support/Hyperlapse/session.json`).

## Match cut

Sélecteur **Hyperlapse / Match cut** en haut à gauche (⌃⌘1 / ⌃⌘2). Chaque outil a ses photos, son ⌘Z et sa session
(`matchcut.json` à côté de `session.json`) : le match cut ne touche jamais à l'hyperlapse.

1. Importer les photos (logo, forme, objet, texte photographié dans des lieux différents).
2. Glisser en diagonale autour de l'élément sur la photo où il est le plus net : ce cadre devient la référence.
3. **Trouver l'élément partout** (⌘T) : recherche sur toute la photo à toutes les tailles (5 à 95 %) et inclinaisons
   (±24°), puis ajustement des 4 coins au pixel. Les photos sont comparées par leurs contours, pas leurs couleurs
   (un logo rouge sur une voiture grise, verte ou bleue a les mêmes contours). La recherche part aussi de la place de
   l'élément sur la référence et sur les photos déjà faites, à plusieurs tailles.
4. Une photo ratée ou en rouge : tracer un cadre grossier autour de l'élément, il s'ajuste seul (⌘Z revient avant le tracé).
   Un coin déplacé à la main reste où il est mis. Toute correction fait passer la photo en orange (placée à la main) et
   la recherche n'y touche plus. Cadre rouge déjà juste : « Le cadre est bon, valider » (↩). On peut corriger pendant
   que la recherche tourne.
5. Vue Aligné, puis export. **Durée de chaque photo** (fenêtre d'export) : 1, 2 ou 3 images de la vidéo par photo
   (chaque photo est calculée une fois puis répétée ; en séquence, le fichier est dupliqué). La lecture suit ce réglage. « Redresser la perspective » fait tomber les 4 coins exactement sur ceux de la référence.

6. **Rangement automatique** (activé par défaut) : après ⌘T, l'app mesure l'élément sur chaque photo et les range du plus
   petit au plus gros ; les photos où il n'est pas trouvé vont à la fin. Pour imposer ton ordre : « Ordre » dans
   Cette photo (Première, ←, →, Dernière, ou ⌥⌘← / ⌥⌘→). Déplacer une photo à la main coupe le rangement automatique.
   Rien de tout ça n'existe dans l'outil Hyperlapse, dont l'ordre ne change jamais.
7. **Ranger** (Petit → gros / Gros → petit) : met les photos dans l'ordre de la taille de l'élément dans la photo
   d'origine (⌘Z rend l'ordre d'avant). **Taille de l'élément** : Identique (le décor zoome autour d'un élément fixe)
   ou **Zoom progressif** (l'élément passe en douceur de sa taille sur la première photo à celle de la dernière, même
   croissance à chaque image, toujours au même endroit).

Testé sur une série de 14 photos d'un même logo (bâches, remorque, carrosseries de couleurs différentes) : 12 photos
placées seules, 13 justes sur 14, la dernière (gros reflet sur le logo) rattrapée par un cadre grossier. Environ 2 s par photo.

## Développement

- `./Tools/release.sh "notes"` : publie la version écrite dans `VERSION` sur GitHub (les apps installées la récupèrent seules).
- `./Tools/build.sh` : compile et installe `/Applications/HYPERLAPSE.app` (sans projet Xcode).
- `./Tools/selftest.sh` : faux hyperlapse de 30 photos 6000×4000 au mouvement connu ; mesure suivi, alignement, export.
- `./Tools/undotest.sh` : vérifie ⌘Z et la conservation des repères par mode (après `selftest.sh`).
- `HYPERLAPSE_SESSION=<fichier>` : fait travailler l'app sur une autre session (tests, captures).
- Design : `DESIGN.md` et `Sources/Theme.swift`. Produit : `PRODUCT.md`.

Points techniques :
- Aperçu, suivi et export passent par le même décodeur ImageIO. Pour les RAW, décodage pleine taille puis
  réduction (le décodage réduit d'ImageIO prend des minutes sur un ARW Sony).
- Suivi : prédiction Vision (translation) + vitesse de la caméra, corrélation grossière puis fine au sous-pixel,
  contre la photo précédente et contre la dernière photo placée à la main (évite la dérive).
- Rendu Core Image identique pour l'aperçu et l'export.
