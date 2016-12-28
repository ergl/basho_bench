#!/usr/bin/env bash

set -eo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: ${0##*/} dc-size total-dcs"
  exit 1
fi

joinLocalDC () {
  local dc_nodes=( $(cat "${1}") )
  local dc_size=${#dc_nodes[*]}

  local head="${dc_nodes[0]}"

  local nodes_str
  for node in "${dc_nodes[@]}"; do
    nodes_str+="'antidote@${node}' "
  done

  nodes_str=${nodes_str%?}

  local join_dc="\
    ./antidote/bin/join_cluster_script.erl ${nodes_str}
  "

  ./execute-in-nodes.sh "${head}" "${join_dc}" "-debug"
}


joinNodes () {
  local dc_size=$1
  local total_dcs=$2

  # No point in clustering if we have only 1 node
  if [[ ${dc_size} -le 1 ]]; then
    echo -e "\t[BUILDING_LOCAL_CLUSTER]: Skipping"
  else
    echo -e "\t[BUILDING_LOCAL_CLUSTER]: Starting..."

    local offset=0
    for _ in $(seq 1 ${total_dcs}); do
      head -$((dc_size + offset)) "${ANT_IPS}" > .dc_nodes
      joinLocalDC .dc_nodes
      offset=$((offset + dc_size))
    done

    echo -e "\t[BUILDING_LOCAL_CLUSTER]: Done"
  fi

  # No point in inter-dc clustering if we have only 1 dc
  if [[ ${total_dcs} -le 1 ]]; then
    echo -e "\t[INTER_DC_CLUSTERING]: Skipping"
    exit
  fi

  # TODO: Join only one node per dc
  echo -e "\t[INTER_DC_CLUSTERING]: Starting..."
  echo -e "\t[INTER_DC_CLUSTERING]: Done"
}

run () {
  local dc_size=$1
  local total_dcs=$2

  joinNodes ${dc_size} ${total_dcs}
}

run "$@"
