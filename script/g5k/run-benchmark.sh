#!/usr/bin/env bash

set -eo pipefail

IFS=$'\r\n' GLOBIGNORE='*' :;

SELF=$(readlink $0 || true)
if [[ -z ${SELF} ]]; then
  SELF=$0
fi

cd $(dirname "$SELF")

source ./configuration.sh

sites=( "${SITES[@]}" )

buildReservation () {
  local reservation
  local node_number=$((DCS_PER_CLUSTER * (ANTIDOTE_NODES + BENCH_NODES)))
  for site in "${sites[@]}"; do
    reservation+="${site}:rdef=/nodes=${node_number},"
  done

  # Trim the last (,) in the string
  reservation=${reservation%?}

  echo "${reservation}"
}

reserveSites () {
  local reservation="$(buildReservation)"

  # Outputs something similar to:
  # ...
  # [OAR_GRIDSUB] Grid reservation id = 56670
  # ...

  local res_id=$(oargridsub -t deploy -w '2:00:00' "${reservation}" \
    | grep "Grid reservation id" \
    | cut -f2 -d=)

  # Trim any leading whitespace
  echo "${res_id## }"
}

if [[ "${RESERVE_SITES}" == "true" ]]; then
  echo "[RESERVING_SITES]: Starting..."
  export GRID_JOB_ID=$(reserveSites)
  sed -i.bak '/^GRID_JOB_ID.*/d' configuration.sh
  echo "GRID_JOB_ID=${GRID_JOB_ID}" >> configuration.sh
  echo "[RESERVING_SITES]: Done. Successfully reserved with id ${GRID_JOB_ID}"
else
  echo "[RESERVING_SITES]: Skipping"
fi

# Delete the reservation if script is killed
trap 'echo "${0##*/}: cancelling"; oargriddel ${GRID_JOB_ID}; exit 1' SIGINT SIGTERM

SCRATCHFOLDER="/home/$(whoami)/grid-benchmark-${GRID_JOB_ID}"
export LOGDIR=${SCRATCHFOLDER}/logs

export EXPERIMENT_PRIVATE_KEY=${SCRATCHFOLDER}/key
EXPERIMENT_PUBLIC_KEY=${SCRATCHFOLDER}/exp_key.pub

export ALL_NODES=${SCRATCHFOLDER}/.all_nodes
BENCH_NODEF=${SCRATCHFOLDER}/.bench_nodes
export ANT_NODES=${SCRATCHFOLDER}/.antidote_nodes

export ALL_IPS=${SCRATCHFOLDER}/.all_ips
BENCH_IPS=${SCRATCHFOLDER}/.bench_ips
export ANT_IPS=${SCRATCHFOLDER}/.antidote_ips

export ALL_COOKIES=${SCRATCHFOLDER}/.all_cookies
ANT_COOKIES=${SCRATCHFOLDER}/.antidote_cookies
BENCH_COOKIES=${SCRATCHFOLDER}/.bench_cookies


# For each node / ip in a file (one each line),
# ssh into it and run the given command
doForNodesIn () {
  ./execute-in-nodes.sh "$(cat "$1")" "$2" "-debug"
}


# Node Name -> IP
getIPs () {
  [[ -f ${ALL_IPS} ]] && rm ${ALL_IPS}
  [[ -f ${BENCH_IPS} ]] && rm ${BENCH_IPS}
  [[ -f ${ANT_IPS} ]] && rm ${ANT_IPS}

  while read n; do dig +short "${n}"; done < ${ANT_NODES} > ${ANT_IPS}
  while read n; do dig +short "${n}"; done < ${BENCH_NODEF} > ${BENCH_IPS}
  while read n; do dig +short "${n}"; done < ${ALL_NODES} > ${ALL_IPS}
}


# Get all nodes in reservation, split them into
# antidote and basho bench nodes.
gatherMachines () {
  echo "[GATHER_MACHINES]: Starting..."

  local antidote_nodes_per_site=$((DCS_PER_CLUSTER * ANTIDOTE_NODES))
  local benchmark_nodes_per_site=$((DCS_PER_CLUSTER * BENCH_NODES))

  [[ -f ${ALL_NODES} ]] && rm ${ALL_NODES}
  [[ -f ${ANT_NODES} ]] && rm ${ANT_NODES}
  [[ -f ${BENCH_NODEF} ]] && rm ${BENCH_NODEF}

  # Remove all blank lines and repeats
  # and add those to the full machine list
  oargridstat -w -l ${GRID_JOB_ID} | sed '/^$/d' \
    | awk '!seen[$0]++' > ${ALL_NODES}

  # For each site, get the list of nodes and slice
  # them into antidote and basho bench lists, depending on
  # the configuration given.
  for site in "${sites[@]}"; do
    awk < ${ALL_NODES} "/${site}/ {print $1}" \
      | tee >(head -${antidote_nodes_per_site} >> ${ANT_NODES}) \
      | sed "1,${antidote_nodes_per_site}d" \
      | head -${benchmark_nodes_per_site} >> ${BENCH_NODEF}
  done

  # Override the full node list, in case we didn't pick all the nodes
  cat ${BENCH_NODEF} ${ANT_NODES} > ${ALL_NODES}

  getIPs

  echo "[GATHER_MACHINES]: Done"
}


