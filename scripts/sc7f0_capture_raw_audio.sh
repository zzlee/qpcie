#!/bin/bash

set -e

# SC7F0 Raw Audio Capture Script
# This script captures raw AES3 subframe PCM from the HDMI audio source,
# and saves it to a binary file for further analysis.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="/home/zzlee/qpcie/build/audio_capture"
ALSA_TEST_APP="$SCRIPT_DIR/../test_app/alsa_test_app"

# Create output directory if needed
mkdir -p "$OUTPUT_DIR"

# Compile the audio test if not exists
if [ ! -x "$ALSA_TEST_APP" ]; then
  echo "Compiling ALSA test app..."
  cd "$SCRIPT_DIR/../test_app"
  make alsa_test_app
fi

# Start capture using TPG pattern to generate distinguishable left/right
echo "[INFO] Capturing 5 seconds of HDMI audio via PCIe (TPG Stereo Pattern)..."
"$ALSA_TEST_APP" --pattern 0 --seconds 5 --out "$OUTPUT_DIR/hdmi_audio_raw_05sec.pcm"

# Also test a few more seconds for good measure
echo "[INFO] Capturing additional 2 seconds of HDMI audio..."
"$ALSA_TEST_APP" --pattern 4 --seconds 2 --out "$OUTPUT_DIR/hdmi_audio_silence_02sec.pcm"
echo "[INFO] Raw audio capture completed."

# Show sample preview of first 10 samples
echo "[SAMPLES PREVIEW]"
xxd -g 4 -l 40 "$OUTPUT_DIR/hdmi_audio_raw_05sec.pcm" | head -5