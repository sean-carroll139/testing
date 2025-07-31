#!/bin/bash

# Requires: smartmontools, sudo/root access

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT="drive_check_summary_$(hostname)_$TIMESTAMP.csv"
TMP_ERROR_LOG="/tmp/dmesg_drive_errors_$TIMESTAMP.log"

# CSV Header
echo "Drive,Device Node,SMART Health,DMESG Error Count" | tee "$OUTPUT"

echo -e "\nScanning drives...\n"

# Find all physical drives
mapfile -t DRIVES < <(lsblk -dno NAME,TYPE | awk '$2 == "disk" {print "/dev/" $1}')

for DEV in "${DRIVES[@]}"; do
    # Get serial number or fallback to device name
    DRIVE_LABEL=$(udevadm info --query=all --name="$DEV" | grep ID_SERIAL= | cut -d= -f2)
    [[ -z "$DRIVE_LABEL" ]] && DRIVE_LABEL=$(basename "$DEV")

    # SMART Health Status
    if smartctl -H "$DEV" &>/dev/null; then
        SMART_HEALTH=$(smartctl -H "$DEV" | grep "SMART overall-health" | awk -F: '{gsub(/^[ \t]+/, "", $2); print $2}')
        [[ -z "$SMART_HEALTH" ]] && SMART_HEALTH="UNKNOWN"
    else
        SMART_HEALTH="NOT SUPPORTED"
    fi

    # Collect dmesg errors for this device
    grep -iE "$DEV|$(basename "$DEV")" /var/log/dmesg 2>/dev/null | \
        grep -iE "error|fail|reset|timeout" > "$TMP_ERROR_LOG"
    if [[ ! -s $TMP_ERROR_LOG ]]; then
        dmesg | grep -iE "$DEV|$(basename "$DEV")" | \
            grep -iE "error|fail|reset|timeout" > "$TMP_ERROR_LOG"
    fi
    DMESG_COUNT=$(wc -l < "$TMP_ERROR_LOG")

    # Print summary line
    SUMMARY_LINE="$DRIVE_LABEL,$DEV,$SMART_HEALTH,$DMESG_COUNT"
    echo "$SUMMARY_LINE" | tee -a "$OUTPUT"

    # If errors found, print them under the summary
    if [[ "$DMESG_COUNT" -gt 0 ]]; then
        echo "---------------" | tee -a "$OUTPUT"
        cat "$TMP_ERROR_LOG" | tee -a "$OUTPUT"
        echo "---------------" | tee -a "$OUTPUT"
    fi

    echo "" | tee -a "$OUTPUT"
done

# Clean up
rm -f "$TMP_ERROR_LOG"

echo "Scan complete. Report saved to: $OUTPUT"
