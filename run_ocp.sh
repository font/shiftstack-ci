#!/usr/bin/env bash

set -e

CONFIG=${CONFIG:-cluster_config.sh}
if [ ! -r "$CONFIG" ]; then
    echo "Could not find cluster configuration file."
    echo "Make sure $CONFIG file exists in the shiftstack-ci directory and that it is readable"
    exit 1
fi
source ${CONFIG}

set -x

declare -r installer="${OPENSHIFT_INSTALLER:-$GOPATH/src/github.com/openshift/installer/bin/openshift-install}"

# check whether we have a free floating IP
FLOATING_IP=$(openstack floating ip list --status DOWN --network $OPENSTACK_EXTERNAL_NETWORK --long --format value -c "Floating IP Address" -c Description | sed 's/ .*//g')
FLOATING_IP=$(echo $FLOATING_IP | cut -d ' ' -f1)

# create new floating ip if doesn't exist
if [ -z "$FLOATING_IP" ]; then
    FLOATING_IP=$(openstack floating ip create $OPENSTACK_EXTERNAL_NETWORK --description "${CLUSTER_NAME}-api" --format value --column floating_ip_address)
fi

hosts="# Generated by shiftstack for $CLUSTER_NAME - Do not edit
$FLOATING_IP api.${CLUSTER_NAME}.${BASE_DOMAIN}
# End of $CLUSTER_NAME nodes"

old_hosts=$(awk "/# Generated by shiftstack for $CLUSTER_NAME - Do not edit/,/# End of $CLUSTER_NAME nodes/" /etc/hosts)

if [ "${hosts}" != "${old_hosts}" ]; then
  echo Updating hosts file
  sudo sed -i "/# Generated by shiftstack for $CLUSTER_NAME - Do not edit/,/# End of $CLUSTER_NAME nodes/d" /etc/hosts
  echo "$hosts" | sudo tee -a /etc/hosts
fi

ssh_config="# Generated by shiftstack for $CLUSTER_NAME - Do not edit
Host openshift-api-$CLUSTER_NAME
    Hostname $FLOATING_IP
    User core
    Port 22
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
# End of $CLUSTER_NAME nodes"

old_ssh_config=$(awk "/# Generated by shiftstack for $CLUSTER_NAME - Do not edit/,/# End of $CLUSTER_NAME nodes/" $HOME/.ssh/config)
if [ "${ssh_config}" != "${old_ssh_config}" ]; then
  echo Updating ssh config file
  sed -i "/# Generated by shiftstack for $CLUSTER_NAME - Do not edit/,/# End of $CLUSTER_NAME nodes/d" $HOME/.ssh/config
  echo "$ssh_config" >>  $HOME/.ssh/config
fi

ARTIFACT_DIR=clusters/${CLUSTER_NAME}

rm -rf ${ARTIFACT_DIR}
mkdir -p ${ARTIFACT_DIR}

: "${OPENSTACK_WORKER_FLAVOR:=${OPENSTACK_FLAVOR}}"

MASTER_ROOT_VOLUME=""
if [[ ${OPENSTACK_MASTER_VOLUME_TYPE} != "" ]]; then
  MASTER_ROOT_VOLUME="rootVolume:
        size: ${OPENSTACK_MASTER_VOLUME_SIZE:-25}
        type: ${OPENSTACK_MASTER_VOLUME_TYPE}"
fi
WORKER_ROOT_VOLUME=""
if [[ ${OPENSTACK_WORKER_VOLUME_TYPE} != "" ]]; then
  WORKER_ROOT_VOLUME="rootVolume:
        size: ${OPENSTACK_WORKER_VOLUME_SIZE:-25}
        type: ${OPENSTACK_WORKER_VOLUME_TYPE}"
fi

if [ ! -f ${ARTIFACT_DIR}/install-config.yaml ]; then
    export CLUSTER_ID=$(uuidgen --random)
    cat > ${ARTIFACT_DIR}/install-config.yaml << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
clusterID:  ${CLUSTER_ID}
compute:
- name: worker
  platform:
    openstack:
      type: ${OPENSTACK_WORKER_FLAVOR}
      ${WORKER_ROOT_VOLUME}
  replicas: ${WORKER_COUNT}
controlPlane:
  name: master
  platform:
    openstack:
      type: ${OPENSTACK_FLAVOR}
      ${MASTER_ROOT_VOLUME}
  replicas: ${MASTER_COUNT}
metadata:
  name: ${CLUSTER_NAME}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.128.0/17
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
platform:
  openstack:
    cloud:            ${OS_CLOUD}
    externalNetwork:  ${OPENSTACK_EXTERNAL_NETWORK}
    computeFlavor:    ${OPENSTACK_FLAVOR}
    lbFloatingIP:     ${FLOATING_IP}
pullSecret: |
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF
fi

"$installer" --log-level=debug ${1:-create} ${2:-cluster} --dir ${ARTIFACT_DIR}

# Attaching FIP to ingress port to access the cluster from outside
# check whether we have a free floating IP
INGRESS_PORT=$(openstack port list --format value -c Name | awk "/${CLUSTER_NAME}.*-ingress-port/ {print}")
if [ -n "$INGRESS_PORT" ]; then
  APPS_FLOATING_IP=$(openstack floating ip list --status DOWN --network $OPENSTACK_EXTERNAL_NETWORK --long --format value -c "Floating IP Address" -c Description | awk 'NF<=1 && NR==1 {print}')

  # create new floating ip if doesn't exist
  if [ -z "$APPS_FLOATING_IP" ]; then
      APPS_FLOATING_IP=$(openstack floating ip create $OPENSTACK_EXTERNAL_NETWORK --description "${CLUSTER_NAME}-apps" --format value --column floating_ip_address --port $INGRESS_PORT)
  else
    # attach the port
    openstack floating ip set --port $INGRESS_PORT $APPS_FLOATING_IP
  fi

  hosts="# Generated by shiftstack for $CLUSTER_NAME - Do not edit
$FLOATING_IP api.${CLUSTER_NAME}.${BASE_DOMAIN}
$APPS_FLOATING_IP console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$APPS_FLOATING_IP integrated-oauth-server-openshift-authentication.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$APPS_FLOATING_IP oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$APPS_FLOATING_IP prometheus-k8s-openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$APPS_FLOATING_IP grafana-openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
# End of $CLUSTER_NAME nodes"

  old_hosts=$(awk "/# Generated by shiftstack for $CLUSTER_NAME - Do not edit/,/# End of $CLUSTER_NAME nodes/" /etc/hosts)

  if [ "${hosts}" != "${old_hosts}" ]; then
    echo Updating hosts file
    sudo sed -i "/# Generated by shiftstack for $CLUSTER_NAME - Do not edit/,/# End of $CLUSTER_NAME nodes/d" /etc/hosts
    echo "$hosts" | sudo tee -a /etc/hosts
  fi
fi
