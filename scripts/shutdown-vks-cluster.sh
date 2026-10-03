#!/usr/bin/env bash
set -euo pipefail

# Scales the cluster's control plane down to 1 replica, waits for that to
# settle, pauses the Cluster, then powers off all VMs backing the
# cluster's Machines via govc (control-plane VM first, then workers).
#
# Before powering off, each VM is paused via VM Operator's admin pause
# mechanism: setting the ExtraConfig key "vmservice.virtualmachine.pause"
# to "true" directly on the vCenter VM. VM Operator's reconcilePowerState
# checks this (paused.ByAdmin) and skips power state reconciliation for
# paused VMs, so the power-off sticks without needing to touch Kubernetes
# at all (no ownership webhook involved, no need to scale down
# vmware-system-vmop-controller-manager).
#
# Before touching the control plane, all worker nodes are cordoned (all of
# them, up front) and then drained. Cordoning everything first prevents
# pods evicted from one worker being rescheduled onto another worker that
# is about to be drained anyway.
#
# Required env vars:
#   KUBECONFIG          - path to kubeconfig for the Supervisor cluster
#                        (used for the Cluster/Machine/KubeadmControlPlane
#                        resources)
#   WORKLOAD_KUBECONFIG - path to kubeconfig for the workload cluster itself
#                        (used for cordon/drain, which act on Node objects
#                        inside the workload cluster, not the Supervisor)
#   KUBENAMESPACE       - namespace the Cluster/Machines live in (Supervisor)
#   GOVC_URL / GOVC_USERNAME / GOVC_PASSWORD (and GOVC_INSECURE, if needed)
#     - standard govc connection env vars
#   GOVC_DATACENTER - required if the vCenter has more than one datacenter
#
# Usage: ./shutdown-vks-cluster.sh <cluster-name>
#
# To restart, use restart-vks-cluster.sh.

CONTROL_PLANE_WAIT_TIMEOUT_SECS=600
CONTROL_PLANE_POLL_INTERVAL_SECS=10

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <cluster-name>" >&2
  exit 1
fi

CLUSTER_NAME="$1"

# Verifies every required env var is set, and that it's actually usable
# (not just non-empty) - e.g. this is what catches a vCenter with multiple
# datacenters needing GOVC_DATACENTER, before any cordon/drain/scale/pause
# has happened, instead of failing on the first govc call partway through.
check_env() {
  local missing=0
  for var in KUBECONFIG WORKLOAD_KUBECONFIG KUBENAMESPACE GOVC_URL GOVC_USERNAME GOVC_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      echo "Required environment variable ${var} is not set" >&2
      missing=1
    fi
  done
  if [[ "$missing" -eq 1 ]]; then
    exit 1
  fi

  echo "Verifying access to the Supervisor cluster (\$KUBECONFIG)..."
  if ! kubectl get namespace "$KUBENAMESPACE" >/dev/null; then
    echo "Could not access namespace '${KUBENAMESPACE}' on the Supervisor cluster using \$KUBECONFIG" >&2
    exit 1
  fi

  echo "Verifying access to the workload cluster (\$WORKLOAD_KUBECONFIG)..."
  if ! KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get nodes >/dev/null; then
    echo "Could not access the workload cluster using \$WORKLOAD_KUBECONFIG" >&2
    exit 1
  fi

  echo "Verifying govc connectivity to vCenter..."
  if ! govc about >/dev/null; then
    echo "Could not connect to vCenter - check GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD, GOVC_INSECURE" >&2
    exit 1
  fi

  local dc_err
  if ! dc_err=$(govc datacenter.info 2>&1 >/dev/null); then
    echo "Could not retrieve datacenters: ${dc_err}" >&2
    exit 1
  fi
  if [[ ( ! -v GOVC_DATACENTER ) && $(govc datacenter.info -json | jq '.datacenters | length') -gt 1 ]]; then
    echo "Multiple datacenters found, set GOVC_DATACENTER to one of the following" >&2
    govc datacenter.info -json | jq -r '.datacenters | map(.name) | .[]' >&2
    exit 1
  fi
}

