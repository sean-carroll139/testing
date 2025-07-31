#!/bin/bash

# Requires: smartmontools, sudo/root access

OUTPUT="drive_check_summary_$(hostname)_$(date +%Y%m%d_%H%M%S).csv"
echo "Drive,Device Node,SMART Health,DMESG Errors" > "$OUTPUT"

echo "Scanning for drives..."

# Get a list of block devices that are disks (e.g., /dev/sda)
mapfile -t DRIVES < <(lsblk -dno NAME,TYPE | awk '$2 == "disk" {print "/dev/" $1}')

for DEV in "${DRIVES[@]}"; do
    DRIVE_LABEL=$(udevadm info --query=all --name="$DEV" | grep ID_SERIAL= | cut -d= -f2)
    if [[ -z "$DRIVE_LABEL" ]]; then
        DRIVE_LABEL=$(basename "$DEV")
    fi

    # Check SMART health
    if smartctl -H "$DEV" &>/dev/null; then
        SMART_HEALTH=$(smartctl -H "$DEV" | grep "SMART overall-health" | awk -F: '{gsub(/^[ \t]+/, "", $2); print $2}')
        [[ -z "$SMART_HEALTH" ]] && SMART_HEALTH="UNKNOWN"
    else
        SMART_HEALTH="NOT SUPPORTED"
    fi

    # Check dmesg for errors related to this drive
    DMESG_ERRORS=$(dmesg | grep -iE "$DEV|$(basename "$DEV")" | grep -iE "error|fail|reset|timeout" | wc -l)

    echo "$DRIVE_LABEL,$DEV,$SMART_HEALTH,$DMESG_ERRORS" >> "$OUTPUT"
done

echo -e "\nScan complete. Summary saved to: $OUTPUT"
