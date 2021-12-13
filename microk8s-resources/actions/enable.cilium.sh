#!/usr/bin/env bash

set -e

source $SNAP/actions/common/utils.sh

ARCH=$(arch)
if ! [ "${ARCH}" = "amd64" ]; then
  echo "Cilium is not available for ${ARCH}" >&2
  exit 1
fi

"$SNAP/microk8s-enable.wrapper" helm3

echo "Restarting kube-apiserver"
refresh_opt_in_config "allow-privileged" "true" kube-apiserver
restart_service apiserver

# Reconfigure kubelet/containerd to pick up the new CNI config and binary.
echo "Restarting kubelet"
refresh_opt_in_config "cni-bin-dir" "\${SNAP_DATA}/opt/cni/bin/" kubelet
restart_service kubelet

set_service_not_expected_to_start flanneld
snapctl stop "${SNAP_NAME}.daemon-flanneld"
remove_vxlan_interfaces

if grep -qE "bin_dir.*SNAP}\/" $SNAP_DATA/args/containerd-template.toml; then
  echo "Restarting containerd"
  "${SNAP}/bin/sed" -i 's;bin_dir = "${SNAP}/opt;bin_dir = "${SNAP_DATA}/opt;g' "$SNAP_DATA/args/containerd-template.toml"
  snapctl restart "${SNAP_NAME}.daemon-containerd"
fi

echo "Enabling Cilium"

read -ra CILIUM_VERSION <<< "$1"
if [ -z "$CILIUM_VERSION" ]; then
  CILIUM_VERSION="v1.10"
fi
CILIUM_ERSION=$(echo $CILIUM_VERSION | sed 's/v//g')

if [ -f "${SNAP_DATA}/bin/cilium-$CILIUM_ERSION" ]
then
  echo "Cilium version $CILIUM_VERSION is already installed."
else
  CILIUM_DIR="cilium-$CILIUM_ERSION"
  SOURCE_URI="https://github.com/cilium/cilium/archive"
  CILIUM_CNI_CONF="plugins/cilium-cni/05-cilium-cni.conf"
  CILIUM_LABELS="k8s-app=cilium"
  NAMESPACE=kube-system

  echo "Fetching cilium version $CILIUM_VERSION."
  mkdir -p "/tmp/cilium"
  (cd "/tmp/cilium"
  curl -L $SOURCE_URI/$CILIUM_VERSION.tar.gz -o "/tmp/cilium/cilium.tar.gz"
  if ! gzip -f -d "/tmp/cilium/cilium.tar.gz"; then
    echo "Invalid version \"$CILIUM_VERSION\". Must be a branch on https://github.com/cilium/cilium."
    exit 1
  fi
  tar -xf "/tmp/cilium/cilium.tar" "$CILIUM_DIR/install" "$CILIUM_DIR/$CILIUM_CNI_CONF" --no-same-owner)

  mv "$SNAP_DATA/args/cni-network/cni.conf" "$SNAP_DATA/args/cni-network/10-kubenet.conf" 2>/dev/null || true
  mv "$SNAP_DATA/args/cni-network/flannel.conflist" "$SNAP_DATA/args/cni-network/20-flanneld.conflist" 2>/dev/null || true
  cp "/tmp/cilium/$CILIUM_DIR/$CILIUM_CNI_CONF" "$SNAP_DATA/args/cni-network/05-cilium-cni.conf"

  mkdir -p "$SNAP_DATA/actions/cilium/"

  # Generate the YAMLs for Cilium and apply them
  (cd "/tmp/cilium/$CILIUM_DIR/install/kubernetes"
  ${SNAP_DATA}/bin/helm3 template cilium \
      --namespace $NAMESPACE \
      --set cni.confPath="$SNAP_DATA/args/cni-network" \
      --set cni.binPath="$SNAP_DATA/opt/cni/bin" \
      --set cni.customConf=true \
      --set containerRuntime.integration="containerd" \
      --set global.containerRuntime.socketPath="$SNAP_COMMON/run/containerd.sock" \
      --set daemon.runPath="$SNAP_DATA/var/run/cilium" \
      --set operator.replicas=1 \
      --set keepDeprecatedLabels=true \
      | tee "$SNAP_DATA/actions/cilium.yaml" >/dev/null)

  ${SNAP}/microk8s-status.wrapper --wait-ready >/dev/null
  echo "Deploying $SNAP_DATA/actions/cilium.yaml. This may take several minutes."
  "$SNAP/kubectl" "--kubeconfig=$SNAP_DATA/credentials/client.config" apply -f "$SNAP_DATA/actions/cilium.yaml"
  "$SNAP/kubectl" "--kubeconfig=$SNAP_DATA/credentials/client.config" -n $NAMESPACE rollout status ds/cilium

  if [ -e "$SNAP_DATA/args/cni-network/cni.yaml" ]
  then
    "$SNAP/kubectl" "--kubeconfig=$SNAP_DATA/credentials/client.config" delete -f "$SNAP_DATA/args/cni-network/cni.yaml"
    # give a bit slack before moving the file out, sometimes it gives out this error "rpc error: code = Unknown desc = checkpoint in progress".
    sleep 2s
    mv "$SNAP_DATA/args/cni-network/cni.yaml" "$SNAP_DATA/args/cni-network/cni.yaml.disabled"
  fi

  # Fetch the Cilium CLI binary and install
  CILIUM_POD=$("$SNAP/kubectl" "--kubeconfig=$SNAP_DATA/credentials/client.config" -n $NAMESPACE get pod -l $CILIUM_LABELS -o jsonpath="{.items[0].metadata.name}")
  CILIUM_BIN=$(mktemp)
  "$SNAP/kubectl" "--kubeconfig=$SNAP_DATA/credentials/client.config" -n $NAMESPACE cp $CILIUM_POD:/usr/bin/cilium $CILIUM_BIN >/dev/null
  mkdir -p "$SNAP_DATA/bin/"
  mv $CILIUM_BIN "$SNAP_DATA/bin/cilium-$CILIUM_ERSION"
  chmod +x "$SNAP_DATA/bin/"
  chmod +x "$SNAP_DATA/bin/cilium-$CILIUM_ERSION"
  ln -s $SNAP_DATA/bin/cilium-$CILIUM_ERSION $SNAP_DATA/bin/cilium

  rm -rf "/tmp/cilium"
fi

echo "Cilium is enabled"
