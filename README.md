# k8scluster
scripts to build a kubernetes cluster.

clone the repo to each of the nodes in the cluster. 

update the env.yaml file with the correct values for the cluster. Each node (this is designed for a 3 node cluster) should be included. With one node listed as "MASTER" with a priority of 101, and the other nodes as "BACKUP" with a priority of 100. The IP addresses should match the IP address each of the hosts. 

Also add an unused IP address to be used for the load balanced api server. This API server is required for the cluster to correctly run. The easiest option is to use an IP address in the same range as the hosts. The api server listens on port 6443 on each of the hosts, so the load balanced api server needs to listed on another port to avoid port conflicts. In this configuration port 8443 is used, but you can select another port. Note, that only the hosts will actually connect to this port. 

## deploying 
make sure all the scripts are executable. 

### step 1: 
run on each host. 

```
00_deploy_prereqs.sh   # deploy required components and kubernetes
```
### step 2:

run on each host, select the correct server from the list when given the option. This ensures the configuration files match the host you are executing this on.  
```
01_update_files.sh   # update the configuration files to match the correct host
```

### step 3: 
run the following script on the primary node. This is the same host you selected as "MASTER". Let everything complete and check the cluster date to ensure this node is active. 

Run
```
kubectl get nodes
```
the node must be listed as action before you proceed to the subsequent servers.

### step 4:
Do this after everything on the primary node has completed. 
No run the following script to complete the setup on each of the additional nodes. Do this one node at a time. 
