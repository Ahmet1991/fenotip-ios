#!/usr/bin/env bash
# iPhone derleme aynası: özel depodaki ios/ klasörünü herkese açık Ahmet1991/fenotip-ios deposuna kopyalar ve iter.
# Özel depoda GitHub, Mac derlemesini hesap ödeme sorunu yüzünden başlatmıyor; açık depoda Mac derlemesi ücretsiz.
# Yalnız ios/ ve ios-app.yml gider (şifre/PIN yok; sunucu adresi zaten herkese açık).
# Kullanım (özel deponun bir çalışma kopyasında, commit'ten sonra): bash ios/scripts/ayna-guncelle.sh [ayna-klasörü]
# Derleme: gh run list -R Ahmet1991/fenotip-ios --workflow ios-app.yml --limit 1
set -euo pipefail
src=$(git rev-parse --show-toplevel)
mirror=${1:-D:/GitHub/fenotip-ios-build}
[ -d "$mirror/.git" ] || git clone -q https://github.com/Ahmet1991/fenotip-ios.git "$mirror"
git -C "$mirror" pull -q --rebase origin main 2>/dev/null || true
rm -rf "$mirror/ios" "$mirror/.github"
git -C "$src" archive HEAD ios .github/workflows/ios-app.yml | tar -x -C "$mirror"
cat > "$mirror/README.md" <<'EOF'
# Fenotip iPhone — derleme aynası

Bu depo yalnız derleme içindir: özel depodaki `ios/` klasörünün kopyasıdır, burada elle değişiklik yapılmaz.
Her itişte GitHub Actions imzasız IPA üretir (`Fenotip-ipa` artifact'i); IPA kişinin kendi Apple hesabıyla imzalanıp kurulur.
EOF
sha=$(git -C "$src" rev-parse --short HEAD)
subject=$(git -C "$src" log -1 --format=%s)
cd "$mirror"
git add -A
if git diff --cached --quiet; then
  echo "ayna zaten güncel ($sha)"
  exit 0
fi
git commit -q -m "ayna $sha: $subject"
git push -q origin HEAD:main
echo "ayna güncellendi: $sha -> $(git rev-parse --short HEAD)"
