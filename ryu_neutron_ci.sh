#!/bin/bash

set +e +x

TESTTARGET=$1

case "$TESTTARGET" in
ryuplugin|ofagent)
  ;;
*)
  echo "unknown target environment"
  exit 1
esac

TOP_DIR=$(pwd)
LOG_DIR="${TOP_DIR}/logs"
export LANG=C
export LC_ALL=C

NEUTRON_REPO=https://github.com/openstack/neutron.git
NEUTRON_BRANCH=master
NEUTRON_DEST=neutron
OFAGENT_REPO=https://review.openstack.org/openstack/neutron
OFAGENT_REFSPEC=refs/changes/91/71791/15
#if [ "$TESTTARGET" = "ryuplugin" ]; then
#  DEVSTACK_REPO=https://github.com/openstack-dev/devstack.git
#  DEVSTACK_BRANCH=master
#else
#  DEVSTACK_REPO=https://github.com/osrg/devstack.git
#  DEVSTACK_BRANCH=bp/ryu-ml2-driver
#fi
DEVSTACK_REPO=https://github.com/osrg/devstack.git
DEVSTACK_BRANCH=bp/ryu-ml2-driver
DEVSTACK_DEST=.

cleanup_ipfilter() {
  for chain in INPUT FORWARD OUTPUT; do
    for i in `seq 1 100`; do
      num=$(sudo iptables --line-numbers -L $chain|grep -E '(neutron|nova|greenthread)'|awk '{print $1}')
      if [ -z "$num" ]; then
        break 1
      fi
      for n in $num; do
        sudo iptables -D $chain $n > /dev/null 2>&1
        break 1
      done
    done
  done

  chains=$(sudo iptables -L|grep Chain|grep -E '(neutron|nova|greenthread)'|awk '{print $2}')
  for chain in $chains; do
    sudo iptables -F $chain > /dev/null 2>&1
  done
  for chain in $chains; do
    sudo iptables -X $chain > /dev/null 2>&1
  done

  for chain in PREROUTING INPUT OUTPUT POSTROUTING; do
    while :; do
      num=$(sudo iptables -t nat --line-numbers -L $chain|grep -E '(neutron|nova|greenthread)'|awk '{print $1}')
      if [ -z "$num" ]; then
        break 1
      fi
      for n in $num; do
        sudo iptables -t nat -D $chain $n
        break 1
      done
    done
  done

  chains=$(sudo iptables -t nat -L|grep Chain|grep -E '(neutron|nova|greenthread)'|awk '{print $2}')
  for chain in $chains; do
    sudo iptables -t nat -F $chain
  done
  for chain in $chains; do
    sudo iptables -t nat -X $chain
  done
}

die() {
  set +x
  rc=$1
  cd ${TOP_DIR}
  sudo killall haproxy > /dev/null 2>&1
  if [ -x ./unstack.sh ]; then
    ./unstack.sh
  fi
  sleep 5
  cleanup_ipfilter
  sudo pkill -9 -f neutron-ns-metadata-proxy > /dev/null 2>&1
  ps ax|grep nova-|grep -v grep|awk '{print $1}'|xargs -r -n 1 kill > /dev/null 2>&1
  sleep 10
  ip netns|grep '^q'|xargs -r -n 1 sudo ip netns delete
  sudo ovs-vsctl del-br br-tun
  if [ -r ${LOG_DIR}/devstack ]; then
    find ${LOG_DIR} -type l -exec rm {} \;
    for f in ${LOG_DIR}/devstack.*; do
      mv $f $f.txt
      gzip $f.txt
    done
  fi
  find ${LOG_DIR} -name '*.log'|while read fname; do
    if [ -f "$fname" ]; then
      f=${fname%%\.log}.txt
      mv $fname $f
      gzip $f
    fi
  done
  if [ -r localrc ]; then
    cp localrc ${LOG_DIR}/localrc.txt
  fi

  exit $rc
}

