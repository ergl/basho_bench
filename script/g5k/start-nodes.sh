#!/usr/bin/env bash

set -eo pipefail

startNodes () {
  # `localhost` keyword will be replaced by the ip before executing
  local antidote_ips=( $(cat ${ANT_IPS}) )
  for node in "${antidote_ips[@]}"; do
    scp -i ${EXPERIMENT_PRIVATE_KEY} ./control-nodes-remote.sh root@${node}:/root/
  done

  ./execute-in-nodes.sh "$(cat ${ANT_IPS})" "./control-nodes-remote.sh start"
}

startNodes
