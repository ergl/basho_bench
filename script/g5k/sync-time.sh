#!/usr/bin/env bash

set -eo pipefail

syncTime () {
  $(while true; do
    local command="\
      service ntp stop && \
      /usr/sbin/ntpdate -b ntp2.grid5000.fr && \
      service ntp start
    "
    ./execute-in-nodes.sh "$(cat ${ANT_NODES})" "${command}" "-debug"
    sleep 60
  done) &

  echo "${!}"
}

if [[ $# -eq 1 && "$1" == "--start" ]]; then
  echo "$(syncTime)"
elif [[ $# -eq 2 && "$1" == "--stop" ]]; then
  kill $2
else
  echo "Usage: ${0##*/} [--start] [--stop pid]"
  exit 1
fi