# Calculates the number of datacenters in the benchmark
getTotalDCCount () {
  # FIX: Assumes that all sites have the same number of data centers
  local sites_size=$((${#sites[*]} - 1))
  local total_dcs=$(( (sites_size + 1) * DCS_PER_CLUSTER))
  echo ${total_dcs}
}


# Number of antidote nodes in each datacenter
getDCSize () {
  # All sites have the same number of nodes, so it doesn't matter which one we pick
  local any_site="${sites[0]}"
  local site_antidote_node_size=$(grep -c -o ${any_site} ${ANT_NODES})
  local dc_size=$((site_antidote_node_size / DCS_PER_CLUSTER))
  echo ${dc_size}
}

# Use kadeploy to provision all the machines
kadeployNodes () {
  for site in "${sites[@]}"; do
    echo -e "\t[SYNC_IMAGE_${sites}]: Starting..."

    local image_dir="$(dirname "${K3_IMAGE}")"
    # rsync can only create dirs up to two levels deep, so we create it just in case
    ssh ${site} "mkdir -p ${image_dir}"
    rsync -r "${image_dir}" ${site}:"${image_dir}"

    echo -e "\t[SYNC_IMAGE_${sites}]: Done"

    echo -e "\t[DEPLOY_IMAGE_${sites}]: Starting..."

    local command="\
      oargridstat -w -l ${GRID_JOB_ID} \
        | sed '/^$/d' \
        | awk '/${sites}/ {print $1}' > ~/.todeploy && \
      kadeploy3 -f ~/.todeploy -a ${K3_IMAGE} -k ${EXPERIMENT_PUBLIC_KEY}
    "

    $(
      ssh -t -o StrictHostKeyChecking=no ${site} "${command}" \
        > ${LOGDIR}/${site}-kadeploy 2>&1
    ) &

    echo -e "\t[DEPLOY_IMAGE_${sites}]: In progress"
  done
  echo "[DEPLOY_IMAGE]: Waiting. (This may take a while)"
  wait
}


provisionBench () {
  echo -e "\t[PROVISION_BENCH_NODES]: Starting..."

  local ts=$1
  for i in $(seq 1 ${BENCH_INSTANCES}); do
    local bench_folder="basho_bench${i}"
    local command="\
      rm -rf ${bench_folder} && \
      git clone ${BENCH_URL} --branch ${BENCH_BRANCH} --single-branch ${bench_folder} && \
      cd ${bench_folder} && \
      make all
    "

    doForNodesIn ${ALL_NODES} "${command}" \
      >> "${LOGDIR}/basho_bench-compile-job${ts}" 2>&1

  done

  echo -e "\t[PROVISION_BENCH_NODES]: Done"
}


provisionAntidote () {
  echo -e "\t[PROVISION_ANTIDOTE_NODES]: Starting... (This may take a while)"

  local ts=$1
  local command="\
    rm -rf antidote && \
    git clone ${ANTIDOTE_URL} --branch ${ANTIDOTE_BRANCH} --single-branch antidote && \
    cd antidote && \
    make relnocert
  "
  doForNodesIn ${ALL_NODES} "${command}" \
    >> "${LOGDIR}/antidote-compile-and-config-job${ts}" 2>&1

  echo -e "\t[PROVISION_ANTIDOTE_NODES]: Done"
}


rebuildAntidote () {
  echo -e "\t[REBUILD_ANTIDOTE]: Starting..."

  local ts=$1
  local command="\
    cd antidote; \
    pkill beam; \
    sed -i.bak 's/127.0.0.1/localhost/g' rel/vars/dev_vars.config.src rel/files/app.config; \
    sed -i.bak 's/127.0.0.1/localhost/g' config/vars.config; \
    rm -rf deps; mkdir deps; \
    make clean; make relnocert
  "
  # We use the IPs here so that we can change the default (127.0.0.1)
  doForNodesIn ${ANT_IPS} "${command}" \
    >> "${LOGDIR}/config-antidote-${ts}" 2>&1

  echo -e "\t[REBUILD_ANTIDOTE]: Done"
}

cleanAntidote () {
  echo -e "\t[CLEAN_ANTIDOTE]: Starting..."

  local ts=$1
  local command="\
    cd antidote; \
    pkill beam; \
    make clean; \
    make relnocert
  "
  doForNodesIn ${ANT_IPS} "${command}" \
    >> ${LOGDIR}/clean-antidote-${ts} 2>&1

  echo -e "\t[CLEAN_ANTIDOTE]: Done"
}


# Provision all the nodes with Antidote and Basho Bench
provisionNodes () {
  local ts=$1

  provisionAntidote ${ts}
  provisionBench ${ts}
}


# Creates unique erlang cookies for all basho_bench and antidote nodes.
# All nodes of the same type inside the same datacenter hold the same cookie.
createCookies () {
  echo -e "\t[CREATE_COOKIES]: Starting..."

  local total_dcs=$1

  [[ -f ${ALL_COOKIES} ]] && rm ${ALL_COOKIES}
  [[ -f ${ANT_COOKIES} ]] && rm ${ANT_COOKIES}
  [[ -f ${BENCH_COOKIES} ]] && rm ${BENCH_COOKIES}

  for n in $(seq 1 ${total_dcs}); do
    # In each datacenter, all antidote nodes must have the same cookie
    for _ in $(seq 1 ${ANTIDOTE_NODES}); do
      echo "dccookie${n}" | tee -a ${ALL_COOKIES} >> ${ANT_COOKIES}
    done

    # In each datacenter, all basho_bench nodes must have the same cookie
    for _ in $(seq 1 ${BENCH_NODES}); do
      echo "dccookie${n}" | tee -a ${ALL_COOKIES} >> ${BENCH_COOKIES}
    done

  done

  echo -e "\t[CREATE_COOKIES]: Done"
}


# TODO: Really necessary? How do we distribute them?
# Send erlang cookies to the appropiate antidote nodes.
distributeCookies () {
  echo -e "\t[DISTRIBUTE_COOKIES]: Starting..."

  local ts=$1
  local cookie_array=($(cat ${ALL_COOKIES}))
  local cookie_dev_config="antidote/rel/vars/dev_vars.config.src"
  local cookie_config="antidote/config/vars.config"

  local c=0
  while read node; do
    local cookie=${cookie_array[$c]}
    local command="sed -i.bak 's|^{cookie.*|{cookie, ${cookie}}.|g' ${cookie_config} ${cookie_dev_config}"
    ssh -i ${EXPERIMENT_PRIVATE_KEY} -T \
        -o ConnectTimeout=3 \
        -o StrictHostKeyChecking=no root@${node} "${command}"
    c=$((c + 1))
  done < ${ANT_IPS}

  echo -e "\t[DISTRIBUTE_COOKIES]: Done"
}

setupTests () {
  echo "[SETUP_TESTS]: Starting..."

  local dc_size=$1
  ./change-partition-size.sh ${dc_size}

  echo "[SETUP_TESTS]: Done"
}

runTests () {
  local dc_size=$1
  local total_dcs=$2
  echo "[RUNNING_TEST]: Starting..."
  ./prepare-clusters.sh ${dc_size} ${total_dcs}
  echo "[RUNNING_TEST]: Done"
}


# Prepare the experiment, create the output folder,
# logs and key pairs.
setupScript () {
  echo "[SETUP_KEYS]: Starting..."

  mkdir -p ${SCRATCHFOLDER}
  mkdir -p ${LOGDIR}
  cp ${PRKFILE} ${EXPERIMENT_PRIVATE_KEY}
  cp ${PBKFILE} ${EXPERIMENT_PUBLIC_KEY}

  echo "[SETUP_KEYS]: Done"
}


# Gather information about all the deployed machines, like
# node names and IPs, and split them into antidote and basho_bench
# nodes. If selected, it will also go ahead and deploy the k3 image
# into the nodes.
setupCluster () {
  gatherMachines
  if [[ "${DEPLOY_IMAGE}" == "true" ]]; then
    echo "[DEPLOY_IMAGE]: Starting..."
    kadeployNodes
    echo "[DEPLOY_IMAGE]: Done"
  else
    echo "[DEPLOY_IMAGE]: Skipping"
  fi
}

# Provision the nodes with the appropiate versions of antidote and
# basho_bench.
# Also create and distribute the erlang cookies to all nodes.
configCluster () {
  local ts=$1
  local total_dcs=$2

  if [[ "${PROVISION_IMAGES}" == "true" ]]; then
    echo "[PROVISION_NODES]: Starting..."
    provisionNodes ${ts}
    echo "[PROVISION_NODES]: Done"
  else
    echo "[PROVISION_NODES]: Skipping"
  fi

  if [[ "${CLEAN_RUN}" == "true" ]]; then
    echo "[CLEAN_RUN]: Starting..."
    rebuildAntidote ${ts}
    createCookies ${total_dcs}
    distributeCookies ${ts}
    echo "[CLEAN_RUN]: Done"
  else
    cleanAntidote ${ts}
  fi
}


run () {
  setupScript
  setupCluster

  local timestamp=$(date +"%Y-%m-%d-%s")
  local total_dcs=$(getTotalDCCount)
  local dc_size=$(getDCSize)
  configCluster ${timestamp} ${total_dcs}

  setupTests "${dc_size}"

  ./sync-time.sh --start
  runTests "${dc_size}" "${total_dcs}"
  ./sync-time.sh --stop
}

run
