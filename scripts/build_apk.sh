#!/usr/bin/env bash
#
# NexRadar · tek komutla APK üretimi
#
#   ./scripts/build_apk.sh            # release APK + kök dizine kopyala
#   ./scripts/build_apk.sh --debug    # hızlı debug derlemesi
#
# Script, bu makinede kullanılan yerel toolchain'i otomatik bulur:
#   Flutter  $HOME/toolchains/flutter
#   JDK 17   $HOME/toolchains/jdk-17*
#   SDK      $HOME/toolchains/android-sdk
# Farklı bir konumdaysa FLUTTER_ROOT / JAVA_HOME / ANDROID_HOME env değişkenleri
# ile geçersiz kılabilirsin.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# ------------------------------------------------------------------ toolchain
if [[ -z "${FLUTTER_ROOT:-}" && -x "$HOME/toolchains/flutter/bin/flutter" ]]; then
  export FLUTTER_ROOT="$HOME/toolchains/flutter"
fi

if [[ -z "${JAVA_HOME:-}" ]]; then
  for candidate in "$HOME"/toolchains/jdk-17* /c/Program\ Files/Eclipse\ Adoptium/jdk-17*; do
    if [[ -x "$candidate/bin/java" ]]; then
      export JAVA_HOME="$candidate"
      break
    fi
  done
fi

if [[ -z "${ANDROID_HOME:-}" && -d "$HOME/toolchains/android-sdk" ]]; then
  export ANDROID_HOME="$HOME/toolchains/android-sdk"
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
fi

export PATH="${FLUTTER_ROOT:-}/bin:${JAVA_HOME:-}/bin:${ANDROID_HOME:-}/platform-tools:$PATH"

echo "── toolchain ────────────────────────────────"
echo "flutter : ${FLUTTER_ROOT:-<PATH>}"
echo "java    : ${JAVA_HOME:-<PATH>}"
echo "sdk     : ${ANDROID_HOME:-<PATH>}"
command -v flutter >/dev/null || { echo "flutter tapılmadı" >&2; exit 1; }
command -v java    >/dev/null || { echo "JDK 17 tapılmadı" >&2; exit 1; }

# --------------------------------------------------------------------- quality
echo "── pub get / analyze / test ─────────────────"
flutter pub get
flutter analyze
flutter test

# ----------------------------------------------------------------------- build
MODE="release"
[[ "${1:-}" == "--debug" ]] && MODE="debug"

echo "── build ($MODE) ────────────────────────────"
flutter build apk "--$MODE"

SRC="$PROJECT_ROOT/build/app/outputs/flutter-apk/app-$MODE.apk"
DEST="$PROJECT_ROOT/RadarSpeedometer.apk"
cp "$SRC" "$DEST"

echo
echo "✅ APK hazır"
echo "   kaynak : $SRC"
echo "   teslim : $DEST"
ls -lh "$DEST"
