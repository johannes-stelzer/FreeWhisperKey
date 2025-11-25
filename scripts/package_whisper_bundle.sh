#!/usr/bin/env bash
set -euo pipefail

# Packages the whisper.cpp CLI binary and the selected model into dist/whisper-bundle.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_DIR="$ROOT_DIR/whisper.cpp"
BIN_SRC="$WHISPER_DIR/build/bin/whisper-cli"
MODEL_SRC="$WHISPER_DIR/models/ggml-base.bin"
DEST="$ROOT_DIR/dist/whisper-bundle"

if [[ ! -x "$BIN_SRC" ]]; then
  echo "whisper-cli binary not found at $BIN_SRC. Build whisper.cpp first." >&2
  exit 1
fi

if [[ ! -f "$MODEL_SRC" ]]; then
  echo "Model file not found at $MODEL_SRC. Run the download script first." >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/models"

cp "$BIN_SRC" "$DEST/bin/"
cp "$MODEL_SRC" "$DEST/models/"

cat >"$DEST/README.txt" <<'EOF'
whisper-bundle
===============

Contents copied from whisper.cpp for embedding or redistribution with a macOS helper app.

bin/whisper-cli          - Command-line transcriber built with Metal support.
models/ggml-base.bin     - Default Whisper base model.

Usage example (run from repo root):
  dist/whisper-bundle/bin/whisper-cli \
      -m dist/whisper-bundle/models/ggml-base.bin \
      -f whisper.cpp/samples/jfk.wav -otxt -of /tmp/jfk_bundle

Ensure you comply with the upstream project licenses when redistributing.
EOF

echo "Bundle created at $DEST"
