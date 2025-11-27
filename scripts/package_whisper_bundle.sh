#!/usr/bin/env bash
set -euo pipefail

# Packages the whisper.cpp CLI binary (and optionally the ggml-base model)
# into dist/whisper-bundle. By default, models are skipped to keep artifacts small.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="$ROOT_DIR/whisper.cpp"
BIN_SRC="$WHISPER_DIR/build/bin/whisper-cli"
MODEL_SRC="$WHISPER_DIR/models/ggml-base.bin"
DEST="$ROOT_DIR/dist/whisper-bundle"
SKIP_MODEL=1

usage() {
  cat <<'EOF'
Usage: scripts/package_whisper_bundle.sh [--include-model]

Creates dist/whisper-bundle containing the whisper.cpp CLI binary. Pass
--include-model to also copy ggml-base.bin into the bundle.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-model)
      SKIP_MODEL=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -x "$BIN_SRC" ]]; then
  echo "whisper-cli binary not found at $BIN_SRC. Build whisper.cpp first." >&2
  exit 1
fi

if [[ $SKIP_MODEL -eq 0 && ! -f "$MODEL_SRC" ]]; then
  echo "Model file not found at $MODEL_SRC. Run whisper.cpp/models/download-ggml-model.sh first." >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/models"

cp "$BIN_SRC" "$DEST/bin/"
cp "$ROOT_DIR/LICENSE" "$DEST/"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$DEST/"

CLI_SHA=$(shasum -a 256 "$DEST/bin/whisper-cli" | awk '{print $1}')

MANIFEST=$(mktemp)
trap 'rm -f "$MANIFEST"' EXIT

cat >"$MANIFEST" <<EOF
{
  "files": {
    "bin/whisper-cli": "$CLI_SHA"
  }
}
EOF

if [[ $SKIP_MODEL -eq 0 ]]; then
  cp "$MODEL_SRC" "$DEST/models/"
  MODEL_SHA=$(shasum -a 256 "$DEST/models/ggml-base.bin" | awk '{print $1}')
  python3 - <<EOF
import json, pathlib
manifest = pathlib.Path("$MANIFEST")
data = json.loads(manifest.read_text())
data["files"]["models/ggml-base.bin"] = "$MODEL_SHA"
manifest.write_text(json.dumps(data, indent=2) + "\n")
EOF
fi

mv "$MANIFEST" "$DEST/manifest.json"
trap - EXIT

cat >"$DEST/README.txt" <<'EOF'
whisper-bundle
===============

Contents copied from whisper.cpp for embedding or redistribution with a macOS helper app.

bin/whisper-cli          - Command-line transcriber built with Metal support.
models/*.bin             - Place Whisper ggml models here (e.g. ggml-medium.en.bin).

Usage example (run from repo root):
  dist/whisper-bundle/bin/whisper-cli \
      -m dist/whisper-bundle/models/ggml-medium.en.bin \
      -f whisper.cpp/samples/jfk.wav -otxt -of /tmp/jfk_bundle

Licensing:
  - LICENSE (BSD 3-Clause) applies to the helper glue in this repository.
  - THIRD_PARTY_NOTICES.md reproduces the MIT licenses for whisper.cpp and OpenAI's Whisper models.
Ensure you ship both files with any redistribution.
EOF

echo "Bundle created at $DEST"
