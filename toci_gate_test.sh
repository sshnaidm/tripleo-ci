#!/usr/bin/env bash
set -eux
# Mirrors
source $(dirname $0)/scripts/common_vars.bash
if [[ -e /etc/nodepool/provider ]]; then
    # NOTE(pabelanger): We have access to AFS mirrors, lets use them.
    source /etc/nodepool/provider

    NODEPOOL_MIRROR_HOST=${NODEPOOL_MIRROR_HOST:-mirror.$NODEPOOL_REGION.$NODEPOOL_CLOUD.openstack.org}
    NODEPOOL_MIRROR_HOST=$(echo $NODEPOOL_MIRROR_HOST|tr '[:upper:]' '[:lower:]')
    export CENTOS_MIRROR=http://$NODEPOOL_MIRROR_HOST/centos
    export EPEL_MIRROR=http://$NODEPOOL_MIRROR_HOST/epel
else
    # NOTE(sshnaidm): If working on dev environments:
    # Mirrors
    # We don't seem to have a CentOS mirror in the data center, so we need to pick
    # one that has reasonable connectivity to our rack.  Provide a few options in
    # case one of them goes down.
    for mirror in http://mirror.hmc.edu/centos/ http://mirrors.usc.edu/pub/linux/distributions/centos/ http://mirror.centos.org/centos/; do
        if curl -L -f -m 10 $mirror > /dev/null 2>&1; then
            export CENTOS_MIRROR=$mirror
            break
        fi
    done
    # This EPEL Mirror is in the same data center as our CI rack
    export EPEL_MIRROR=http://dl.fedoraproject.org/pub/epel
    # NOTE(pabelanger): Once we bring AFS mirrors online, we no longer need to do this.
    sudo sed -i -e "s|^#baseurl=http://mirror.centos.org/centos/|baseurl=$CENTOS_MIRROR|;/^mirrorlist/d" /etc/yum.repos.d/CentOS-Base.repo
fi

# FIXME(derekh) This needs to be removed
# We pin this in tripleo-puppet-elements, but the stuff in toci_* overrides it
# as ci is written to use whatever zuul tells it to use, remove what zuul has given
# us and use stable/hammer (pinned in t-p-e), N.B. This essentially invailidates
# tripleo puppet-ceph ci
rm -rf $TRIPLEO_ROOT/puppet-ceph

if [ ${NODEPOOL_CLOUD:-} == 'tripleo-test-cloud-rh1' ]; then
    source $(dirname $0)/scripts/rh2.env

    # In order to save space remove the cached git repositories, at this point in
    # CI the ones we are interested in have been cloned to /opt/stack/new. We
    # can also remove some distro images cached on the images.
    sudo rm -rf /opt/git /opt/stack/cache/files/mysql.qcow2 /opt/stack/cache/files/ubuntu-12.04-x86_64.tar.gz
fi

# Clean any cached yum metadata, it maybe stale
sudo yum clean all

# NOTE(pabelanger): Current hack to make centos-7 dib work.
# TODO(pabelanger): Why is python-requests installed from pip?
sudo rm -rf /usr/lib/python2.7/site-packages/requests

# Remove metrics from a previous run
rm -f /tmp/metric-start-times /tmp/metrics-data

