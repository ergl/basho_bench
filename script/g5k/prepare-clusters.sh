#!/usr/bin/env bash

run () {
  local dc_size=$1
  local total_dcs=$2

  echo "[STOP_ANTIDOTE]: Starting..."
  ./control-nodes.sh --stop
  echo "[STOP_ANTIDOTE]: Done"

  echo "[START_ANTIDOTE]: Starting..."
  ./control-nodes.sh --start
  echo "[START_ANTIDOTE]: Done"

  echo "[BUILD_CLUSTER]: Starting..."
  ./join-clusters.sh ${dc_size} ${total_dcs}
  echo "[BUILD_CLUSTER]: Done"
}

run "$@"