check_env

# Refuses to start if any node is unhealthy or CAPI is already mid
# upgrade/scale - cordoning/draining/scaling down on top of an existing
# operation is exactly the kind of overlapping-change scenario this whole
# procedure is designed to avoid.
check_no_operations_in_progress() {
  echo "Verifying all nodes are healthy and no cluster operations are in progress..."

  if ! KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait --for=condition=Ready node --all --timeout=10s >/dev/null; then
    echo "Not all nodes are healthy - aborting" >&2
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get nodes >&2
    exit 1
  fi

  local in_progress
  in_progress=$(
    kubectl get cluster "$CLUSTER_NAME" -n "$KUBENAMESPACE" -o json \
      | jq -r '[.status.conditions[] | select(.type=="RollingOut" or .type=="ScalingUp" or .type=="ScalingDown" or .type=="Remediating") | select(.status=="True") | .type] | join(", ")'
  )

  if [[ -n "$in_progress" ]]; then
    echo "Cluster ${CLUSTER_NAME} has operation(s) in progress (${in_progress}) - aborting" >&2
    exit 1
  fi
  local addons_reconciled
  addons_reconciled=$(
    kubectl get cluster "$CLUSTER_NAME" -n "$KUBENAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type == "AddonsReconciled")].status}')
  if [[ "$addons_reconciled" != "True" ]]; then
    echo "Addons are not reconciled for cluster ${CLUSTER_NAME} - aborting" >&2
    exit 1
  fi
}

check_no_operations_in_progress

cordon_and_drain_workers() {
  echo "Cordoning all worker nodes for ${CLUSTER_NAME}..."
  local worker_nodes
  worker_nodes=$(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name)

  if [[ -z "$worker_nodes" ]]; then
    echo "No worker nodes found to cordon/drain" >&2
    return
  fi

  # shellcheck disable=SC2086
  KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl cordon $worker_nodes

  echo "Draining all worker nodes for ${CLUSTER_NAME}..."
  echo "$worker_nodes" | xargs -I{} env KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl drain {} --ignore-daemonsets --delete-emptydir-data --force
}

cordon_and_drain_workers

echo "Scaling control plane for ${CLUSTER_NAME} to 1 replica..."
kubectl patch cluster "$CLUSTER_NAME" -n "$KUBENAMESPACE" \
  --type='json' -p='[{"op": "replace", "path": "/spec/topology/controlPlane/replicas", "value": 1}]'

KCP_NAME=$(
  kubectl get kubeadmcontrolplane -n "$KUBENAMESPACE" \
    -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" \
    -o jsonpath='{.items[0].metadata.name}'
)

if [[ -z "$KCP_NAME" ]]; then
  echo "Could not find KubeadmControlPlane for cluster '${CLUSTER_NAME}' in namespace '${KUBENAMESPACE}'" >&2
  exit 1
fi

echo "Waiting for KubeadmControlPlane ${KCP_NAME} to scale down to 1 replica..."
elapsed=0
while true; do
  current_total=$(
    kubectl get kubeadmcontrolplane "$KCP_NAME" -n "$KUBENAMESPACE" \
      -o jsonpath='{.status.replicas}'
  )

  # Wait for replicas (total Machine count) to hit 1 - this confirms the
  # excess Machine has been FULLY deleted, not just marked unready.
  # Powering off a VM via govc while CAPI is still gracefully tearing it
  # down (including removing it as an etcd member) can interrupt that
  # removal and leave a stale etcd member behind.
  if [[ "$current_total" == "1" ]]; then
    echo "Control plane scaled down to 1 replica (excess machine fully deleted)."
    break
  fi

  if (( elapsed >= CONTROL_PLANE_WAIT_TIMEOUT_SECS )); then
    echo "Timed out waiting for control plane to scale down (total replicas: ${current_total})" >&2
    exit 1
  fi

  sleep "$CONTROL_PLANE_POLL_INTERVAL_SECS"
  elapsed=$(( elapsed + CONTROL_PLANE_POLL_INTERVAL_SECS ))
done

# Separately confirm the surviving node is actually healthy before we shut
# it down - checked directly against the Node object, not via KCP's
# readyReplicas (that field is easy to mix up with the replicas check
# above, and substituting it for replicas is exactly what caused the
# earlier etcd-corruption incident).
echo "Verifying all nodes are healthy before powering off..."
if ! KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait --for=condition=Ready node --all --timeout=60s >/dev/null; then
  echo "Not all nodes are healthy after scaling down - aborting" >&2
  KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get nodes >&2
  exit 1
fi

echo "Pausing cluster ${CLUSTER_NAME}..."
kubectl patch cluster "$CLUSTER_NAME" -n "$KUBENAMESPACE" \
  --type='json' -p='[{"op": "replace", "path": "/spec/paused", "value": true}]'

# shellcheck disable=SC2034  # out_ref is a nameref: assignment writes to the caller's array
get_provider_ids_array() {
  local selector="$1"
  local -n out_ref=$2
  local raw

  if ! raw=$(
    kubectl get machines -n "$KUBENAMESPACE" \
      -l "$selector" \
      -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}'
  ); then
    echo "Failed to query machines with selector '${selector}'" >&2
    exit 1
  fi

  out_ref=()
  if [[ -n "$raw" ]]; then
    mapfile -t out_ref <<< "$raw"
  fi
}