prepare_dest() {
  sudo rm -rf /opt/stack || return 1
  sudo mkdir /opt/stack || return 1
  sudo chown -R $USER /opt/stack || return 1
  sudo chmod 0755 /opt/stack || return 1

  return 0
}

git_clone() {
  GIT_REMOTE=$1
  GIT_DEST=$2
  GIT_REF=$3
  GIT_BRANCH=$4

  git clone $GIT_REMOTE $GIT_DEST || return 1
  if [ -n "$GIT_REF" -a -n "$GIT_BRANCH" ]; then
    cd $GIT_DEST
    if echo $GIT_REF | egrep -q "^refs"; then
      git fetch $GIT_REMOTE $GIT_REF:$GIT_BRANCH || return 1
      git checkout $GIT_BRANCH || return 1
    else
      git checkout $GIT_REF || return 1
    fi
  fi

  return 0
}

prepare_neutron() {
  rip_repo=$1
  rip_ref=$2
  base="master"

  cd /opt/stack

  git_clone ${NEUTRON_REPO} ${NEUTRON_DEST} || return 1
  cd ${NEUTRON_DEST}

  if [ -n "$rip_repo" ]; then
    git fetch ${rip_repo} ${rip_ref}:rip || return 1
    git checkout rip || return 1
    git rebase master || return 1
    base="rip"
  fi
  git fetch ${NEUTRON_REPO} ${GERRIT_REFSPEC}:review || return 1
  git checkout review || return 1
  git rebase $base || return 1

  return 0
}

prepare_devstack() {
  git_clone $DEVSTACK_REPO $DEVSTACK_DEST $DEVSTACK_BRANCH ryu || return 1

  return 0
}

sudo rm -rf .* * > /dev/null 2>&1

prepare_devstack
if [ $? -ne 0 ]; then
  echo "could not download devstack."
  die 1
fi

prepare_dest || die 1

if [ "$TESTTARGET" = "ryuplugin" ]; then
  prepare_neutron
else
  prepare_neutron $OFAGENT_REPO $OFAGENT_REFSPEC
fi
if [ $? -ne 0 ]; then
  echo "preparation for neutron failed."
  die 1
fi
cd ${TOP_DIR}

if [ "$TESTTARGET" = "ryuplugin" ]; then
cat <<EOF > localrc
SERVICE_HOST=127.0.0.1

Q_HOST=\$SERVICE_HOST
MYSQL_HOST=\$SERVICE_HOST
RABBIT_HOST=\$SERVICE_HOST
GLANCE_HOSTPORT=\$SERVICE_HOST:9292
KEYSTONE_AUTH_HOST=\$SERVICE_HOST
KEYSTONE_SERVICE_HOST=\$SERVICE_HOST
RYU_API_HOST=\$SERVICE_HOST
RYU_OFP_HOST=\$SERVICE_HOST

MYSQL_PASSWORD=mysql
RABBIT_PASSWORD=rabbit
SERVICE_TOKEN=service
SERVICE_PASSWORD=admin
ADMIN_PASSWORD=admin

disable_service n-net n-novnc n-xvnc n-cauth horizon
enable_service neutron q-svc q-agt q-l3 q-dhcp q-meta q-lbaas q-fwaas
enable_service tempest
enable_service ryu

FLOATING_RANGE=172.16.0.0/24
PUBLIC_NETWORK_GATEWAY=172.16.0.1
FIXED_RANGE=192.168.0.0/24
NETWORK_GATEWAY=192.168.0.1

Q_PLUGIN=ryu
NETWORK_API_EXTENSIONS=service-type,ext-gw-mode,security-group,lbaas_agent_scheduler,fwaas,binding,external-net,router,lbaas,extraroute

RYU_APPS=ryu.app.gre_tunnel,ryu.app.quantum_adapter,ryu.app.rest,ryu.app.rest_conf_switch,ryu.app.rest_tunnel,ryu.app.tunnel_port_updater,ryu.app.rest_quantum

