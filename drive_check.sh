#!/bin/bash

# Requires: smartmontools, sudo/root access

OUTPUT="drive_check_summary_$(hostname)_$(date +%Y%m%d_%H%M%S).csv"
HEADER="Drive,Device Node,SMART Health,DMESG Errors"

echo "$HEADER" | tee "$OUTPUT"

echo "Scanning for drives..."

# Get list of disk devices (e.g., /dev/sda, /dev/nvme0n1)
mapfile -t DRIVES < <(lsblk -dno NAME,TYPE | awk '$2 == "disk" {print "/dev/" $1}')

for DEV in "${DRIVES[@]}"; do
    # Try to get serial number or label
    DRIVE_LABEL=$(udevadm info --query=all --name="$DEV" | grep ID_SERIAL= | cut -d= -f2)
    [[ -z "$DRIVE_LABEL" ]] && DRIVE_LABEL=$(basename "$DEV")

    # SMART health check
    if smartctl -H "$DEV" &>/dev/null; then
        SMART_HEALTH=$(smartctl -H "$DEV" | grep "SMART overall-health" | awk -F: '{gsub(/^[ \t]+/, "", $2); print $2}')
        [[ -z "$SMART_HEALTH" ]] && SMART_HEALTH="UNKNOWN"
    else
        SMART_HEALTH="NOT SUPPORTED"
    fi

    # Count relevant dmesg errors
    DMESG_ERRORS=$(dmesg | grep -iE "$DEV|$(basename "$DEV")" | grep -iE "error|fail|reset|timeout" | wc -l)

    # Compose line and print + save
    LINE="$DRIVE_LABEL,$DEV,$SMART_HEALTH,$DMESG_ERRORS"
    echo "$LINE" | tee -a "$OUTPUT"
done

echo -e "\nScan complete. Summary saved to: $OUTPUT"