# JOB_NAME used to be available from jenkins, we need to create it ourselves until
# we remove our reliance on it.
if [[ -z "${JOB_NAME-}" ]]; then
    JOB_NAME=${WORKSPACE%/}
    export JOB_NAME=${JOB_NAME##*/}
fi

# cd to toci directory so relative paths work
cd $(dirname $0)

# Only define $http_proxy if it is unset (use "-" instead of ":-" in the
# parameter expansion). This will allow an external script to override using a
# proxy by setting export http_proxy=""
export http_proxy=${http_proxy-"http://192.168.1.100:3128/"}

export GEARDSERVER=${TEBROKERIP-192.168.1.1}
export MIRRORSERVER=${MIRRORIP-192.168.1.101}

export CACHEUPLOAD=0
export INTROSPECT=0
export NODECOUNT=2
export PACEMAKER=0
# Whether or not we deploy an Overcloud
export OVERCLOUD=1
# NOTE(bnemec): At this time, the undercloud install + image build is taking from
# 1 hour to 1 hour and 15 minutes on the jobs I checked.  The devstack gate timeout
# is 170 minutes, so subtracting 90 should leave us an hour and 20 minutes for
# the deploy.  Hopefully that's enough, while still leaving some cushion to come
# in under the gate timeout so we can collect logs.
OVERCLOUD_DEPLOY_TIMEOUT=$((DEVSTACK_GATE_TIMEOUT-90))
export OVERCLOUD_SSH_USER=${OVERCLOUD_SSH_USER:-"jenkins"}
export OVERCLOUD_DEPLOY_ARGS=${OVERCLOUD_DEPLOY_ARGS:-""}
export OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS --libvirt-type=qemu -t $OVERCLOUD_DEPLOY_TIMEOUT"
export OVERCLOUD_UPDATE_ARGS=
export UNDERCLOUD_SSL=0
export UNDERCLOUD_IDEMPOTENT=0
export UNDERCLOUD_SANITY_CHECK=0
export TRIPLEO_SH_ARGS=
export NETISO_V4=0
export NETISO_V6=0
export RUN_PING_TEST=1
export RUN_TEMPEST_TESTS=0
export OVB=0
export UCINSTANCEID=NULL
export TOCIRUNNER="./toci_instack.sh"
export MULTINODE=0
# Whether or not we run TripleO using OpenStack Infra nodes
export OSINFRA=0
export CONTROLLER_HOSTS=
export COMPUTE_HOSTS=
export SUBNODES_SSH_KEY=
export TEST_OVERCLOUD_DELETE=0

# start dstat early
# TODO add it to the gate image building
sudo yum install -y dstat nmap-ncat #nc is for metrics
mkdir -p "$WORKSPACE/logs"
dstat -tcmndrylpg --output "$WORKSPACE/logs/dstat-csv.log" >/dev/null &
disown

# Switch defaults based on the job name
for JOB_TYPE_PART in $(sed 's/-/ /g' <<< "${TOCI_JOBTYPE:-}") ; do
    case $JOB_TYPE_PART in
        updates)
            NODECOUNT=3
            OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS -e /usr/share/openstack-tripleo-heat-templates/environments/puppet-pacemaker.yaml --ceph-storage-scale 1 -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation-v6.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/net-multiple-nics-v6.yaml -e $TRIPLEO_ROOT/tripleo-ci/test-environments/net-iso.yaml"
            OVERCLOUD_UPDATE_ARGS="-e /usr/share/openstack-tripleo-heat-templates/overcloud-resource-registry-puppet.yaml $OVERCLOUD_DEPLOY_ARGS"
            NETISO_V6=1
            PACEMAKER=1
            ;;
        ha)
            NODECOUNT=4
            # In ci our overcloud nodes don't have access to an external netwrok
            # --ntp-server is here to make the deploy command happy, the ci env
            # is on virt so the clocks should be in sync without it.
            OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS --control-scale 3 --ntp-server 0.centos.pool.ntp.org -e /usr/share/openstack-tripleo-heat-templates/environments/puppet-pacemaker.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml -e $TRIPLEO_ROOT/tripleo-ci/test-environments/network-templates/network-environment.yaml -e $TRIPLEO_ROOT/tripleo-ci/test-environments/net-iso.yaml"
            NETISO_V4=1
            PACEMAKER=1
            ;;
        ha2)
            NODECOUNT=5
            # In ci our overcloud nodes don't have access to an external netwrok
            # --ntp-server is here to make the deploy command happy, the ci env
            # is on virt so the clocks should be in sync without it.
            OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS --control-scale 3 --ceph-storage-scale 1 --ntp-server 0.centos.pool.ntp.org -e /usr/share/openstack-tripleo-heat-templates/environments/puppet-pacemaker.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/storage-environment.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml -e $TRIPLEO_ROOT/tripleo-ci/test-environments/network-templates/network-environment.yaml -e $TRIPLEO_ROOT/tripleo-ci/test-environments/net-iso.yaml"
            NETISO_V4=1
            PACEMAKER=1
            ;;
        nonha)
            OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS -e $TRIPLEO_ROOT/tripleo-ci/test-environments/enable-tls.yaml -e $TRIPLEO_ROOT/tripleo-ci/test-environments/inject-trust-anchor.yaml --ceph-storage-scale 1 -e /usr/share/openstack-tripleo-heat-templates/environments/puppet-ceph-devel.yaml"
            INTROSPECT=1
            NODECOUNT=3
            UNDERCLOUD_SSL=1
            ;;
        containers)
            # TODO : remove this when the containers job is passing again
            exit 1
            TRIPLEO_SH_ARGS="--use-containers"
            ;;
        ovb)
            OVB=1
            TOCIRUNNER="./toci_instack_ovb.sh"

            # The test env broker needs to know the instanceid of the this node so it can attach it to the provisioning network
            UCINSTANCEID=$(http_proxy= curl http://169.254.169.254/openstack/2015-10-15/meta_data.json | python -c 'import json, sys; print json.load(sys.stdin)["uuid"]')
            ;;
        multinode)
            MULTINODE=1
            TOCIRUNNER="./toci_instack_osinfra.sh"
            NODECOUNT=1
            PACEMAKER=1
            OSINFRA=1

            CONTROLLER_HOSTS=$(sed -n 1,1p /etc/nodepool/sub_nodes)
            SUBNODES_SSH_KEY=/etc/nodepool/id_rsa
            UNDERCLOUD_SSL=0
            INTROSPECT=0
            OVERCLOUD_DEPLOY_ARGS="--libvirt-type=qemu -t $OVERCLOUD_DEPLOY_TIMEOUT"
            OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS -e /usr/share/openstack-tripleo-heat-templates/environments/deployed-server-environment.yaml -e $TRIPLEO_ROOT/tripleo-ci/test-environments/multinode.yaml --compute-scale 0 --overcloud-ssh-user $OVERCLOUD_SSH_USER --validation-errors-nonfatal"
            ;;
        undercloud)
            TOCIRUNNER="./toci_instack_osinfra.sh"
            NODECOUNT=0
            OVERCLOUD=0
            OSINFRA=1
            RUN_PING_TEST=0
            UNDERCLOUD_SSL=0
            INTROSPECT=0
            export UNDERCLOUD_SANITY_CHECK=1
            ;;
        periodic)
            export DELOREAN_REPO_URL=http://trunk.rdoproject.org/centos7/consistent
            CACHEUPLOAD=1
            UNDERCLOUD_IDEMPOTENT=1
            TEST_OVERCLOUD_DELETE=1
            ;;
        liberty|mitaka)
            # This is handled in tripleo.sh (it always uses centos7-$STABLE_RELEASE/current)
            # where $STABLE_RELEASE is derived in toci_instack.sh
            unset DELOREAN_REPO_URL
            ;;
        tempest)
            export RUN_TEMPEST_TESTS=1
            export RUN_PING_TEST=0
            UNDERCLOUD_IDEMPOTENT=0
            ;;
    esac
