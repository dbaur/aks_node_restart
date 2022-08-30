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
nodes=''

function print_usage() {
  echo "Usage: $0 [<options>]"
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
    status=$(kubectl get node $node -o "jsonpath={.status.conditions[?(.reason==\"$reason\")].type}")
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
  vmss=$(kubectl get node $1 -o json | jq -r '.spec.providerID | . |= split("/")[10]' | sort -u)
  echo $vmss
}

function get_instance_id_for_node() {
  node=$1
  id=$(kubectl get node $1 -o json | jq -r '.spec.providerID | . |= split("/")[12]' | sort -u)
  echo $id
}

function restart_node() {
  node=$1
  vmss=$(get_vmss_for_node "$node")
  id=$(get_instance_id_for_node "$node")

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
