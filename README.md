# Script restarting all nodes in an AKS cluster (Virtual Machine Scale Sets)

A simple bash scripts that deallocates and starts all virtual machines that are represented as nodes
within the cluster.

## Usage

```
Usage: ./node_restart.sh [<options>]

-n|--node <node>                    The name of a node to restart.
                                    By default, a rolling restart of all nodes
                                    is performed.

--resource-group <group-name>       The resource group of the cluster.
                                    Can also be set by RESOURCE_GROUP
                                    Default: <set your default here, to avoid having to specify in the common case>

--cluster-name <cluster-name>       The name of the cluster.
                                    Can also be set by CLUSTER_NAME
                                    Default: <set your default here>

--region <azure-region>             The Azure region in which the cluster is.
                                    Can also be set by REGION
                                    Default: <set your default here>

-f|--force                          Restart node(s) without first draining.
                                    Useful if draining a node fails.

-d|--dry-run                        Just print what to do; don't actually do it


-r|--restart                        Only restart (instead of deallocate/start)

-h|--help                           Print usage and exit.
```

## Thanks

Heavily based on this [script](https://gist.github.com/tomasaschan/9dbc9180d313ad8cae57f62ce229610b).