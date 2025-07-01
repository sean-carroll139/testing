#!/bin/bash

echo "=== CMOS Battery Voltage Checker ==="
echo

# === Check for lm-sensors ===
if ! command -v sensors >/dev/null 2>&1; then
    echo "?? lm-sensors not found. Installing (requires sudo)..."
    sudo apt-get update && sudo apt-get install -y lm-sensors
else
    echo "? lm-sensors is already installed."
fi

# === Check for bc ===
if ! command -v bc >/dev/null 2>&1; then
    echo "?? bc not found. Installing (requires sudo)..."
    sudo apt-get install -y bc
else
    echo "? bc is already installed."
fi

echo

# === Check if sensor data is already available ===
if ! sensors | grep -qi 'adapter'; then
    echo "?? No sensor data found. Running sensors-detect (requires sudo)..."
    yes | sudo sensors-detect > /dev/null
    echo "?? Reloading kernel modules..."
    sudo systemctl restart kmod
    sleep 2
else
    echo "? Sensor data is already available."
fi

echo
echo "?? Scanning for CMOS battery voltage..."
echo

# === Capture relevant voltage lines ===
VOLTAGE_LINES=$(sensors | grep -iE 'cmos|vbatt|vbat|voltage')
echo "$VOLTAGE_LINES"

# === Extract and check voltages ===
LOW_VOLTAGE=false
while read -r line; do
    VOLT=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+(?= V)')
    if [[ -n "$VOLT" ]]; then
        COMP=$(echo "$VOLT < 3.0" | bc -l)
        if [[ "$COMP" -eq 1 ]]; then
            LOW_VOLTAGE=true
        fi
    fi
done <<< "$VOLTAGE_LINES"

if $LOW_VOLTAGE; then
    echo
    echo "?? WARNING: One or more voltage readings are below 3.0V!"
    echo "Your CMOS battery may be weak or near failure."
fi
