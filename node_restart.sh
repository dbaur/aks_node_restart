#!/usr/bin/env bash

set -e

resourceGroupDefault='<set your default here, to avoid having to specify in the common case>'
resourceGroup=${RESOURCE_GROUP:-$resourceGroupDefault}
clusterNameDefault='<set your default here>'
clusterName=${CLUSTER_NAME:-$clusterNameDefault}
regionDefault='<set your default here>'
region=${REGION:-$regionDefault}
force=false
dryrun=false
restart=false
nodes=''

function echoerr() { echo "$@" 1>&2; }

function print_usage() {
  echo "Usage: $0 [<options>]"
  echo ""
  echo "-n|--node <node>                    The name of a node to restart."
  echo "                                    By default, a rolling restart of all nodes"
  echo "                                    is performed."
  echo ""
  echo "--resource-group <group-name>       The resource group of the cluster."
  echo "                                    Can also be set by RESOURCE_GROUP"
  echo "                                    Default: $resourceGroupDefault"
  echo ""
  echo "--cluster-name <cluster-name>       The name of the cluster."
  echo "                                    Can also be set by CLUSTER_NAME"
  echo "                                    Default: $clusterNameDefault"
  echo ""
  echo "--region <azure-region>             The Azure region in which the cluster is."
  echo "                                    Can also be set by REGION"
  echo "                                    Default: $regionDefault"
  echo ""
  echo "-f|--force                          Restart node(s) without first draining."
  echo "                                    Useful if draining a node fails."
  echo ""
  echo "-d|--dry-run                        Just print what to do; don't actually do it"
  echo ""
  echo "-h|--help                           Print usage and exit."
}

while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
  -n | --node)
    node="$2"
    shift
    shift
    ;;
  --resource-group)
    resourceGroup="$2"
    shift
    shift
    ;;
  --cluster-name)
    clusterName="$2"
    shift
    shift
    ;;
  --region)
    region="$2"
    shift
    shift
    ;;
  -f | --force)
    force=true
    shift
    ;;
  --dry-run)
    dryrun=true
    shift
    ;;
  --restart-only)
    restart=true
    shift
    ;;
  -h | --help)
    print_usage
    exit 0
    ;;
  *)
    print_usage
    exit 1
    ;;
  esac
done

group="MC_${resourceGroup}_${clusterName}_$region"

function wait_for_status() {
  node=$1
  reason=$2
  i=0
  while [[ $i -lt 60 ]]; do
    status=$(kubectl get node "$node" -o "jsonpath={.status.conditions[?(.reason==\"$reason\")].type}")
    if [[ "$status" == "Ready" ]]; then
      echo "$reason after $((i * 2)) seconds"
      break
    else
      sleep 2s
      i=$(($i + 1))
    fi
  done
  if [[ $i == 30 ]]; then
    echo "Error: Did not reach $reason state within 2 minutes"
    exit 1
  fi
}

function get_vmss_for_node() {
  node=$1

  # we need to check if provider id is set due to bug https://github.com/kubernetes-sigs/cloud-provider-azure/issues/1155
  providerId=$(kubectl get node "$node" -o json | jq -r '.spec.providerID // empty')

  if [[ -z "$providerId" ]]; then
    return 0
  fi

  vmss=$(kubectl get node "$node" -o json | jq -r '.spec.providerID | . |= split("/")[10]' | sort -u)
  echo $vmss
}

function get_instance_id_for_node() {
  node=$1
  id=$(kubectl get node "$node" -o json | jq -r '.spec.providerID | . |= split("/")[12]' | sort -u)
  echo $id
}

function restart_node() {
  node=$1
  vmss=$(get_vmss_for_node "$node")

  YELLOW='\033[1;33m'
  NC='\033[0m' # No Color

  if [[ -z "$vmss" ]]; then
    echo -e "${YELLOW}Warning:${NC} Skipping restart of node $node as it has no ProviderID set (Azure issue - https://github.com/kubernetes-sigs/cloud-provider-azure/issues/1155)"
    return 0
  fi

  id=$(get_instance_id_for_node "$node")

  if $restart; then
    echo "Restarting VM $node"
    if $dryrun; then
      echo "az vmss restart -g $group -n $vmss --instance-ids $id"
    else
      az vmss restart -g "$group" -n "$vmss" --instance-ids "$id"
    fi
  else
    echo "Deallocating VM $node"
    if $dryrun; then
      echo "az vmss deallocate -g $group -n $vmss --instance-ids $id"
    else
      az vmss deallocate -g "$group" -n "$vmss" --instance-ids "$id"
    fi

    echo "Starting VM $node"
    if $dryrun; then
      echo "az vmss start -g $group -n $vmss --instance-ids $id"
    else
      az vmss start -g "$group" -n "$vmss" --instance-ids "$id"
    fi
  fi

}

if [ -z "$node" ]; then
  nodes=$(kubectl get nodes -o jsonpath={.items[*].metadata.name})
else
  nodes="$node"
fi

for node in $nodes; do
  if $force; then
    echo "WARNING: --force specified, restarting node $node without draining first"
    if $dryrun; then
      echo "kubectl cordon $node"
    else
      kubectl cordon "$node"
    fi
  else
    echo "Draining $node..."
    if $dryrun; then
      echo "kubectl drain $node --ignore-daemonsets --delete-emptydir-data"
    else
      kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data
    fi
  fi

  echo "Initiating VM restart for $node..."
  restart_node "$node"

  if ! $dryrun; then
    echo "Waiting for $node to start back up..."
    wait_for_status "$node" KubeletReady
  fi

  echo "Re-enabling $node for scheduling"

  if $dryrun; then
    echo "kubectl uncordon $node"
  else
    kubectl uncordon "$node"
  fi
done
