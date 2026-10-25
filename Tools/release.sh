#!/bin/zsh
# Publishes the version written in VERSION on GitHub: build, zip, tag and release. The apps already installed
# (1.1 and later) find it by themselves, download it and install it at their next quit.
#   ./Tools/release.sh "Ce qui change dans cette version"
set -e
ROOT=${0:A:h:h}
cd "$ROOT"
VERSION=$(cat VERSION)
NOTES=${1:-"Version $VERSION"}
[[ -z $(git status --porcelain) ]] || { echo "Enregistre d'abord les changements (git commit)."; exit 1; }
gh release view "v$VERSION" >/dev/null 2>&1 && { echo "La version $VERSION existe déjà : augmente le numéro dans VERSION."; exit 1; }
./Tools/build.sh noinstall
OUT=$(mktemp -d)
ditto ".build/HYPERLAPSE.app" "$OUT/Hyperlapse:Match cut.app"
(cd "$OUT" && ditto -c -k --keepParent "Hyperlapse:Match cut.app" Hyperlapse-Match-cut.zip)
git push -q
gh release create "v$VERSION" "$OUT/Hyperlapse-Match-cut.zip" --title "Hyperlapse/Match cut $VERSION" --notes "$NOTES

**Déjà installée (1.1 ou plus) :** la mise à jour arrive toute seule et s'installe à la fermeture de l'app.
**Première installation :** télécharger Hyperlapse-Match-cut.zip ci-dessous, décompresser, glisser l'app dans Applications, puis clic droit > Ouvrir la première fois."
echo "Publiée : version $VERSION"
