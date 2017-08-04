# digitalocean-kubernetes-provider

## Use
Clone into `kubernetes/cluster` as `digitalocean`, to use the (deprecated) kube-up.sh script, in your existing <a href="https://github.com/kubernetes/kubernetes">Kubernetes repo</a>.

## Setup

Before running, set the following variables

```bash
  export KUBERNETES_PROVIDER=digitalocean 
  export SSH_KEY_NAME="YOUR_KEY_FILENAME" (i.e. for ~/.ssh/your_key.pub, you'd enter your_key.pub, or the name as it appears in your DigitalOcean account if it already exists)
  export DO_REGION=sfo2
  export MASTER_SIZE=4gb (or whatever size you'd like)
  export NODE_SIZE=c-4 (or whatever size your workers should be; c-4 is, for example, a high CPU size)
  export DO_CERTS=true 
  export KUBE_VERSION=<Desired Kubernetes version>
 ```
This also requires that the `doctl` tool be installed on your client machine:

https://github.com/digitalocean/doctl

## Deploying

```
export KUBERNETES_PROVIDER=digitalocean; ./cluster/kube-up.sh
```

## Serving the K8s package from the local network

If, for some reason, you do not want the package pulled down directly from Google, you can use this script to service the
packages from Minio on a DigitalOcean droplet that is created and torn down during the kube-up run.

You can enable this by uncommenting this section of the kube-up.sh script:

https://github.com/jmarhee/kubernetes/blob/digitalocean_provider/cluster/digitalocean/util.sh#L41-L93

and enabling the function during the kube-up() portion of the script. 
