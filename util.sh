#!/bin/bash

KUBE_ROOT=$(dirname "${BASH_SOURCE}")/../..
source $(dirname ${BASH_SOURCE})/${KUBE_CONFIG_FILE-"config-default.sh"}
source "${KUBE_ROOT}/cluster/common.sh"
source "${KUBE_ROOT}/cluster/digitalocean/authorization.sh"

verify-prereqs() {
  # Make sure that prerequisites are installed.
  for x in doctl openssl; do
    if [ "$(which $x)" == "" ]; then
      echo "cluster/digitalocean/util.sh:  Can't find $x in PATH, please fix and retry."
      exit 1
    fi
  done

  if [[ -z "${DO_REGION}" ]]; then
    echo "cluster/digitalocean/util.sh: DO_REGION not set."
    return 1
  fi

}

do-ssh-key() {
  if [ ! -f $HOME/.ssh/${SSH_KEY_NAME} ]; then
    echo "cluster/digitalocean/util.sh: Generating SSH KEY ${HOME}/.ssh/${SSH_KEY_NAME}"
    ssh-keygen -f ${HOME}/.ssh/${SSH_KEY_NAME} -N '' > /dev/null
  fi

  if ! $(doctl compute ssh-key list | grep $SSH_KEY_NAME > /dev/null 2>&1); then
    echo "cluster/digitalocean/util.sh: Uploading key to DigitalOcean:"
    echo -e "\tdoctl compute ssh-key import ${SSH_KEY_NAME} --public-key-file ${HOME}/.ssh/${SSH_KEY_NAME}.pub"
    doctl compute ssh-key import ${SSH_KEY_NAME} --public-key-file ${HOME}/.ssh/${SSH_KEY_NAME}.pub && \
    SSH_KEY_ID=$(doctl compute ssh-key list | grep ${SSH_KEY_NAME} | awk '{print $1}')
  else
    echo "cluster/digitalocean/util.sh: SSH key ${SSH_KEY_NAME}.pub already uploaded" && \
    SSH_KEY_ID=$(doctl compute ssh-key list | grep ${SSH_KEY_NAME} | awk '{print $1}')
  fi
}

# find-object-url() {
#
#   RELEASE_URL="https://github.com/kubernetes/kubernetes/releases/download/v${KUBE_VERSION}/kubernetes.tar.gz"
#   MINIO_KEY=$(date +%s | sha256sum | base64 | head -c 8 ; echo)
#   MINIO_SECRET=$(date +%s | sha256sum | base64 | head -c 24 ; echo)
#   MINIO_NODE_ID="$(date +%s | sha256sum | base64 | head -c 6 ; echo)"
#
#   echo "=> Provisioning object storage..."
#   sed -e "s|RELEASE_URL|${RELEASE_URL}|" \
#       -e "s|MINIO_KEY|${MINIO_KEY}|" \
#       -e "s|MINIO_SECRET|${MINIO_SECRET}|" \
#       $(dirname $0)/digitalocean/cloud-config/object-storage.sh > $KUBE_TEMP/object-storage.sh
#
#   STORE_ADDR=$(doctl compute droplet create kubernetes-minio-${MINIO_NODE_ID} --size 512mb --image ubuntu-14-04-x64 --ssh-keys ${SSH_KEY_ID} --region ${DO_REGION} --user-data-file $KUBE_TEMP/object-storage.sh --wait | awk '{print $3}' | tail -n 1) && \
#   STORE_DROPLET_ID=$(doctl compute droplet list | grep minio-kube-source | tail -n 1 | awk '{print $1}') && \
#   #THIS NEEDS TO BE REPLACED BY A CHECK FOR PORT READINESS
#   echo "Allowing Minio setup time to complete..."; sleep 90; echo "Checking readiness..." && \
#   MINIO_ENDPOINT="http://$STORE_ADDR:9000" && \
#   echo "==> Minio Endpoint Created"
#   echo "===> $MINIO_ENDPOINT (${MINIO_KEY}/${MINIO_SECRET})" && \
#   echo "===> Adding server $MINIO_ENDPOINT to minio client" && \
#   mc config host add $MINIO_NODE_ID $MINIO_ENDPOINT $MINIO_KEY $MINIO_SECRET S3v4
#
#   share=$(mc share download $MINIO_NODE_ID/server/kubernetes-server-linux-amd64.tar.gz | grep Share)
#   KUBE_TAR=${share#Share: }
#   echo $share
#
#   urlencode() {
#       # urlencode <string>
#       local length="${#1}"
#       for (( i = 0; i < length; i++ )); do
#           local c="${1:i:1}"
#           case $c in
#               [a-zA-Z0-9.~_-]) printf "$c" ;;
#               *) printf '%%%02X' "'$c"
#           esac
#       done
#   }
#
#   RELEASE_TMP_URL=$KUBE_TAR
#   RELEASE_URL=`urlencode $KUBE_TAR`
#
#   echo "cluster/digitalocean/util.sh: Object temp URL:"
#   echo -e "\t$RELEASE_TMP_URL"
# }
#
# object-store-teardown () {
#
#   echo -e "Deleting droplet $STORE_DROPLET_ID...\n"; \
#   doctl compute droplet delete $STORE_DROPLET_ID && \
#   echo -e "...$STORE_DROPLET_ID deleted.\n"
#
# }

