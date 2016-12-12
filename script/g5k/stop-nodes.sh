#!/usr/bin/env bash

set -eo pipefail

stopNodes () {
  local command="\
    ./control-nodes-remote.sh stop; \
    pkill beam; \
    rm -rf antidote/_build/default/rel/antidote/data/*; \
    rm -rf antidote/_build/default/rel/antidote/log/*; \
    ./control-nodes-remote.sh stop
  "
  ./execute-in-nodes.sh "$(cat ${ANT_NODES})" "${command}" "-debug"
}

stopNodes
