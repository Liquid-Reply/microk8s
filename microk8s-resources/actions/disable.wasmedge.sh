#!/usr/bin/env bash

set -e

source $SNAP/actions/common/utils.sh

echo "Disable WasmEdge"

echo "$SNAP_DATA/args/containerd-template.toml"

#TODO: find a way to make ${RUNTIME} configurable
#sed -i s/crun/runc/g "$SNAP_DATA/args/containerd-template.toml"
sed -i s/\${RUNTIME}/runc/g "$SNAP_DATA/args/containerd-template.toml"

restart_service containerd