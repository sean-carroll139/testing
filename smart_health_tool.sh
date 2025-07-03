#!/bin/bash

LOG_FILE="/tmp/smartcheck.log"
DATA_FOLDER="/smart/data"
CSV_FILE="$DATA_FOLDER/summary.csv"
EMAIL_RECIPIENT="sean.carroll@ahead.com"
SUBJECT="SMART Health Check Failure Report - $(hostname)"
BAD_DRIVES=()
MAX_RAID_DISKS=32
RAID_TOOLS=(storcli64 storcli perccli64 perccli ssacli)

mkdir -p "$DATA_FOLDER"
> "$LOG_FILE"
echo "Device,Serial Number,Health,Reallocated_Sector_Ct,Current_Pending_Sector,Offline_Uncorrectable" > "$CSV_FILE"

# Color codes for deuteranopia-friendly output
BOLD="\033[1m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RED="\033[1;31m"
NC="\033[0m"

log()  { echo -e "${BOLD}${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${BOLD}${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"; }
crit() { echo -e "${BOLD}${RED}[CRITICAL]${NC} $*" | tee -a "$LOG_FILE"; }

install_required_packages() {
  if command -v apt-get &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update
    for pkg in smartmontools mailutils postfix; do
      if ! dpkg -s "$pkg" &>/dev/null; then
        log "Installing $pkg..."
        if [ "$pkg" = "postfix" ]; then
          echo "postfix postfix/mailname string $(hostname)" | sudo debconf-set-selections
          echo "postfix postfix/main_mailer_type string 'Internet Site'" | sudo debconf-set-selections
        fi
        sudo apt-get install -y "$pkg"
      fi
    done
    sudo systemctl enable --now postfix
  elif command -v yum &>/dev/null; then
    sudo yum install -y smartmontools mailx postfix
    sudo systemctl enable --now postfix
  fi
}

get_serial_number() {
  smartctl -i "$1" | grep -oP 'Serial [Nn]umber:\s*\K\S+'
}

save_smart_data() {
  local device="$1"
  local serial=$(get_serial_number "$device")
  [ -z "$serial" ] && serial=$(basename "$device" | tr '/' '_')
  smartctl --all "$device" > "$DATA_FOLDER/${serial}.txt"
}

parse_and_log_csv() {
  local device="$1"
  local serial=$(get_serial_number "$device")
  [ -z "$serial" ] && serial=$(basename "$device")
  local health=$(grep -i "SMART overall-health" /tmp/smart_output.txt | awk -F: '{print $2}' | xargs)
  local realloc=$(grep -i "Reallocated_Sector_Ct" /tmp/smart_output.txt | awk '{print $10}' | head -n1)
  local pending=$(grep -i "Current_Pending_Sector" /tmp/smart_output.txt | awk '{print $10}' | head -n1)
  local offline=$(grep -i "Offline_Uncorrectable" /tmp/smart_output.txt | awk '{print $10}' | head -n1)
  echo "$device,$serial,$health,${realloc:-0},${pending:-0},${offline:-0}" >> "$CSV_FILE"
}

send_alert_email() {
  [ ${#BAD_DRIVES[@]} -eq 0 ] && return

  log "Sending HTML-formatted alert email to $EMAIL_RECIPIENT..."
  local html_body="/tmp/smart_email_body.html"
  local boundary="smart-check-$(date +%s)"

  cat <<EOF > "$html_body"
Subject: $SUBJECT
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="$boundary"

--$boundary
Content-Type: text/html; charset="UTF-8"
Content-Transfer-Encoding: 7bit

<html>
  <body style="font-family:sans-serif; color:#000;">
    <h2 style="color:#003366;">SMART Health Report - $(hostname)</h2>
    <p><strong>Detected Issues:</strong></p>
    <table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse; font-size:14px;">
      <thead style="background-color:#003366; color:#fff;">
        <tr>
          <th>Device</th>
          <th>Serial</th>
          <th>Health</th>
          <th>Reallocated</th>
          <th>Pending</th>
          <th>Uncorrectable</th>
        </tr>
      </thead>
      <tbody>
EOF

  tail -n +2 "$CSV_FILE" | while IFS=',' read -r dev serial health realloc pend uncorrect; do
    color="#009900"
    [[ "$health" =~ FAIL ]] && color="#cc0000"
    [[ "$realloc" -gt 0 || "$pend" -gt 0 || "$uncorrect" -gt 0 ]] && color="#ff9900"
    cat <<ROW >> "$html_body"
        <tr>
          <td>$dev</td>
          <td>$serial</td>
          <td style="color:$color;"><strong>$health</strong></td>
          <td align="center">$realloc</td>
          <td align="center">$pend</td>
          <td align="center">$uncorrect</td>
        </tr>
ROW
  done

  cat <<EOF >> "$html_body"
      </tbody>
    </table>
    <p style="margin-top:20px;">Full reports saved to: <code>$DATA_FOLDER</code></p>
  </body>
</html>

--$boundary
Content-Type: text/csv; name="summary.csv"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="summary.csv"

EOF

  base64 "$CSV_FILE" >> "$html_body"
  echo "--$boundary--" >> "$html_body"

  sendmail -t < "$html_body"
}

check_smartctl_drive() {
  local device="$1"
  local opt="$2"
  smartctl -H -A $opt "$device" &>/tmp/smart_output.txt
  save_smart_data "$device"
  parse_and_log_csv "$device"

  grep -q "SMART support is: Unavailable" /tmp/smart_output.txt && return

  if grep -q "SMART overall-health.*FAILED" /tmp/smart_output.txt; then
    crit "SMART health FAILED on $device"
    BAD_DRIVES+=("$device")
    cat /tmp/smart_output.txt >> "$LOG_FILE"
    return
  fi

  if grep -E 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Reported_Uncorrect|Percent_Lifetime_Remain|Unexpect_Power_Loss_Ct|Write_Error_Rate|Program_Fail_Count|Erase_Fail_Count' /tmp/smart_output.txt |
      awk '{
        attr=$2
        val=$10
        if (val ~ /^[0-9]+$/ && (
            (attr == "Reallocated_Sector_Ct"       && val > 0) ||
            (attr == "Current_Pending_Sector"      && val > 0) ||
            (attr == "Offline_Uncorrectable"       && val > 0) ||
            (attr == "Reported_Uncorrect"          && val > 0) ||
            (attr == "Write_Error_Rate"            && val > 0) ||
            (attr == "Program_Fail_Count"          && val > 0) ||
            (attr == "Erase_Fail_Count"            && val > 0) ||
            (attr == "Percent_Lifetime_Remain"     && val <= 5) ||
            (attr == "Unexpect_Power_Loss_Ct"      && val > 100)
        )) print
      }' | grep -q '.'; then
    warn "SMART attribute issues detected on $device"
    BAD_DRIVES+=("$device")
  fi
}

check_smartctl_all() {
  log "Scanning standard drives..."
  for dev in /dev/sd? /dev/nvme?n? /dev/sg?; do
    [ -b "$dev" ] && check_smartctl_drive "$dev"
  done
}

check_raid_drives_smartctl_scan() {
  log "Scanning RAID drives..."
  smartctl --scan-open | grep -i "megaraid" | while read -r line; do
    device=$(echo "$line" | awk '{print $1}')
    driver=$(echo "$line" | grep -o 'megaraid,[0-9]*')
    check_smartctl_drive "$device" "-d $driver"
  done

  for i in $(seq 0 $((MAX_RAID_DISKS-1))); do
    for dev in /dev/sd?; do
      [ -b "$dev" ] && smartctl -a -d megaraid,$i "$dev" &>/dev/null && check_smartctl_drive "$dev" "-d megaraid,$i"
    done
  done
}

check_storcli() {
  local cli="$1"
  log "Checking RAID with $cli..."
  controllers=$($cli show | grep -Eo '^ *[0-9]+' | awk '{print $1}')
  for ctrl in $controllers; do
    for i in $(seq 0 $((MAX_RAID_DISKS-1))); do
      smartctl -a -d megaraid,$i /dev/sda &>/dev/null && check_smartctl_drive /dev/sda "-d megaraid,$i"
    done
  done
}

check_raid_drives_with_tools() {
  for tool in "${RAID_TOOLS[@]}"; do
    command -v "$tool" &>/dev/null && [[ "$tool" == *storcli* || "$tool" == *perccli* ]] && check_storcli "$tool"
  done
}

summary() {
  if [ ${#BAD_DRIVES[@]} -eq 0 ]; then
    log "All drives passed SMART checks."
  else
    crit "Drives with SMART warnings or failures:"
    for bad in "${BAD_DRIVES[@]}"; do echo " - $bad" | tee -a "$LOG_FILE"; done
    send_alert_email
    exit 1
  fi
}

copy_to_usb_auto() {
  echo -e "\n${BOLD}${YELLOW}Looking for USB drive to copy SMART reports...${NC}"
  local candidate=$(lsblk -rpno NAME,RM,MOUNTPOINT | awk '$2==1 && $3=="" {print $1}' | head -n1)
  [ -z "$candidate" ] && warn "No USB drive found." && return

  echo -e "${BOLD}Suggested USB device:${NC} $candidate"
  read -p "Copy SMART data to $candidate? (y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || return

  sudo mkdir -p /mnt/usbsmart
  log "Mounting $candidate..."
  sudo mount "$candidate" /mnt/usbsmart || { crit "Mount failed."; return; }

  sudo mkdir -p /mnt/usbsmart/smart
  log "Copying SMART data to USB..."
  sudo cp -ar "$DATA_FOLDER" /mnt/usbsmart/smart/

  log "Unmounting..."
  sudo umount /mnt/usbsmart
  log "Copied SMART data to USB: /smart/data"
}

main() {
  install_required_packages
  check_smartctl_all
  check_raid_drives_smartctl_scan
  check_raid_drives_with_tools
  summary
  copy_to_usb_auto
}

main
