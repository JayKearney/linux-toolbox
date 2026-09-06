#!/bin/bash
set -euo pipefail

# inspect-mac.sh — process, inode, and deleted-file inspection on macOS (Darwin/BSD).
# macOS has no /proc; the same information comes from ps, lsof, and stat.
# See the Linux equivalents (/proc-based) noted in the README.

usage() {
  echo "Usage: $0 process <pid> | inode <file> | deleted"
  exit 1
}

state_meaning() {
  # macOS state letters (first char of the STAT column)
  case ${1:0:1} in
    R) echo "(runnable — on or waiting for CPU)" ;;
    S) echo "(sleeping < ~20s — waiting normally, healthy)" ;;
    I) echo "(idle — sleeping > ~20s)" ;;
    U) echo "(uninterruptible wait — stuck on I/O, cannot be killed)" ;;
    Z) echo "(zombie — exited, parent never collected status)" ;;
    T) echo "(stopped/paused)" ;;
    *) echo "" ;;
  esac
}

inspect_process() {
  local pid=$1
  # -p <pid> fails if the process doesn't exist; guard on that.
  ps -p "$pid" >/dev/null 2>&1 || { echo "No such process: $pid"; exit 1; }

  local state rss comm
  state=$(ps -o stat= -p "$pid" | tr -d ' ')
  rss=$(ps -o rss= -p "$pid" | tr -d ' ')          # resident memory in KB
  comm=$(ps -o comm= -p "$pid")

  echo "PID:      $pid"
  echo "Command:  $comm"
  echo "State:    $state  $(state_meaning "$state")"
  echo "Memory:   ${rss} KB resident (RSS)"
  echo "Open FDs: $(lsof -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
}

inspect_inode() {
  local file=$1
  stat -x "$file"    # -x gives a verbose, Linux-like layout on macOS
  echo
  echo "Note: the filename is NOT stored in the inode above —"
  echo "it lives in the directory entry mapping name -> inode number."
}

find_deleted_open() {
  echo "Processes holding deleted files open (space not yet freed):"
  # lsof marks deleted-but-still-open files; that space isn't freed until close.
  lsof 2>/dev/null | grep -i 'deleted' || echo "None found."
}

case ${1:-} in
  process) inspect_process "${2:?pid required}" ;;
  inode)   inspect_inode   "${2:?file required}" ;;
  deleted) find_deleted_open ;;
  *) usage ;;
esac