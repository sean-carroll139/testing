#!/bin/bash

###########################################################
# Script: unlockHDD.sh
# Author: Sean Carroll
# Updated: 2025-07-09
# Description: Automatically detects locked drives and attempts
#              to unlock them using increasingly aggressive methods.
#              Includes support for Micron drives, secure erase,
#              ATA sanitize, and RAID BIOS fallback.
###########################################################

password="password"

unlock_drives() {
    local drive=$1
    local model=$(hdparm -I "$drive" 2>/dev/null | grep "Model Number" | awk -F ':' '{print $2}' | xargs)

    echo -e "\n[INFO] Checking $drive ($model)..."

    if hdparm -I "$drive" 2>/dev/null | grep -q "not locked"; then
        echo "[OK] $drive is not locked."
        return
    fi

    echo "[WARN] $drive appears to be locked. Attempting to unlock..."

    # Attempt standard unlocks
    if hdparm --security-unlock "$password" "$drive" >/dev/null 2>&1 ||
       hdparm --user-master u --security-unlock "$password" "$drive" >/dev/null 2>&1; then
        echo "[SUCCESS] Unlocked $drive with standard method."
        return
    fi

    # Micron-specific logic
    if echo "$model" | grep -qi "micron"; then
        echo "[INFO] Micron drive detected. Trying secure erase before re-attempting unlock..."
        hdparm --user-master u --security-erase "$password" "$drive" >/dev/null 2>&1
        hdparm --user-master u --security-unlock "$password" "$drive" >/dev/null 2>&1
    fi

    # Try to disable security
    hdparm --user-master u --security-disable "$password" "$drive" >/dev/null 2>&1

    # Re-check
    if hdparm -I "$drive" 2>/dev/null | grep -q "not locked"; then
        echo "[SUCCESS] $drive unlocked after secure erase or security disable."
        return
    fi

    echo "[FAIL] $drive still locked. Attempting ATA sanitize methods (destructive)..."

    # Try sanitize-crypto-scramble
    hdparm --yes-i-know-what-i-am-doing --sanitize-crypto-scramble "$drive" >/dev/null 2>&1
    sleep 3

    if hdparm -I "$drive" 2>/dev/null | grep -q "not locked"; then
        echo "[SUCCESS] $drive unlocked after sanitize-crypto-scramble."
        return
    fi

    # Try sanitize-block-erase
    hdparm --yes-i-know-what-i-am-doing --sanitize-block-erase "$drive" >/dev/null 2>&1
    sleep 3

    if hdparm -I "$drive" 2>/dev/null | grep -q "not locked"; then
        echo "[SUCCESS] $drive unlocked after sanitize-block-erase."
        return
    fi

    # Final fallback message
    echo "[ERROR] $drive remains locked after all methods."
    echo "[INFO] LAST RESORT: Connect $drive to a RAID controller (LSI, Dell, HP) with RAID BIOS."
    echo "        - Build a RAID 0 volume with the drive(s)"
    echo "        - ERASE the RAID (do not DELETE) to remove the lock"
}

# Detect drives
drives=$(lsblk -o NAME,TYPE -n | awk '$2=="disk"{print $1}')

# Loop through each drive
for drive in $drives; do
    unlock_drives "/dev/$drive"
done

echo -e "\n[INFO] To manually verify the unlocked status of drives, run:"
echo "       hdparm -I /dev/sd{a..z} | grep locked"
