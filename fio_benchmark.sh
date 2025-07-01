#!/bin/bash

# Function to check if a package is installed; installs if not
install_if_missing() {
  if ! dpkg -s "$1" &>/dev/null; then
    echo ""
    echo "Installing required package: $1. Please wait..."
    sudo apt-get install -y "$1"
  else
    echo "$1 is already installed. Skipping..."
  fi
}

echo "========================================"
echo "Checking and installing necessary packages..."
echo "========================================"

install_if_missing xdotool
install_if_missing nmon

echo ""
echo "========================================"
echo "Launching System Monitor (nmon)..."
echo "========================================"
echo "A new terminal window will open to show live disk activity."
echo "Do not close that window; it will update in real time."
lxterminal --title "nmon" -e nmon &

sleep 5  # Allow nmon to load

# Locate the nmon terminal window and activate it
WID=$(xdotool search --class lxterminal | while read id; do
  TITLE=$(xdotool getwindowname "$id")
  if [[ "$TITLE" == *nmon* ]]; then
    echo "$id"
    break
  fi
done)

if [ -n "$WID" ]; then
  xdotool windowactivate --sync "$WID"
  sleep 1
  for i in {1..3}; do
    xdotool key --window "$WID" d
    sleep 0.5
  done
  echo "nmon window is active and showing disk activity."
else
  echo "Warning: Unable to detect the nmon window. You may need to switch to it manually."
fi

echo ""
echo "========================================"
echo "Welcome to the Storage Benchmark Script"
echo "========================================"
echo "This script helps test the performance of your HDD or NVMe drives."
echo "You will first choose a drive type, then pick which devices to test."

# Ask for drive type
drive_type=""
while [ "$drive_type" != "1" ] && [ "$drive_type" != "2" ]; do
  echo ""
  echo "Please select the type of drive you want to benchmark:"
  echo "  1) Hard Drive (HDD)"
  echo "  2) NVMe Drive (SSD)"
  read -p "Enter 1 for HDD or 2 for NVMe: " drive_type

  if [[ "$drive_type" != "1" && "$drive_type" != "2" ]]; then
    echo "Invalid input. Please type either 1 or 2."
  fi
done

# Function to select storage devices
select_devices() {
  echo ""
  echo "Detecting available storage devices..."

  mapfile -t devices < <(lsblk -dn -o NAME,SIZE,TYPE | awk '$3=="disk"{print $1,$2}' | sort -V)

  if [ "${#devices[@]}" -eq 0 ]; then
    echo "No storage devices found. Exiting."
    exit 1
  fi

  echo ""
  echo "List of detected storage devices:"
  for i in "${!devices[@]}"; do
    echo "$((i+1))) ${devices[i]}"
  done

  echo ""
  echo "Please enter the number(s) for the device(s) you want to test."
  echo "Separate multiple numbers with commas (e.g., 1,3,4)"
  read -p "Your selection: " input

  input_without_spaces=$(echo "$input" | tr -d ' ')
  IFS=',' read -ra selections <<< "$input_without_spaces"

  invalid_selection=false
  for i in "${selections[@]}"; do
    if [[ ! "$i" =~ ^[1-9][0-9]*$ ]] || (( i <= 0 || i > ${#devices[@]} )); then
      echo "Invalid selection: $i. Please choose numbers from the list."
      invalid_selection=true
      break
    fi
  done

  if [ "$invalid_selection" = true ]; then
    echo ""
    echo "Let's try selecting devices again."
    select_devices
    return
  fi

  filenames=""
  for i in "${selections[@]}"; do
    ((device_index=i-1))
    filenames+="/dev/${devices[device_index]%% *}:"
  done
  filenames=${filenames%:}

  echo ""
  echo "You selected the following device(s):"
  echo "$filenames"
}

# HDD branch
if [ "$drive_type" == "1" ]; then
  echo ""
  echo "You chose to test Hard Disk Drives (HDDs)."
  echo "Here are your connected drives:"
  lsblk -dn -o NAME,SIZE,TYPE | awk '$3=="disk"{print "/dev/"$1, $2}'
  echo ""

  while true; do
    echo "Please enter the size of the test file to create for benchmarking."
    echo "Use a format like 4G (4 gigabytes), 500M (500 megabytes), etc."
    read -p "Enter test size: " size

    if [[ "$size" =~ ^[0-9]+([KkMmGgTtPp])?$ ]]; then
      break
    else
      echo "Invalid format. Use a number followed by an optional unit (K, M, G, T, or P). Example: 2G"
    fi
  done

  select_devices

  if [ -z "$filenames" ]; then
    echo "No devices selected. Exiting..."
    exit 1
  fi

  echo ""
  echo "Starting the HDD benchmark..."
  echo "This may take several minutes depending on file size."
  echo ""
  echo "Running the following fio command:"
  echo "fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --bs=4k --iodepth=64 --readwrite=randrw --rwmixread=75 --size=$size --filename=$filenames"
  fio --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --bs=4k --iodepth=64 --readwrite=randrw --rwmixread=75 --size=$size --filename=$filenames

# NVMe branch
elif [ "$drive_type" == "2" ]; then
  echo ""
  echo "You chose to test NVMe drives."
  echo "Next, enter the duration for the test to run."
  echo "Examples: 3600s (seconds), 1m (minute), 2h (hours), 3d (days)"

  while true; do
    read -p "Enter test runtime: " runtime
    if [[ $runtime =~ ^[0-9]+[smhd]$ ]]; then
      break
    else
      echo "Invalid input. Please use a number followed by s, m, h, or d. Example: 2h"
    fi
  done

  select_devices

  if [ -z "$filenames" ]; then
    echo "No devices selected. Exiting..."
    exit 1
  fi

  echo ""
  echo "Starting the NVMe benchmark..."
  echo "This may take some time depending on the test duration."
  echo ""
  echo "Running the following fio command:"
  echo "fio --ioengine=libaio --direct=1 --readwrite=randrw --thread=1 --norandommap=1 --time_base=1 --ramp_time=10s --bs=4k --iodepth=32 --numjobs=1 --name=test --rwmixread=100 --runtime=${runtime} --filename=$filenames"
  fio --ioengine=libaio --direct=1 --readwrite=randrw --thread=1 --norandommap=1 --time_base=1 --ramp_time=10s --bs=4k --iodepth=32 --numjobs=1 --name=test --rwmixread=100 --runtime=${runtime} --filename=$filenames
fi

echo ""
echo "Benchmark completed. You can now review the results above."
echo "Thank you for using this benchmark script."
