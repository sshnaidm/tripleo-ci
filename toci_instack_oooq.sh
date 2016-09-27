#!/usr/bin/env bash
set -eux

## Signal to toci_gate_test.sh we've started
touch /tmp/toci.started

export CURRENT_DIR=$(dirname ${BASH_SOURCE[0]:-$0})
export TRIPLEO_CI_DIR=$CURRENT_DIR/../

source $TRIPLEO_CI_DIR/tripleo-ci/scripts/common_vars.bash
source $TRIPLEO_CI_DIR/tripleo-ci/scripts/common_functions.sh
#source $TRIPLEO_CI_DIR/tripleo-ci/scripts/metrics.bash

mkdir -p $WORKSPACE/logs

hostname | sudo dd of=/etc/hostname
echo "127.0.0.1 $(hostname) $(hostname).openstacklocal" | sudo tee -a /etc/hosts
echo "127.0.0.2 $(hostname) $(hostname).openstacklocal" | sudo tee -a /etc/hosts

echo | sudo tee -a ~root/.ssh/authorized_keys | sudo tee -a ~/.ssh/authorized_keys
if [ ! -e /home/$USER/.ssh/id_rsa.pub ] ; then
    ssh-keygen -N "" -f /home/$USER/.ssh/id_rsa
fi
cat ~/.ssh/id_rsa.pub | sudo tee -a ~root/.ssh/authorized_keys | sudo tee -a ~/.ssh/authorized_keys

sudo yum remove -y puppet hiera puppetlabs-release rdo-release
sudo rm -rf /etc/puppet /etc/hiera.yaml
sudo yum reinstall -y python-requests || sudo yum install -y python-requests

trap "[ \$? != 0 ] && echo ERROR DURING PREVIOUS COMMAND ^^^ && echo 'See postci.txt in the logs directory for debugging details'; collect_oooq_logs 2>&1 | ts '%Y-%m-%d %H:%M:%S.000 |' > $WORKSPACE/logs/postci.log 2>&1" EXIT

# Install our test cert so SSL tests work
sudo cp $TRIPLEO_ROOT/tripleo-ci/test-environments/overcloud-cacert.pem /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust extract

cp -f $TE_DATAFILE ~/instackenv.json
$TRIPLEO_CI_DIR/tripleo-ci/scripts/tripleo.sh --repo-setup

prepare_oooq

#sed -i "s@https://github.com/redhat-openstack/ansible-role-tripleo-overcloud-prep-images.git@https://github.com/sshnaidm/ansible-role-tripleo-overcloud-prep-images.git@" $TRIPLEO_ROOT/tripleo-quickstart/quickstart-extras-requirements.txt

sudo yum install -y python-tripleoclient

echo "See env in /tmp/my_env_is_here"

UNDERCLOUD_SCRIPTS=" -e network_isolation=True -e step_introspect=False --config $TRIPLEO_ROOT/tripleo-quickstart/config/general_config/ha.yml "
PLAYBOOK=" --playbook ovb.yml --requirements quickstart-extras-requirements.txt "
OVERCLOUD_SCRIPTS=" -e /usr/share/openstack-tripleo-heat-templates/environments/puppet-pacemaker.yaml \
                    -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
                    -e $TRIPLEO_ROOT/tripleo-ci/test-environments/network-templates/network-environment.yaml \
                    -e $TRIPLEO_ROOT/tripleo-ci/test-environments/net-iso.yaml"

# -e extra_args='--control-scale 3 --ntp-server 0.centos.pool.ntp.org' \
env > /tmp/my_env_is_here
prepare_images_oooq

pushd $TRIPLEO_ROOT/tripleo-quickstart/

echo "$TRIPLEO_ROOT/tripleo-quickstart/quickstart.sh  --bootstrap \
        -t all \
        $PLAYBOOK $UNDERCLOUD_SCRIPTS \
        $OOOQ_DEFAULT_ARGS 127.0.0.2 2>&1 \
        | ts '%Y-%m-%d %H:%M:%S.000 |' | sudo tee /var/log/undercloud_install.txt ||:" | tee command_log

$TRIPLEO_ROOT/tripleo-quickstart/quickstart.sh  --bootstrap \
        -t all \
        $PLAYBOOK $UNDERCLOUD_SCRIPTS \
        $OOOQ_DEFAULT_ARGS 127.0.0.2 2>&1 \
        | ts '%Y-%m-%d %H:%M:%S.000 |' | sudo tee /var/log/undercloud_install.txt ||:


collect_oooq_logs

popd