function previous_release_from {
    local release="${1:-master}"
    local type="${2:-mixed_upgrade}"
    local previous_version=""
    case "${type}" in
        'mixed_upgrade')
            previous_version=$(previous_release_mixed_upgrade_case "${release}");;
        'ffu_upgrade')
            previous_version=$(previous_release_ffu_upgrade_case "${release}");;
        *)
            echo "UNKNOWN_TYPE"
            return 1
            ;;
    esac
    echo "${previous_version}"
}

function previous_release_mixed_upgrade_case {
    local release="${1:-master}"
    case "${release}" in
        ''|master)
            # NOTE: we need to update this when we cut a stable branch
            echo "queens"
            ;;
        queens)
            echo "pike"
            ;;
        pike)
            echo "ocata"
            ;;
        ocata)
            echo "newton"
            ;;
        newton)
            echo "mitaka"
            ;;
        *)
            echo "UNKNOWN_RELEASE"
            return 1
            ;;
    esac
}

function previous_release_ffu_upgrade_case {
    local release="${1:-master}"

    case "${release}" in
        ''|master)
            # NOTE: we need to update this when we cut a stable branch
            echo "newton"
            ;;
        queens)
            echo "newton"
            ;;
        *)
            echo "INVALID_RELEASE_FOR_FFU"
            return 1
            ;;
    esac
}

function is_featureset {
    local type="${1}"
    local featureset_file="${2}"

    [ $(shyaml get-value "${type}" "False"< "${featureset_file}") = "True" ]
}

function run_with_timeout {
    # First parameter is the START_JOB_TIME
    # Second is the command to be executed
    JOB_TIME=$1
    shift
    COMMAND=$@
    # Leave 20 minutes for quickstart logs collection for ovb only
    if [[ "$TOCI_JOBTYPE" =~ "ovb" ]]; then
        RESERVED_LOG_TIME=20
    else
        RESERVED_LOG_TIME=3
    fi
    # Use $REMAINING_TIME of infra to calculate maximum time for remaining part of job
    REMAINING_TIME=${REMAINING_TIME:-180}
    TIME_FOR_COMMAND=$(( REMAINING_TIME - ($(date +%s) - JOB_TIME)/60 - $RESERVED_LOG_TIME))

    if [[ $TIME_FOR_COMMAND -lt 1 ]]; then
        return 143
    fi
    /usr/bin/timeout --preserve-status ${TIME_FOR_COMMAND}m ${COMMAND}
}

function generate_playbook_command {
    local playbook=$1

    echo "$QUICKSTART_INSTALL_CMD \
        --extra-vars ci_job_end_time=$(( START_JOB_TIME + REMAINING_TIME*60 )) \
        $LOCAL_WORKING_DIR/playbooks/$playbook \"${PLAYBOOKS_ARGS[$playbook]:-}\" \
        2>&1 | tee -a $LOGS_DIR/quickstart_install.log && exit_value=0 || exit_value=$?"
}

function dumpvars {
set +u
cat<<EOF > ~/oooq_internal_vars.sh
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG}"
export ANSIBLE_SSH_ARGS="${ANSIBLE_SSH_ARGS}"
export ARA_DATABASE="${ARA_DATABASE}"
export DEFAULT_ARGS="${DEFAULT_ARGS}"
export DEVSTACK_GATE_TIMEOUT="${DEVSTACK_GATE_TIMEOUT}"
export LOCAL_WORKING_DIR="${LOCAL_WORKING_DIR}"
export LOGS_DIR="${LOGS_DIR}"
export NODEPOOL_PROVIDER="${NODEPOOL_PROVIDER}"
export NODES_FILE="${NODES_FILE}"
export OOOQ_DIR="${OOOQ_DIR}"
export OPT_WORKDIR="${OPT_WORKDIR}"
export QUICKSTART_COLLECTLOGS_CMD="${QUICKSTART_COLLECTLOGS_CMD}"
export QUICKSTART_INSTALL_CMD="${QUICKSTART_INSTALL_CMD}"
export QUICKSTART_RELEASE="${QUICKSTART_RELEASE}"
export QUICKSTART_VENV_CMD="${QUICKSTART_VENV_CMD}"
export REMAINING_TIME="${REMAINING_TIME}"
export SSH_CONFIG="${SSH_CONFIG}"
export STABLE_RELEASE="${STABLE_RELEASE}"
export START_JOB_TIME="${START_JOB_TIME}"
export STATS_OOOQ="${STATS_OOOQ}"
export STATS_TESTENV="${STATS_TESTENV}"
export TOCI_JOBTYPE="${TOCI_JOBTYPE}"
export VIRTUAL_ENV_DISABLE_PROMPT="${VIRTUAL_ENV_DISABLE_PROMPT}"
export WORKING_DIR="${WORKING_DIR}"
export ZUUL_CHANGES="${ZUUL_CHANGES}"
export ZUUL_PIPELINE="${ZUUL_PIPELINE}"
EOF
set -u
cat ~/oooq_internal_vars.sh
}

function loadvars {
    source ~/oooq_internal_vars.sh || echo "Can not load variables from ~/oooq_internal_vars.sh"
}