pause_and_poweroff_vms() {
  local -n ids_ref=$1

  for provider_id in "${ids_ref[@]}"; do
    if [[ -z "$provider_id" ]]; then
      echo "Skipping machine with empty providerID" >&2
      continue
    fi

    uuid="${provider_id#vsphere://}"
    echo "Pausing VM Operator reconciliation for VM with UUID ${uuid}..."
    govc vm.change -vm.uuid="$uuid" -e vmservice.virtualmachine.pause=true

    # Soft (guest OS) shutdown via VMware Tools, not a hard power-off.
    # No -force: this must fail rather than silently falling back to a hard shutdown.
    echo "Shutting down VM with UUID ${uuid} (soft/guest shutdown)..."
    govc vm.power -s -vm.uuid="$uuid"

    echo "Waiting for VM with UUID ${uuid} to report poweredOff..."
    local elapsed=0
    while true; do
      local state
      state=$(govc vm.info -vm.uuid="$uuid" -json | jq -r '.virtualMachines[0].runtime.powerState')

      if [[ "$state" == "poweredOff" ]]; then
        break
      fi

      if (( elapsed >= CONTROL_PLANE_WAIT_TIMEOUT_SECS )); then
        echo "Timed out waiting for VM with UUID ${uuid} to shut down (state: ${state})" >&2
        exit 1
      fi

      sleep "$CONTROL_PLANE_POLL_INTERVAL_SECS"
      elapsed=$(( elapsed + CONTROL_PLANE_POLL_INTERVAL_SECS ))
    done
  done
}

get_provider_ids_array \
  "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME},cluster.x-k8s.io/control-plane" \
  CONTROL_PLANE_PROVIDER_IDS
get_provider_ids_array \
  "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME},!cluster.x-k8s.io/control-plane" \
  WORKER_PROVIDER_IDS

if [[ ${#CONTROL_PLANE_PROVIDER_IDS[@]} -eq 0 && ${#WORKER_PROVIDER_IDS[@]} -eq 0 ]]; then
  echo "No machines found for cluster '${CLUSTER_NAME}' in namespace '${KUBENAMESPACE}'" >&2
  exit 1
fi

echo "Powering off control-plane VM(s)..."
pause_and_poweroff_vms CONTROL_PLANE_PROVIDER_IDS

echo "Powering off worker VMs..."
pause_and_poweroff_vms WORKER_PROVIDER_IDS