NEUTRON_BRANCH=${GERRIT_REFSPEC}

VERBOSE=False
LOGFILE=${LOG_DIR}/devstack
SCREEN_LOGDIR=${LOG_DIR}/stack/
LOG_COLOR=False
OFFLINE=False
RECLONE=False
EOF
else
cat <<EOF > localrc
SERVICE_HOST=127.0.0.1

Q_HOST=\$SERVICE_HOST
MYSQL_HOST=\$SERVICE_HOST
RABBIT_HOST=\$SERVICE_HOST
GLANCE_HOSTPORT=\$SERVICE_HOST:9292
KEYSTONE_AUTH_HOST=\$SERVICE_HOST
KEYSTONE_SERVICE_HOST=\$SERVICE_HOST
RYU_API_HOST=\$SERVICE_HOST
RYU_OFP_HOST=\$SERVICE_HOST

MYSQL_PASSWORD=mysql
RABBIT_PASSWORD=rabbit
SERVICE_TOKEN=service
SERVICE_PASSWORD=admin
ADMIN_PASSWORD=admin

disable_service n-net n-novnc n-xvnc n-cauth horizon
enable_service neutron q-svc q-agt q-l3 q-dhcp q-meta q-lbaas q-fwaas q-vpn
enable_service tempest

FLOATING_RANGE=172.16.0.0/24
PUBLIC_NETWORK_GATEWAY=172.16.0.1
FIXED_RANGE=192.168.0.0/24
NETWORK_GATEWAY=192.168.0.1

Q_PLUGIN=ml2
ENABLE_TENANT_TUNNELS=True
TENANT_TUNNEL_RANGES=1100:1199
Q_ML2_PLUGIN_MECHANISM_DRIVERS=ofagent
Q_AGENT=ofagent
Q_ALLOW_OVERLAPPING_IP=True
NETWORK_API_EXTENSIONS=service-type,ext-gw-mode,security-group,l3_agent_scheduler,lbaas_agent_scheduler,external-net,binding,quotas,agent,router,dhcp_agent_scheduler,fwaas,multi-provider,allowed-address-pairs,extra_dhcp_opt,provider,lbaas,extraroute

RYU_REPO=https://github.com/yamt/ryu
RYU_BRANCH=neutron-ofa

VERBOSE=False
LOGFILE=${LOG_DIR}/devstack
SCREEN_LOGDIR=${LOG_DIR}/stack/
LOG_COLOR=False
OFFLINE=False
RECLONE=False
EOF
fi

echo "----------"
cat localrc
echo "----------"

set -x
./stack.sh
if [ $? -ne 0 ]; then
  set +x
  echo "devstack failed."
  if [ -r ${LOG_DIR}/devstack ]; then
    echo "----------"
    tail -20 ${LOG_DIR}/devstack
    echo "----------"
  else
    echo "no log"
  fi
  die 1
fi

cd /opt/stack/tempest
testr init
if [ "$TESTTARGET" = "ryuplugin" ]; then
rc=$?
testr run \
tempest.api.network.test_networks \
tempest.api.network.test_floating_ips \
tempest.api.network.test_security_groups \
tempest.api.network.test_security_groups_negative \
tempest.api.network.test_load_balancer \
tempest.api.network.test_service_type_management
#tempest.scenario.test_network_basic_ops
#tempest.api.network.test_routers \
rc=$?
else
testr run \
tempest.api.network
#tempest.api.network \
#tempest.scenario.test_network_basic_ops
rc=$?
fi

set +x
TESTRLOG=${LOG_DIR}/testr.log
testr last > ${TESTRLOG}
echo "----" >> ${TESTRLOG}
testr last --subunit >> ${TESTRLOG}
if [ -r tempest.log ]; then
  cp tempest.log ${LOG_DIR}
fi
die ${rc}