prep_known_tokens() {
  for (( i=0; i<${#NODE_NAMES[@]}; i++)); do
    generate_kubelet_tokens ${NODE_NAMES[i]}
    cat ${KUBE_TEMP}/${NODE_NAMES[i]}_tokens.csv >> ${KUBE_TEMP}/known_tokens.csv
  done

    # Generate tokens for other "service accounts".  Append to known_tokens.
    #
    # NB: If this list ever changes, this script actually has to
    # change to detect the existence of this file, kill any deleted
    # old tokens and add any new tokens (to handle the upgrade case).
    local -r service_accounts=("system:scheduler" "system:controller_manager" "system:logging" "system:monitoring" "system:dns")
    for account in "${service_accounts[@]}"; do
      echo "$(create_token),${account},${account}" >> ${KUBE_TEMP}/known_tokens.csv
    done

  generate_admin_token
}

create-kube-ca () {
  openssl genrsa -out $(dirname $0)/digitalocean/certs/ca-key.pem 2048 && \
  openssl req -x509 -new -nodes -key $(dirname $0)/digitalocean/certs/ca-key.pem -days 10000 -out $(dirname $0)/digitalocean/certs/ca.pem -subj "/CN=kube-ca"
}

create-cluster-tag () {
  CLUSTER_TAG_ID="$(date +%s | sha256sum | base64 | head -c 6 ; echo)"
  echo "Creating tag ID $CLUSTER_TAG_ID..."
  doctl compute tag create kubernetes-$CLUSTER_TAG_ID && \
  echo $CLUSTER_TAG_ID > $(dirname $0)/digitalocean/.last_cluster
}

do-boot-master() {

  DISCOVERY_URL=$(curl --silent https://discovery.etcd.io/new)
  DISCOVERY_ID=$(echo "${DISCOVERY_URL}" | cut -f 4 -d /)
  echo "cluster/digitalocean/util.sh: etcd discovery URL: ${DISCOVERY_URL}"

# Copy cloud-config to KUBE_TEMP and work some sed magic
  sed -e "s|DISCOVERY_ID|${DISCOVERY_ID}|" \
      -e "s|KUBE_VERSION|${KUBE_VERSION}|" \
      -e "s|SERVICE_CLUSTER_IP_RANGE|${SERVICE_CLUSTER_IP_RANGE}|" \
      $(dirname $0)/digitalocean/cloud-config/master-cloud-config.yaml > $KUBE_TEMP/master-cloud-config.yaml

  MASTER_NAME="${INSTANCE_PREFIX}-master"
  MASTER_BOOT_CMD="doctl compute droplet create ${MASTER_NAME}-${CLUSTER_TAG_ID} \
                  --size ${MASTER_SIZE} \
                  --ssh-keys ${SSH_KEY_ID} \
                  --image coreos-stable \
                  --user-data-file ${KUBE_TEMP}/master-cloud-config.yaml \
                  --region ${DO_REGION} \
                  --enable-private-networking \
                  --wait "

  echo "cluster/digitalocean/util.sh: Booting ${MASTER_NAME} with following command:"
  echo -e "\t$MASTER_BOOT_CMD\n"
  KUBE_MASTER_IP=$($MASTER_BOOT_CMD | tail -n 1 | awk '{print $3}')
  echo "Tagging $MASTER_NAME into cluster kubernetes-$CLUSTER_TAG_ID..."
  doctl compute droplet tag $MASTER_NAME-${CLUSTER_TAG_ID} --tag-name kubernetes-$CLUSTER_TAG_ID

  EXT_CLUSTER_RANGE=$(echo $SERVICE_CLUSTER_IP_RANGE | cut -f1 -d"/") && \
  MASTER_CLUSTER_IP=${EXT_CLUSTER_RANGE%?}1
  echo "Generating openssl.cnf for $MASTER_CLUSTER_IP..."
  echo "[req]
  req_extensions = v3_req
  distinguished_name = req_distinguished_name
  [req_distinguished_name]
  [ v3_req ]
  basicConstraints = CA:FALSE
  keyUsage = nonRepudiation, digitalSignature, keyEncipherment
  subjectAltName = @alt_names
  [alt_names]
  DNS.1 = kubernetes
  DNS.2 = kubernetes.default
  DNS.3 = kubernetes.default.svc
  DNS.4 = kubernetes.default.svc.cluster.local
  IP.1 = ${MASTER_CLUSTER_IP}
  IP.2 = ${KUBE_MASTER_IP}
  " > $KUBE_TEMP/openssl.cnf

  if [ $DO_CERTS == true ]; then
    echo "Creating self-signed API Server certs..."
    openssl genrsa -out $(dirname $0)/digitalocean/certs/apiserver-key.pem 2048 && \
    openssl req -new -key $(dirname $0)/digitalocean/certs/apiserver-key.pem -out $(dirname $0)/digitalocean/certs/apiserver.csr -subj "/CN=kube-apiserver" -config $KUBE_TEMP/openssl.cnf && \
    openssl x509 -req -in $(dirname $0)/digitalocean/certs/apiserver.csr -CA $(dirname $0)/digitalocean/certs/ca.pem -CAkey $(dirname $0)/digitalocean/certs/ca-key.pem -CAcreateserial -out $(dirname $0)/digitalocean/certs/apiserver.pem -days 365 -extensions v3_req -extfile $KUBE_TEMP/openssl.cnf
  fi

  if [ $DO_CERTS == false ]; then
    echo "Certificates will not be created; ensure you have your imported apiserver.pem, and apiserver-key.pem in the certs/ directory. "
  fi

}

do-boot-nodes() {

  cp $(dirname $0)/digitalocean/cloud-config/node-cloud-config.yaml \
  ${KUBE_TEMP}/node-cloud-config.yaml

  for (( i=0; i<${#NODE_NAMES[@]}; i++)); do

    get_tokens_from_csv ${NODE_NAMES[i]}

    sed -e "s|DISCOVERY_ID|${DISCOVERY_ID}|" \
        -e "s|KUBE_VERSION|${KUBE_VERSION}|" \
        -e "s|DNS_SERVER_IP|${DNS_SERVER_IP:-}|" \
        -e "s|DNS_DOMAIN|${DNS_DOMAIN:-}|" \
        -e "s|ENABLE_CLUSTER_DNS|${ENABLE_CLUSTER_DNS:-false}|" \
        -e "s|ENABLE_NODE_LOGGING|${ENABLE_NODE_LOGGING:-false}|" \
        -e "s|INDEX|$((i + 1))|g" \
        -e "s|KUBELET_TOKEN|${KUBELET_TOKEN}|" \
        -e "s|KUBE_NETWORK|${KUBE_NETWORK}|" \
        -e "s|KUBELET_TOKEN|${KUBELET_TOKEN}|" \
        -e "s|KUBE_PROXY_TOKEN|${KUBE_PROXY_TOKEN}|" \
        -e "s|LOGGING_DESTINATION|${LOGGING_DESTINATION:-}|" \
    $(dirname $0)/digitalocean/cloud-config/node-cloud-config.yaml > $KUBE_TEMP/node-cloud-config-$(($i + 1)).yaml

    NODE_BOOT_CMD="doctl compute droplet create ${NODE_NAMES[$i]}-${CLUSTER_TAG_ID} \
                    --size ${NODE_SIZE} \
                    --ssh-keys ${SSH_KEY_ID} \
                    --image coreos-stable \
                    --user-data-file ${KUBE_TEMP}/node-cloud-config-$(( i +1 )).yaml \
                    --region ${DO_REGION} \
                    --enable-private-networking \
                    --wait "

    echo "cluster/digitalocean/util.sh: Booting ${NODE_NAMES[$i]} with following command:"
    echo -e "\t$NODE_BOOT_CMD\n"
    $NODE_BOOT_CMD
    echo "Tagging ${NODE_NAMES[$i]} into cluster kubernetes-$CLUSTER_TAG_ID..."
    doctl compute droplet tag ${NODE_NAMES[$i]}-${CLUSTER_TAG_ID} --tag-name kubernetes-$CLUSTER_TAG_ID
  done
}

detect-nodes() {
  KUBE_NODE_IP_ADDRESSES=()
  for (( i=0; i<${#NODE_NAMES[@]}; i++)); do
    local node_ip=$(doctl compute droplet list | grep ${NODE_NAMES[$i]} | awk '{print $3}' | tail -n 1)
    echo "cluster/digitalocean/util.sh: Found ${NODE_NAMES[$i]} at ${node_ip}"
    KUBE_NODE_IP_ADDRESSES+=("${node_ip}")
  done
  if [ -z "$KUBE_NODE_IP_ADDRESSES" ]; then
    echo "cluster/digitalocean/util.sh: Could not detect Kubernetes node nodes.  Make sure you've launched a cluster with 'kube-up.sh'"
    exit 1
  fi

}

detect-master() {
  KUBE_MASTER=${MASTER_NAME}

  echo "Waiting for ${MASTER_NAME} IP Address."
  echo
  echo "  This will continually check to see if the master node has an IP address."
  echo

  KUBE_MASTER_IP=$(doctl compute droplet list | grep ${KUBE_MASTER} | awk '{print $3}' | tail -n 1)

  while [ "${KUBE_MASTER_IP}" == "|" ]; do
    KUBE_MASTER_IP=$(doctl compute droplet list | grep ${KUBE_MASTER} | awk '{print $3}' | tail -n 1)
    printf "."
    sleep 2
  done

  echo "${KUBE_MASTER} IP Address is ${KUBE_MASTER_IP}"
}

# $1 should be the network you would like to get an IP address for
detect-master() {
  KUBE_MASTER=${MASTER_NAME}

  MASTER_IP=$(doctl compute droplet list | grep ${KUBE_MASTER} | awk '{print $3}' | tail -n 1)
}


kube-up() {

  SCRIPT_DIR=$(CDPATH="" cd $(dirname $0); pwd)
 #Creates key, object storage requires, at this time, a new droplet to be created ahead of the cluster to servce the kubernetes.tar.gz archive
  do-ssh-key

  # Create a temp directory to hold scripts that will be uploaded to master/nodes
  KUBE_TEMP=$(mktemp -d -t kubernetes.XXXXXX)
  trap "rm -rf ${KUBE_TEMP}" EXIT

  load-or-gen-kube-basicauth
  python2.7 $(dirname $0)/../third_party/htpasswd/htpasswd.py -b -c ${KUBE_TEMP}/htpasswd $KUBE_USER $KUBE_PASSWORD
  HTPASSWD=$(cat ${KUBE_TEMP}/htpasswd)

  # create and upload ssh key if necessary

  echo "cluster/digitalocean/util.sh: Starting Cloud Servers"
  prep_known_tokens
  create-kube-ca
  create-cluster-tag
  do-boot-master
  do-boot-nodes

  detect-master

  # TODO look for a better way to get the known_tokens to the master. This is needed over file injection since the files were too large on a 4 node cluster.
  $(scp -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME} ${KUBE_TEMP}/known_tokens.csv core@${KUBE_MASTER_IP}:/home/core/known_tokens.csv)
  $(sleep 2)
  $(ssh -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME} core@${KUBE_MASTER_IP} sudo /usr/bin/mkdir -p /var/lib/kube-apiserver)
  $(ssh -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME} core@${KUBE_MASTER_IP} sudo mv /home/core/known_tokens.csv /var/lib/kube-apiserver/known_tokens.csv)
  $(ssh -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME} core@${KUBE_MASTER_IP} sudo chown root.root /var/lib/kube-apiserver/known_tokens.csv)
  $(ssh -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME} core@${KUBE_MASTER_IP} sudo systemctl restart kube-apiserver)
  $(scp -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME} $(dirname $0)/digitalocean/certs/apiserver.pem core@${KUBE_MASTER_IP}:/home/core/apiserver.pem)
  $(scp -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME} $(dirname $0)/digitalocean/certs/apiserver-key.pem core@${KUBE_MASTER_IP}:/home/core/apiserver-key.pem)
  if [ $DO_CERTS == true ]; then
    $(scp -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME} $(dirname $0)/digitalocean/certs/ca.pem core@${KUBE_MASTER_IP}:/home/core/ca.pem)
  fi
  $(sleep 2)
  $(ssh -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME} core@${KUBE_MASTER_IP} sudo mkdir /opt/certs)
  $(ssh -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME} core@${KUBE_MASTER_IP} sudo mv /home/core/apiserver.pem /opt/certs/apiserver.pem)
  $(ssh -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME} core@${KUBE_MASTER_IP} sudo mv /home/core/apiserver-key.pem /opt/certs/apiserver-key.pem)
  if [ $DO_CERTS == true ]; then
    $(ssh -o StrictHostKeyChecking=no -i ~/.ssh/${SSH_KEY_NAME} core@${KUBE_MASTER_IP} sudo mv /home/core/ca.pem /opt/certs/ca.pem)
  fi

  FAIL=0
  for job in `jobs -p`
  do
      wait $job || let "FAIL+=1"
  done
  if (( $FAIL != 0 )); then
    echo "${FAIL} commands failed.  Exiting."
    exit 2
  fi

  echo "Waiting for cluster initialization."
  echo
  echo "  This will continually check to see if the API for kubernetes is reachable."
  echo "  This might loop forever if there was some uncaught error during start"
  echo "  up."
  echo

  #This will fail until apiserver salt is updated
  #Return to this when proxy container is re-introdced with certs!
  KUBE_BEARER_TOKEN=$(cat $KUBE_TEMP/known_tokens.csv|grep admin| cut -f1 -d',')
  until $(curl --insecure --header "Authorization: Bearer ${KUBE_BEARER_TOKEN}" --max-time 5 \
          --fail --output /dev/null --silent https://${KUBE_MASTER_IP}/healthz); do
      printf "."
      sleep 2
  done

  echo -e "\nKubernetes cluster created."

  export KUBE_CERT="$(dirname $0)/digitalocean/certs/apiserver.pem"
  export KUBE_KEY="$(dirname $0)/digitalocean/certs/apiserver-key.pem"
  if [ $DO_CERTS == true ]; then
    export CA_CERT="$(dirname $0)/digitalocean/certs/ca.pem"
  fi
  export CONTEXT="digitalocean_${INSTANCE_PREFIX}"

  create-kubeconfig

  # Don't bail on errors, we want to be able to print some info.
  set +e

  detect-nodes

  # ensures KUBECONFIG is set
  get-kubeconfig-basicauth
  echo "All nodes may not be online yet, this is okay."
  echo
  echo "Kubernetes cluster is running.  The master is running at:"
  echo
  echo "  https://${KUBE_MASTER_IP}"
  echo
  echo "The user name and password to use is located in ${KUBECONFIG:-$DEFAULT_KUBECONFIG}."
  echo
  echo "Security note: The server above uses a self signed certificate.  This is"
  echo "    subject to \"Man in the middle\" type attacks."
  echo
}


kube-down () {
    TAG_ID=`cat $(dirname $0)/digitalocean/.last_cluster`
    echo "Tearing down cluster $TAG_ID..." && \
    doctl compute droplet list --tag-name kubernetes-$TAG_ID | grep -v ID | awk '{print $1}' | xargs doctl compute droplet delete
    echo "Deleting tag kubernetes-$TAG_ID..."
    doctl compute tag delete kubernetes-$TAG_ID
}

# Perform preparations required to run e2e tests
function prepare-e2e() {
  echo "DigitalOcean doesn't need special preparations for e2e tests"
}
