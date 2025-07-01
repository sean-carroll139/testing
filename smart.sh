#!/bin/bash

LOG_FILE="/tmp/smartcheck.log"
EMAIL_RECIPIENT="sean.carroll@ahead.com"
SUBJECT="SMART Health Check Failure Report - $(hostname)"
BAD_DRIVES=()
MAX_RAID_DISKS=32
RAID_TOOLS=(storcli64 storcli perccli64 perccli ssacli)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

install_required_packages() {
  local INSTALL_CMD=""
  if command -v apt-get &>/dev/null; then
    INSTALL_CMD="apt-get install -y"
    export DEBIAN_FRONTEND=noninteractive

    for pkg in smartmontools mailutils postfix; do
      if ! dpkg -s "$pkg" &>/dev/null; then
        log "Installing missing package: $pkg"
        if [ "$pkg" = "postfix" ]; then
          echo "postfix postfix/main_mailer_type string 'Internet Site'" | sudo debconf-set-selections
          echo "postfix postfix/mailname string $(hostname)" | sudo debconf-set-selections
        fi
        sudo $INSTALL_CMD "$pkg"
      fi
    done

  elif command -v yum &>/dev/null; then
    INSTALL_CMD="yum install -y"
    sudo $INSTALL_CMD smartmontools mailx postfix
    sudo systemctl enable --now postfix
  elif command -v dnf &>/dev/null; then
    INSTALL_CMD="dnf install -y"
    sudo $INSTALL_CMD smartmontools mailx postfix
    sudo systemctl enable --now postfix
  else
    log "ERROR: No supported package manager found."
    exit 1
  fi
}

send_alert_email() {
  if [ ${#BAD_DRIVES[@]} -gt 0 ]; then
    log "Sending alert email to $EMAIL_RECIPIENT using mailx/sendmail..."
    mail -s "$SUBJECT" "$EMAIL_RECIPIENT" < "$LOG_FILE"
  fi
}

check_smartctl_drive() {
  local drive="$1"
  local options="$2"
  smartctl -H -A $options "$drive" &>/tmp/smart_output.txt

  if grep -q "SMART support is: Unavailable" /tmp/smart_output.txt; then return; fi

  if grep -q "SMART overall-health self-assessment test result: FAILED" /tmp/smart_output.txt; then
    log "CRITICAL: SMART health failed on $drive"
    BAD_DRIVES+=("$drive")
    cat /tmp/smart_output.txt >> "$LOG_FILE"
    return
  fi

  if grep -E 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Media_Wearout_Indicator|Percentage Used' /tmp/smart_output.txt | awk '{if ($2 ~ /^[0-9]+$/ && $10 > 0) print}' | grep -q '.'; then
    log "WARNING: Problematic SMART values detected on $drive"
    grep -E 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Media_Wearout_Indicator|Percentage Used' /tmp/smart_output.txt | tee -a "$LOG_FILE"
    BAD_DRIVES+=("$drive")
  fi
}

check_smartctl_all() {
  log "Scanning all /dev/sd?, /dev/nvme?, /dev/sg? devices..."
  for dev in /dev/sd? /dev/nvme?n? /dev/sg?; do
    [ -b "$dev" ] || continue
    log "Checking SMART data for $dev"
    check_smartctl_drive "$dev"
  done
}

check_raid_drives_smartctl_scan() {
  log "Checking RAID drives via smartctl --scan..."
  smartctl --scan-open | grep -i "megaraid" | while read -r line; do
    device=$(echo "$line" | awk '{print $1}')
    driver=$(echo "$line" | grep -o 'megaraid,[0-9]*')
    log "SMART RAID device: $device -d $driver"
    check_smartctl_drive "$device" "-d $driver"
  done

  for i in $(seq 0 $((MAX_RAID_DISKS-1))); do
    for dev in /dev/sd?; do
      [ -b "$dev" ] || continue
      if smartctl -a -d megaraid,$i "$dev" &>/tmp/smart_output.txt; then
        if grep -q "Device Model" /tmp/smart_output.txt; then
          log "SMART RAID (brute) - $dev -d megaraid,$i"
          check_smartctl_drive "$dev" "-d megaraid,$i"
        fi
      fi
    done
  done
}

check_raid_drives_with_tools() {
  for tool in "${RAID_TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
      case "$tool" in
        storcli*|perccli*) check_storcli "$tool" ;;
        ssacli)            check_ssacli ;;
      esac
    fi
  done
}

check_storcli() {
  local cli="$1"
  log "Checking RAID with $cli..."
  controllers=$($cli show | grep -Eo '^ *[0-9]+' | awk '{print $1}')
  for ctrl in $controllers; do
    for i in $(seq 0 $((MAX_RAID_DISKS-1))); do
      if smartctl -a -d megaraid,$i /dev/sda &>/tmp/smart_output.txt; then
        if grep -q "Device Model" /tmp/smart_output.txt; then
          log "SMART RAID (storcli passthrough): /dev/sda -d megaraid,$i"
          check_smartctl_drive /dev/sda "-d megaraid,$i"
        fi
      fi
    done
  done
}

check_ssacli() {
  log "Detected ssacli, but SMART passthrough may not be supported directly."
}

summary() {
  if [ ${#BAD_DRIVES[@]} -eq 0 ]; then
    log "All drives passed SMART checks."
  else
    log "Drives with SMART warnings or failures:"
    for bad in "${BAD_DRIVES[@]}"; do
      echo " - $bad" | tee -a "$LOG_FILE"
    done
    send_alert_email
    exit 1
  fi
}

main() {
  : > "$LOG_FILE"
  install_required_packages
  check_smartctl_all
  check_raid_drives_smartctl_scan
  check_raid_drives_with_tools
  summary
}

main
