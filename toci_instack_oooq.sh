#!/usr/bin/env bash
set -eux

## Signal to toci_gate_test.sh we've started
touch /tmp/toci.started

exit_value=0
export CURRENT_DIR=$(dirname ${BASH_SOURCE[0]:-$0})
export TRIPLEO_CI_DIR=$CURRENT_DIR/../

source $TRIPLEO_CI_DIR/tripleo-ci/scripts/common_vars.bash
source $TRIPLEO_CI_DIR/tripleo-ci/scripts/common_functions.sh
#source $TRIPLEO_CI_DIR/tripleo-ci/scripts/metrics.bash

mkdir -p $WORKSPACE/logs

hostname | sudo dd of=/etc/hostname
echo "127.0.0.1 $(hostname) $(hostname).openstacklocal" | sudo tee -a /etc/hosts
echo "127.0.0.2 $(hostname) $(hostname).openstacklocal" | sudo tee -a /etc/hosts
echo | sudo tee -a /root/.ssh/authorized_keys | tee -a ~/.ssh/authorized_keys
if [ ! -e ${HOME}/.ssh/id_rsa.pub ] ; then
    if [[ -e ${HOME}/.ssh/id_rsa ]]; then
        ssh-keygen -y -f ${HOME}/.ssh/id_rsa > ${HOME}/.ssh/id_rsa.pub
    else
        ssh-keygen -N "" -f ${HOME}/.ssh/id_rsa
    fi
fi
cat ~/.ssh/id_rsa.pub | sudo tee -a /root/.ssh/authorized_keys | tee -a ~/.ssh/authorized_keys

sudo yum remove -y puppet hiera puppetlabs-release rdo-release
sudo rm -rf /etc/puppet /etc/hiera.yaml

trap "exit_val=\$?; [ \$exit_val != 0 ] && echo ERROR DURING PREVIOUS COMMAND ^^^ && echo 'See postci.txt in the logs directory for debugging details'; postci \$exit_val 2>&1 | ts '%Y-%m-%d %H:%M:%S.000 |' > $WORKSPACE/logs/postci.log 2>&1" EXIT

# Install our test cert so SSL tests work
sudo cp $TRIPLEO_ROOT/tripleo-ci/test-environments/overcloud-cacert.pem /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust extract

cp -f $TE_DATAFILE ~/instackenv.json
$TRIPLEO_CI_DIR/tripleo-ci/scripts/tripleo.sh --repo-setup

prepare_oooq

sudo yum install -y python-tripleoclient
if [[ "$TOCI_JOBTYPE" =~ "-ha" ]]; then
    CONFIG="ha"
elif [[ "$TOCI_JOBTYPE" =~ "-nonha" ]]; then
    CONFIG="minimal"
else
    CONFIG="minimal"
fi
if [[ "${STABLE_RELEASE}" =~ ^(liberty|mitaka)$ ]] ; then
    export OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS -e $TRIPLEO_ROOT/tripleo-ci/test-environments/worker-config-mitaka-and-below.yaml"
else
    export OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS -e $TRIPLEO_ROOT/tripleo-ci/test-environments/worker-config.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/low-memory-usage.yaml"
fi


UNDERCLOUD_SCRIPTS=" --config $TRIPLEO_ROOT/tripleo-quickstart/config/general_config/${CONFIG}.yml \
-e @$TRIPLEO_ROOT/tripleo-ci/scripts/quickstart/ovb.yml -e tripleo_root=$TRIPLEO_ROOT"
PLAYBOOK=" --playbook ovb-playbook.yml --requirements quickstart-extras-requirements.txt "


prepare_images_oooq

pushd $TRIPLEO_ROOT/tripleo-quickstart/

echo "See env in /tmp/my_env_is_here"
env > /tmp/my_env_is_here

echo "$TRIPLEO_ROOT/tripleo-quickstart/quickstart.sh  --bootstrap --no-clone \
        -t all \
        $PLAYBOOK $UNDERCLOUD_SCRIPTS \
        $OOOQ_DEFAULT_ARGS 127.0.0.2 2>&1 \
        | ts '%Y-%m-%d %H:%M:%S.000 |' | sudo tee /var/log/undercloud_install.txt ||:" | tee command_log


$TRIPLEO_ROOT/tripleo-quickstart/quickstart.sh  --bootstrap --no-clone \
        -t all \
        $PLAYBOOK $UNDERCLOUD_SCRIPTS \
        $OOOQ_DEFAULT_ARGS 127.0.0.2 2>&1 \
        | ts '%Y-%m-%d %H:%M:%S.000 |' | sudo tee /var/log/quickstart_install.log || exit_value=2

if [[ -e ${OOO_WORKDIR_LOCAL}/overcloudrc ]]; then
    $TRIPLEO_ROOT/tripleo-quickstart/quickstart.sh --bootstrap \
        $OOOQ_DEFAULT_ARGS \
        -t all  \
        --playbook tempest.yml  \
        --extra-vars run_tempest=True  \
        -e test_regex='.*smoke' 127.0.0.2 2>&1| sudo tee /var/log/quickstart_tempest.log || exit_value=$?
else
    exit_value=1
fi
collect_oooq_logs

popd

echo 'Run completed.'
exit $exit_value