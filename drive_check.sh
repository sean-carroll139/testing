#!/bin/bash

# Description: Drive health check script with SMART and dmesg parsing.
# Output: CSV + human-readable terminal summary.
# Usage: Run as root.

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname)
OUTPUT="drive_check_summary_${HOSTNAME}_$TIMESTAMP.csv"
TMP_ERROR_LOG="/tmp/dmesg_drive_errors_$TIMESTAMP.log"

echo "Drive,Device Node,SMART Health,DMESG Error Count" | tee "$OUTPUT"
echo -e "\nScanning drives...\n"

# Get all /dev/sdX devices
mapfile -t DRIVES < <(lsblk -dno NAME,TYPE | awk '$2 == "disk" {print "/dev/" $1}')

for DEV in "${DRIVES[@]}"; do
    ###############################
    # Robust Serial Number Detection
    ###############################
    DRIVE_LABEL=""
    SERIAL_OUT=""
    MODES=("" "sat" "scsi" "ata" "auto")

    for MODE in "${MODES[@]}"; do
        if [[ -z "$SERIAL_OUT" ]]; then
            if [[ -z "$MODE" ]]; then
                SERIAL_OUT=$(smartctl -i "$DEV" 2>/dev/null)
            else
                SERIAL_OUT=$(smartctl -i -d "$MODE" "$DEV" 2>/dev/null)
            fi
        fi

        # Exit early if serial found
        if echo "$SERIAL_OUT" | grep -iqE 'serial|s/n'; then
            break
        fi
    done

    # Try to extract serial number
    DRIVE_LABEL=$(echo "$SERIAL_OUT" | awk -F: '
    /[Ss]erial[ _]*[Nn]umber|S\/N/ {
        gsub(/^[ \t]+/, "", $2)
        gsub(/[ \t\r\n]+$/, "", $2)
        print $2
        exit
    }')

    # Fallback to WWN if no serial
    if [[ -z "$DRIVE_LABEL" ]]; then
        DRIVE_LABEL=$(echo "$SERIAL_OUT" | awk -F: '
        /LU WWN Device Id/ {
            gsub(/^[ \t]+/, "", $2)
            gsub(/[ \t]+/, "", $2)
            print $2
            exit
        }')
    fi

    # Final fallback: device name
    [[ -z "$DRIVE_LABEL" ]] && DRIVE_LABEL=$(basename "$DEV")

    ###############################
    # SMART Health Status
    ###############################
    if smartctl -H "$DEV" &>/dev/null; then
        SMART_HEALTH=$(smartctl -H "$DEV" | grep -i "SMART overall-health" | awk -F: '{gsub(/^[ \t]+/, "", $2); print $2}')
        [[ -z "$SMART_HEALTH" ]] && SMART_HEALTH="UNKNOWN"
    else
        SMART_HEALTH="NOT SUPPORTED"
    fi

    ###############################
    # DMESG Error Detection
    ###############################
    grep -iE "$DEV|$(basename "$DEV")" /var/log/dmesg 2>/dev/null | \
        grep -iE "error|fail|reset|timeout" > "$TMP_ERROR_LOG"

    if [[ ! -s "$TMP_ERROR_LOG" ]]; then
        dmesg | grep -iE "$DEV|$(basename "$DEV")" | \
            grep -iE "error|fail|reset|timeout" > "$TMP_ERROR_LOG"
    fi

    DMESG_COUNT=$(wc -l < "$TMP_ERROR_LOG")

    ###############################
    # Output Summary + Errors
    ###############################
    SUMMARY_LINE="$DRIVE_LABEL,$DEV,$SMART_HEALTH,$DMESG_COUNT"
    echo "$SUMMARY_LINE" | tee -a "$OUTPUT"

    if [[ "$DMESG_COUNT" -gt 0 ]]; then
        echo "---------------" | tee -a "$OUTPUT"
        cat "$TMP_ERROR_LOG" | tee -a "$OUTPUT"
        echo "---------------" | tee -a "$OUTPUT"
    fi

    echo "" | tee -a "$OUTPUT"
done

rm -f "$TMP_ERROR_LOG"
echo "Scan complete. Report saved to: $OUTPUT"
