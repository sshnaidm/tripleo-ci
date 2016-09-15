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
sudo yum install -y python-tripleoclient

echo "See env in /tmp/my_env_is_here"
env > /tmp/my_env_is_here

$TRIPLEO_ROOT/tripleo-quickstart/quickstart.sh  --bootstrap \
        -t 'undercloud-scripts,undercloud-install' \
        --requirements quickstart-extras-requirements.txt \
        --playbook quickstart-extras.yml \
        $OOOQ_DEFAULT_ARGS 127.0.0.2 2>&1 \
        | ts '%Y-%m-%d %H:%M:%S.000 |' | sudo tee /var/log/undercloud_install.txt ||:

wget http://66.187.229.139/builds/current-tripleo/ipa_images.tar
wget http://66.187.229.139/builds/current-tripleo/overcloud-full.tar

tar -xvf overcloud-full.tar
tar -xvf ipa_images.tar
update_image ironic-python-agent.initramfs
update_image overcloud-full.qcow2
rm -f overcloud-full.tar ipa_images.tar

$TRIPLEO_ROOT/tripleo-quickstart/quickstart.sh  --no-clone \
        -t 'undercloud-post-install,overcloud-scripts' \
        -e step_introspect=False \
        -e network_isolation=True \
        --requirements quickstart-extras-requirements.txt \
        --playbook quickstart-extras.yml \
        $OOOQ_DEFAULT_ARGS 127.0.0.2 2>&1 \
        | ts '%Y-%m-%d %H:%M:%S.000 |' | sudo tee /var/log/undercloud_install.txt ||:

collect_oooq_logs