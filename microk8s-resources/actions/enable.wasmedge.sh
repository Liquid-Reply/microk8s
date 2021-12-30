#!/usr/bin/env bash

set -e

source $SNAP/actions/common/utils.sh

echo "Switching OCI runtime to crun with WasmEdge support"

#TODO: find a way to make ${RUNTIME} configurable
sed 's/default_runtime_name = \"\${RUNTIME}\"/default_runtime_name = \"crun\"/g' $SNAP/microk8s-resources/default-args/containerd-template.toml > $SNAP_DATA/args/containerd-template.toml

restart_service containerd