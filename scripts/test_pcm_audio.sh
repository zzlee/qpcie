#!/bin/bash

# Script to test PCM audio capture from QPCIe device
# This verifies that the new format conversion is working properly

echo "Testing PCM capture from QPCIe device..."

# Ensure we have access to required tools
if ! command -v arecord &> /dev/null; then
    echo "arecord not found - please install alsa-utils"
    exit 1
fi

# Get a list of available audio devices
echo "--- Available Audio Devices ---"
arecord -l

# Check for our QPCIe device specifically
echo ""
echo "--- Checking for QPCIe Audio Devices ---"
for card_info in $(cat /proc/asound/cards); do
    if [[ "$card_info" =~ "QPCIe" ]] || [[ "$card_info" =~ "qpcie" ]]; then
        echo "Found QPCIe audio device: $card_info"
    fi
done

# Attempt actual capture with short duration to check format compatibility 
echo ""
echo "--- Testing PCM capture (5 seconds) ---"
arecord -D hw:QPCIeAudio0,0 -f S32_LE -r 48000 -d 5 test_pcm_capture.wav

if [ $? -eq 0 ]; then
    echo "✓ PCM capture successful!"
    
    # Play back to validate the content (optional)
    # aplay test_pcm_capture.wav
    
else
    echo "✗ PCM capture failed."
    exit 1
fi

echo ""
echo "--- Capture Test Complete ---"