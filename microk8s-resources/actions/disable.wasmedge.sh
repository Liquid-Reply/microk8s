#!/usr/bin/env bash

set -e

source $SNAP/actions/common/utils.sh

echo "Switching OCI runtime back to default"

cp $SNAP/microk8s-resources/default-args/containerd-template.toml $SNAP_DATA/args/containerd-template.toml

restart_service containerd