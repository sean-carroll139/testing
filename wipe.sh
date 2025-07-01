#!/bin/bash

set -euo pipefail
shopt -s nullglob

REQUIRED_CMDS=("smartctl" "hdparm" "parted" "lsblk" "mdadm" "nvme" "pvremove" "vgremove" "lvremove" "sgdisk")

install_missing_packages() {
    echo "Checking required tools..."
    missing=()
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        echo "Missing tools: ${missing[*]}"
        echo "Installing missing packages..."
        sudo apt update
        sudo apt install -y smartmontools hdparm parted mdadm nvme-cli lvm2 gdisk
    else
        echo "All required tools found."
    fi
}

select_drive_type() {
    echo
    echo "Select which type of drives you want to wipe:"
    echo "  1) NVMe SSDs"
    echo "  2) SATA/SAS SSDs"
    echo "  3) Exit"

    while true; do
        read -rp "Enter your choice (1/2/3): " choice
        case "$choice" in
            1) DRIVE_TYPE="nvme"; break ;;
            2) DRIVE_TYPE="sata"; break ;;
            3) echo "Exiting."; exit 0 ;;
            *) echo "Invalid option. Try again." ;;
        esac
    done
}

detect_drives() {
    if [[ "$DRIVE_TYPE" == "nvme" ]]; then
        mapfile -t drives < <(lsblk -dno NAME | grep -E '^nvme[0-9]+n1')
    else
        mapfile -t drives < <(lsblk -d -o NAME,ROTA,TYPE | awk '$2 == 0 && $3 == "disk" {print $1}' | grep -v '^nvme')
    fi

    if [[ ${#drives[@]} -eq 0 ]]; then
        echo "No $DRIVE_TYPE drives found. Exiting."
        exit 1
    fi
}

display_drive_info() {
    echo
    echo "Drive Information:"
    for drive in "${drives[@]}"; do
        dev="/dev/$drive"
        echo
        echo "=== $dev ==="
        smartctl -i "$dev" 2>/dev/null | grep -E "Model|Serial|Firmware|Capacity"
        smartctl -H "$dev" 2>/dev/null | grep "SMART overall-health"
        lsblk "$dev"
    done
}

get_user_confirmation() {
    while true; do
        read -rp "This will erase ALL DATA on the above drives. Continue? (Y/N): " confirm
        case "$confirm" in
            [Yy]) return 0 ;;
            [Nn]) echo "Cancelled."; exit 0 ;;
            *) echo "Please type Y or N." ;;
        esac
    done
}

attempt_stop_raid() {
    echo "Stopping all active md devices..."
    for md in /dev/md*; do
        [ -e "$md" ] || continue
        echo "  Attempting to stop $md"
        mdadm --stop "$md" || echo "  Failed to stop $md"
        mdadm --remove "$md" || echo "  Failed to remove $md"
    done
}

zero_raid_superblocks() {
    echo "Zeroing md superblocks on partitions..."
    for dev in "${drives[@]}"; do
        for part in /dev/${dev}?*; do
            if [[ -e "$part" ]]; then
                echo "  Wiping md superblock on $part"
                mdadm --zero-superblock "$part" || echo "  Failed to zero $part"
            fi
        done
    done
}

wipe_drives() {
    for drive in "${drives[@]}"; do
        dev="/dev/$drive"
        echo
        echo "WIPING $dev..."

        echo "Unmounting any mounted partitions..."
        lsblk -ln "$dev" | awk '{print $1}' | while read -r part; do
            mountpoint=$(findmnt -nr -o TARGET "/dev/$part" || true)
            if [[ -n "$mountpoint" ]]; then
                echo "  Unmounting /dev/$part from $mountpoint"
                umount -f "/dev/$part" || echo "  Failed to unmount /dev/$part"
            fi
        done

        echo "Deactivating and removing LVM if present..."
        pvs_output=$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | grep "$dev" || true)
        if [[ -n "$pvs_output" ]]; then
            while read -r pv vg; do
                echo "  Found PV $pv in VG $vg"
                vgchange -an "$vg" || echo "  Could not deactivate VG $vg"
                lvremove -fy "$vg" || echo "  Could not remove LVs in $vg"
                vgremove -f "$vg" || echo "  Could not remove VG $vg"
                pvremove -ff "$pv" || echo "  Could not remove PV $pv"
            done <<< "$pvs_output"
        fi

        echo "Wiping filesystem signatures..."
        wipefs -a "$dev" || echo "Failed to wipe filesystem on $dev"

        echo "Creating new GPT label..."
        parted "$dev" --script mklabel gpt || echo "Failed to create GPT on $dev"

        echo "Zapping GPT/MBR partition tables..."
        sgdisk --zap-all "$dev" || echo "Failed to zap partition tables on $dev"

        if [[ "$DRIVE_TYPE" == "nvme" ]]; then
            echo "Attempting NVMe secure format..."
            nvme format -f "$dev" || echo "nvme format failed on $dev"
        else
            echo "Attempting secure erase with hdparm..."
            if hdparm -I "$dev" | grep -q "supported: enhanced erase"; then
                hdparm --user-master u --security-set-pass NULL "$dev"
                hdparm --user-master u --security-erase NULL "$dev"
            else
                echo "Secure erase not supported for $dev"
            fi
        fi

        echo "Final layout for $dev:"
        lsblk "$dev"
    done
}

# === Main Script Execution ===
install_missing_packages
select_drive_type
detect_drives
display_drive_info
get_user_confirmation
attempt_stop_raid
zero_raid_superblocks
wipe_drives

echo
echo "Wipe process completed for all selected $DRIVE_TYPE drives."
