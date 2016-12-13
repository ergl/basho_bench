#!/usr/bin/env bash

if [[ $# -ne 1 ]]; then
  exit 1
fi

ntpClock () {
  while true; do
    service ntp stop
    /usr/sbin/ntpdate -b ntp2.grid5000.fr
    service ntp start
    sleep 60
  done
}

start () {
  ntpClock &
  echo "$!" > .ntp_timer_pid
}

stop () {
  if [[ -f .ntp_timer_pid ]]; then
    local timer_pid=$(< .ntp_timer_pid)
    kill ${timer_pid}
  fi
}

case "$1" in
  "--start") start;;
  "*") stop
esac
