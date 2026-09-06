#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 process <pid> | inode <file> | deleted"
  exit 1
}

inspect_process() {
  local pid=$1
  [[ -d /proc/$pid ]] || { echo "No such process: $pid"; exit 1; }

  local state
  state=$(awk '{print $3}' "/proc/$pid/stat")
  echo "PID:     $pid"
  echo "Command: $(tr -d '\0' < /proc/$pid/cmdline)"
  echo "State:   $state  $(state_meaning "$state")"
  echo "Memory:  $(grep VmRSS /proc/$pid/status 2>/dev/null || echo 'VmRSS: n/a (kernel thread)')"
  echo "Open FDs: $(ls /proc/$pid/fd 2>/dev/null | wc -l)"
}

state_meaning() {
  case $1 in
    R) echo "(running on CPU)" ;;
    S) echo "(sleeping — waiting normally, healthy)" ;;
    D) echo "(uninterruptible sleep — stuck on disk/network I/O, cannot be killed)" ;;
    Z) echo "(zombie — exited, parent never collected status)" ;;
    T) echo "(stopped/paused)" ;;
    *) echo "" ;;
  esac
}

inspect_inode() {
  local file=$1
  stat "$file"
  echo
  echo "Note: the filename is NOT stored in the inode above —"
  echo "it lives in the directory entry mapping name → inode number."
}

find_deleted_open() {
  echo "Processes holding deleted files open (space not yet freed):"
  ls -l /proc/*/fd 2>/dev/null | grep '(deleted)' || echo "None found."
}

case ${1:-} in
  process) inspect_process "${2:?pid required}" ;;
  inode)   inspect_inode   "${2:?file required}" ;;
  deleted) find_deleted_open ;;
  *) usage ;;
esac