done

# print the final values of control variables to console
env | grep -E "(TOCI_JOBTYPE)="

# Allow the instack node to have traffic forwards through here
sudo iptables -A FORWARD -i eth0 -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
echo 1 | sudo dd of=/proc/sys/net/ipv4/ip_forward

TIMEOUT_SECS=$((DEVSTACK_GATE_TIMEOUT*60))
# ./testenv-client kill everything in its own process group it it hits a timeout
# run it in a separate group to avoid getting killed along with it
set -m

# install moreutils for timestamping postci.log with ts
# This comes from epel, so we need to install it before removing that repo
sudo yum install -y moreutils

# Temporary fix for https://bugs.launchpad.net/tripleo/+bug/1606685
sudo yum erase -y epel-release nodejs nodejs-devel nodejs-packaging || :

source $TRIPLEO_ROOT/tripleo-ci/scripts/metrics.bash
start_metric "tripleo.testenv.wait.seconds"
if [ -z "${TE_DATAFILE:-}" -a "$OSINFRA" = "0" ] ; then
    # NOTE(pabelanger): We need gear for testenv, but this really should be
    # handled by tox.
    sudo pip install gear
    # Kill the whole job if it doesn't get a testenv in 20 minutes as it likely will timout in zuul
    ( sleep 1200 ; [ ! -e /tmp/toci.started ] && sudo kill -9 $$ ) &

    ./testenv-client -b $GEARDSERVER:4730 -t $TIMEOUT_SECS --envsize $(($NODECOUNT+1)) --ucinstance $UCINSTANCEID -- $TOCIRUNNER
else
    LEAVE_RUNNING=1 $TOCIRUNNER
fi
