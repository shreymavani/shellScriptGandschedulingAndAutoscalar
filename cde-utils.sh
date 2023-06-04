#!/bin/bash

set -e # Any subsequent(*) commands which fail will cause the shell script to exit immediately

# Program name
PROG=`basename $0`

# Scratch directory
SCRATCH_SPACE="/tmp/`echo ${PROG}-tmp | sed 's/.sh//'`"

dry_run_cmd() {
    cmd="bash -c \"$1\""
    log_info "${DRY_RUN}Running command: ${cmd}"
    log_info "${DRY_RUN}Exit code = $?"
}

run_cmd() {
    cmd="bash -c \"$1\""
    log_info "Running command: ${cmd}"
    bash -c "${cmd}"
    exit_code=`echo $?`
    log_info "Exit code = $exit_code"
    return $exit_code
}

run_kubectl_cmd() {
    export PATH=/opt/cloudera/parcels/ECS/installer/install/bin/linux/:$PATH;
    export KUBECONFIG=${KUBECONFIG:-"/etc/rancher/rke2/rke2.yaml"}
    APISERVER=$(kubectl config view | grep "server:" | awk '{print $2}')
    # Add the apiserver hostname to no proxy
    export NO_PROXY=$(echo $APISERVER | sed -e 's/[^/]*\/\/\([^@]*@\)\?\([^:/]*\).*/\2/')
    if [ -z "${DRY_RUN}" ]; then
        run_cmd "$@"
    else
        dry_run_cmd "$@"
    fi
}

log_info() {
  now="$(date +'%Y-%m-%d %T,%3N')"
  echo "${now} [INFO] ${1}" 1>&2
}

log_error() {
  error="$1"
  now="$(date +'%Y-%m-%d %T,%3N')"
  echo "${now} [ERROR] ${error}" 1>&2
}

subcommand_usage() {
    echo "Usage: ${0} [-d('dry-run')].
    Sub-commands:
                                help    Prints this message
                init-virtual-cluster    Initialize a CDE Virtual Cluster                    -h <virtual-cluster-host> [-a('auto-generate-certs')]
                                                                                            -h <virtual-cluster-host> -c <certificate-path> -k <keyfile-path> [-w('enable wildcard certificate')]
        init-user-in-virtual-cluster    Initialize a user in a CDE Virtual Cluster          -h <virtual-cluster-host> -u <workload-user> -p <principal-file> -k <keytab-file>
        delete-user-in-virtual-cluster  Delete a user in a CDE Virtual Cluster              -h <virtual-cluster-host> -u <workload-user>
 add-spark-config-in-virtual-cluster    Add/update a spark config in a CDE Virtual Cluster  -h <virtual-cluster-host> -c <spark configs> --gang-scheduling <gang scheduling>
                                        & Enable/Disable gang scheduling
             edit-cluster-autoscaler    Modify the duration of node scaling down to         --scale-down-delay-after-add <delay after add>         --scale-down-delay-after-delete <delay after delete>
                                        accelerate the cluster autoscaler's node            --scale-down-delay-after-failure <delay after failure> --scale-down-unneeded-time <unneeded time>
                                        scaling down process.                               --unremovable-node-recheck-timeout <recheck timeout>   -i <interactive menu>" 1>&2
}

auto_create_certs() {
    DOMAIN_NAME=$1
    VC_ID=`echo ${DOMAIN_NAME} | cut -d. -f 1`
    if [ ${#DOMAIN_NAME} -lt 64 ]; then
      log_info "Using the domain name as-is:$DOMAIN_NAME";
    else
      DOMAIN_NAME=${DOMAIN_NAME/$VC_ID/\*};
      log_info "Domain name is too long, generating wild card certificate with the domain:$DOMAIN_NAME";
    fi

    CERT_DIR="${SCRATCH_SPACE}/certs"
    run_cmd "mkdir -p ${CERT_DIR}"

    AUTO_GENERATED_KEY_FILE="ssl.key"
    AUTO_GENERATED_CERT_FILE="ssl.crt"

    cat >${CERT_DIR}/req.conf <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

prompt = no
[req_distinguished_name]
CN = ${DOMAIN_NAME}
[v3_req]
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${DOMAIN_NAME}
EOF

    # Generate the certificate
    run_cmd "openssl req -new -newkey RSA:2048 -nodes -keyout ${CERT_DIR}/${AUTO_GENERATED_KEY_FILE} -out ${CERT_DIR}/ssl.csr -extensions v3_req -config ${CERT_DIR}/req.conf"

    # Sign the certificate
    run_cmd "openssl x509 -req -days 365 -in ${CERT_DIR}/ssl.csr -signkey ${CERT_DIR}/ssl.key -out ${CERT_DIR}/${AUTO_GENERATED_CERT_FILE} -extensions v3_req -extfile ${CERT_DIR}/req.conf"

    # Cleanup
    run_cmd "rm ${CERT_DIR}/req.conf"
    run_cmd "rm ${CERT_DIR}/ssl.csr"
    export CERT_PATH=${CERT_DIR}/${AUTO_GENERATED_CERT_FILE}
    export KEY_PATH=${CERT_DIR}/${AUTO_GENERATED_KEY_FILE}
}

# To delete the Pod, provide one argument which contain the Pod name (case-sensitive), also set "K8_NAMESPACE".
deletePod(){
    # Restart the Pod for updates to reflect
    VC_POD=`kubectl get pods -n "${K8_NAMESPACE}" | grep -e ""${K8_NAMESPACE}"-"$1"-" | awk '{print $1;}'`

    echo $'\n'"deleting pod \""${VC_POD}"\"...."

    kubectl delete pod -n "${K8_NAMESPACE}" "${VC_POD}"
}

subcommand_init_base_cluster() {
    OPTS="${@}"

    SCOPE="dex-base"
    __setup_ingress ${SCOPE} ${OPTS}
}

subcommand_add_spark_config_virtual_cluster() {

    # SubProgram name
    SUBCMD="add-spark-config-in-virtual-cluster"

    help(){
      echo "
This command helps to add default configs in the configmap and allows to disable/enable gangScheduling of your virtual cluster.

Arguments:
    -h                  \$VIRTUAL_CLUSTER_HOST      Virtual cluster host.
    -c                  \$CONFIGS                   Spark configs(can overrides default configs, format 'key1=val1,key2=val2'). <-- use delimiter as \",\" for more than one configs.
    --gang-scheduling   \$STATUS                    Set gangScheduling to 'enable' or 'disable'.

Usage:
  ./${PROG} ${SUBCMD} [arguments]

Example:
  ./${PROG} ${SUBCMD} -h xyz.cde-vjgd8ksl.dsp-azur.xcu2-8y8x.dev.cldr.work -c 'spark.driver.supervise=\"false\",spark.executor.instances=\"2\"' --gang-scheduling disable

Use \"./${PROG} ${SUBCMD} --help\" for more information about a given command."
    }

    # STDERR
    error(){
        echo "$@" 1>&2
    }

    # Message for invalid arguments
    invalid_arg(){
        error "Error: invalid argument: $1"
        help
    }

    # Checking for some vars
    check_vars(){

        if [ -z ${VIRTUAL_CLUSTER_HOST+x} ]; then  # VC_ID must be set
            error "Error: missing virtual cluster host."
            help
            exit 1
        fi

        if [ -z ${STATUS+x} ]; then  # Check if the gangScheduling flag isn't set
            if [ -z ${CONFIGS+x} ]; then  # Atleast one config must be there
                error "Error: please provide atleast one config."
                help
                exit 1
            fi
        else
            if [ $STATUS != "enable" ] && [ $STATUS != "disable" ]; then # Check for valid value of flag
                echo "Error: please answer in enable/disable for gangScheduling flag."
                help
                exit 1
            fi
        fi

        # Check for kubectl access
        if ! kubectl get nodes > /dev/null; then
            error "Error: not able to access the cluster using kubectl."
            exit 1
        fi

        # Check for valid virtual cluster
        if ! kubectl get ns "${K8_NAMESPACE}" > /dev/null; then
            exit 1
        fi
    }

    # Split all the provided configs with delimiter ","
    split(){
        IFS=","
        # Encode the CONFIGS to remove "equal-sign" and replace it with "space + colon"
        CONFIGS=${CONFIGS//=/: }
        read -a CONFIGS_ARR <<< "$CONFIGS"
    }

    # Warning
    warningPOD(){
        echo
        while true; do
            read -p "This action will restart "$1" pod. Please confirm no jobs/sessions are active [y/n]: " yn
            case $yn in
                [Yy]* ) break;;
                [Nn]* ) exit 1;;
                * ) echo "Please answer Y/y or N/n.";;
            esac
        done
    }

    # Enable/Disable Gang-Scheduling
    updateGangScheduling(){
        BOOL=`kubectl get configmap -n "${K8_NAMESPACE}" "${K8_NAMESPACE}"-api-cm -o yaml | sed -n -e '/gangSchedulingEnabled:.*/{n;' -e 'p' -e '}' | cut -c 5-5 | head -n 1`

        if [ $BOOL = 'f' ]; then  # Currently, gangScheduling status is false
            if [ $STATUS = 'enable' ]; then
                echo "updating status..."
                kubectl get configmap -n "${K8_NAMESPACE}" "${K8_NAMESPACE}"-api-cm -o yaml | sed -e '/gangSchedulingEnabled:.*/{n;s/    false/    true/;}' | kubectl apply -f -
                echo "gangScheduling is enabled."
                deletePod "api"  # Call function to restart API pod
            else
                echo 'gangScheduling already disabled!'
            fi
        elif [ $BOOL = 't' ]; then  # Currently, gangScheduling status is true
            if [ $STATUS = 'enable' ]; then
                echo 'gangScheduling already enabled!'
            else
                echo "updating status..."
                kubectl get configmap -n "${K8_NAMESPACE}" "${K8_NAMESPACE}"-api-cm -o yaml | sed -e '/gangSchedulingEnabled:.*/{n;s/    true/    false/;}' | kubectl apply -f -
                echo "gangScheduling is disabled."
                deletePod "api"  # Call function to restart API pod
            fi
        fi
    }

    # Append all the provided configs into the configmap
    updateConfigs(){
        for CONFIG in "${CONFIGS_ARR[@]}";
        do
          echo $'\n'"config : $CONFIG"
          kubectl get configmap -n "${K8_NAMESPACE}" spark-defaults-conf-config-map-"${K8_NAMESPACE}" -o yaml | sed -e "/^kind:.*/i\\
  ${CONFIG}" | kubectl apply -f -
        done
        # Call function to restart Livy pod
        deletePod "livy"
    }

    # Update the configMaps
    updateConfigMap(){

        if ! [ -z ${STATUS+x} ]; then  # GangScheduling flag is set
            warningPOD "API"
            updateGangScheduling
        fi

        if [ "$CONFIGS" != "" ]; then  # Config flag is set
            warningPOD "Livy"
            updateConfigs
        fi

    }

    # Check for provided flags and read the arguments
    while [[ $# -gt 0 ]]
    do
        key=$1
        case $key in
            -h)
                    VIRTUAL_CLUSTER_HOST="$2"
                    K8_NAMESPACE="dex-app-` echo ${VIRTUAL_CLUSTER_HOST} | cut -d . -f 1`"
                    shift
                    shift
                    ;;

            -c)
                    CONFIGS="$2"
                    shift
                    shift
                    ;;

            --gang-scheduling)
                    STATUS="$2"
                    shift
                    shift
                    ;;

            --help)
                    help
                    exit 0
                    ;;

            *)
                    invalid_arg $1
                    exit 1
                    ;;
        esac
    done

    # Checking of vars
    check_vars

    # Function call
    split
    updateConfigMap
}

# Only applicable to AWS
subcommand_edit_cluster_autoscaler() {

    # SubProgram name
    SUBCMD="edit-cluster-autoscaler"
    menu_items=("scale-down-delay-after-add         Duration after scale up when scale down evaluation resumes"
                "scale-down-delay-after-delete      Duration after node deletion when scale down evaluation resumes, defaults to scan-interval"
                "scale-down-delay-after-failure     Duration after scale down failure when scale down evaluation resumes"
                "scale-down-unneeded-time           Duration for a node to be unneeded before it is eligible for scale down"
                "unremovable-node-recheck-timeout   The timeout before we check again a node that couldn't be removed before"
                "Exit")
    menu_size="${#menu_items[@]}"
    menu_limit=$((menu_size - 1))
    # Interaction menu disabled, MENU=1 -> interaction menu enabled
    MENU=0

    help(){
      echo "
This script helps to update the time for scaling down of nodes in autoscaler.

Arguments:
    -i                                  \$INTERACTIVE       To use interactive menu based on arrow keys
    --scale-down-delay-after-add        \$TIME_ADD          Duration after scale up when scale down evaluation resumes, eg 10s, 1h, 5m
    --scale-down-delay-after-delete     \$TIME_DELETE       Duration after node deletion when scale down evaluation resumes, defaults to scan-interval, eg 10s, 1h, 5m
    --scale-down-delay-after-failure    \$TIME_FAILURE      Duration after scale down failure when scale down evaluation resumes, eg 10s, 1h, 5m
    --scale-down-unneeded-time          \$TIME_UNNEEDED     Duration for a node to be unneeded before it is eligible for scale down, eg 10s, 1h, 5m
    --unremovable-node-recheck-timeout  \$TIME_RECHECK      The timeout before we check again a node that couldn't be removed before, eg 10s, 1h, 5m
Usage:
  ./${PROG} ${SUBCMD} [arguments]

Note:
  This script is only applicable to \"AWS - Public Cloud\".

Use \"./${PROG} ${SUBCMD} --help\" for more information about a given command."
    }

    # STDERR
    error(){
        echo -e "$@" 1>&2
        help
        exit 1
    }

    # Message for invalid arguments
    invalid_arg(){
        echo "Error: invalid argument: $1"
        help
        exit 1
    }

    # Checking for some vars
    check_vars(){

        # Check for kubectl access
        if ! kubectl get nodes > /dev/null; then
            echo "Error: not able to access the cluster using kubectl."
            exit 1
        fi

        # Get the autoscaler
        AUTOSCALER=$(kubectl get deployment -n kube-system | grep '.*-autoscaler' | awk '{print $1}')

        # Check for cloudPlatform (only applicable to AWS)
        # Deployment can be "cluster-autoscale"(<1.24 K8s) or "autoscaler-aws-autoscaler"(>=1.24 K8s)
        if [[ $AUTOSCALER != 'cluster-autoscaler' ]] && [[ $AUTOSCALER != 'autoscaler-aws-autoscaler' ]]; then
            error "Error: deployment doesn't exist for cluster-autoscaler(Only AWS is expected to work)."
        fi

        if ! [ -z ${INTERACTIVE+x} ]; then  # Interactive menu is enabled
            MENU=1
        else  # Interactive menu is disabled
            # No other arguments are given
            if [ -z ${TIME_ADD+x} ] && [ -z ${TIME_DELETE+x} ] && [ -z ${TIME_FAILURE+x} ] && [ -z ${TIME_UNNEEDED+x} ] && [ -z ${TIME_RECHECK+x} ]; then  # not set.
                error "Error: no arguments are provided!"
            fi

            if ! [ -z ${TIME_ADD+x} ]; then  # Scale-down-delay-after-add is set
                if validate "$TIME_ADD"; then
                    error "Error: invalid time -> $TIME_ADD."
                fi
            fi

            if ! [ -z ${TIME_DELETE+x} ]; then  # Scale-down-delay-after-delete is set
                if validate "$TIME_DELETE"; then
                    error "Error: invalid time -> $TIME_DELETE."
                fi
            fi

            if ! [ -z ${TIME_FAILURE+x} ]; then  # Scale-down-delay-after-failure is set
                if validate "$TIME_FAILURE"; then
                    error "Error: invalid time -> $TIME_FAILURE."
                fi
            fi

            if ! [ -z ${TIME_UNNEEDED+x} ]; then  # Scale-down-unneeded-time is set
                if validate "$TIME_UNNEEDED"; then
                    error "Error: invalid time -> $TIME_UNNEEDED."
                fi
            fi

            if ! [ -z ${TIME_RECHECK+x} ]; then  # Unremovable-node-recheck-timeout is set
                if validate "$TIME_RECHECK"; then
                    error "Error: invalid time -> $TIME_RECHECK."
                fi
            fi
        fi
    }

    # Print the menu according to selected item
    print_menu()
    {
        selected_item="$1"
        echo -e "\033[32m?\x1B[0m Please choose the option  \033[36m[Use arrows to move, enter to select]\x1B[0m"
        for (( i = 0; i < menu_size; ++i ))
        do
            if [ "$i" = "$selected_item" ]; then
                echo -e "\033[36m> ${menu_items[i]}\x1B[0m"
            else
                echo "   ${menu_items[i]}"
            fi
        done
    }

    # Change the menu according to user's response
    run_menu()
    {
        selected_item="$1"

        clear
        print_menu "$selected_item"

        set +e  # Disabling the set option
        while read -rsn1 input
        do
            case "$input"
            in
                $'\x1B')  # ESC ASCII code
                    read -rsn1 -t 1 input
                    if [ "$input" = "[" ]; then  # Occurs before arrow code
                        read -rsn1 -t 1 input
                        case "$input"
                        in
                            A)  # Up Arrow
                                if [ "$selected_item" -ge 1 ]; then
                                    selected_item=$((selected_item - 1)) # Decrease arrow by 1
                                else
                                    selected_item=$menu_limit # Set arrow to last option
                                fi
                                clear
                                print_menu "$selected_item"
                                ;;
                            B)  # Down Arrow
                                if [ "$selected_item" -lt "$menu_limit" ]; then
                                    selected_item=$((selected_item + 1)) # Increase arrow by 1
                                else
                                    selected_item=0 # Set arrow to first option
                                fi
                                clear
                                print_menu "$selected_item"
                                ;;
                        esac
                    fi
                    read -rsn5 -t 0 # flushing stdin
                    ;;
                "")  # Enter key
                    return "$selected_item"
                    ;;
            esac
        done
        set -e # Enabling the set option
    }

    # Function to validate the time provided by user
    validate () {
        re='^[1-9][0-9]*[mhs]$' # Regex
        if [[ $1 =~ $re ]]; then
            return 1
        fi
        return 0
    }

    inputTime=0
    # To take input from the user while using interactive menu
    input_time () {
        while true
        do
            echo "Enter the time you want to provide for \"$OPT\" :"
            read -r time
            validate "$time"

            if [ $? = 1 ]; then
                inputTime=$time
                return 0
            else
                echo -e "Invalid time. \n"
            fi
            read -rsn5 -t 0 # flushing stdin
        done
    }

    # Update the time in cluster-autoscaler deployment in AWS
    updateAutoScaler(){
        echo -e "updating...\n"

        # Get a name of autoscaler, since liftie changed the format for it for >= 1.24
        AUTOSCALER=$(kubectl get deployment -n kube-system | grep '.*-autoscaler' | awk '{print $1}')

        if ! [ -z ${TIME_ADD+x} ]; then  # Scale-down-delay-after-add is set
            OPT="scale-down-delay-after-add"
            echo "$OPT"="$TIME_ADD"
            kubectl get deployments $AUTOSCALER -n kube-system -o yaml | sed -e "s/        - --$OPT=.*/        - --$OPT=$TIME_ADD/g" | kubectl apply -f -
            echo
            unset TIME_ADD # unset the variable
        fi

        if ! [ -z ${TIME_DELETE+x} ]; then  # Scale-down-delay-after-delete is set
            OPT="scale-down-delay-after-delete"
            echo "$OPT"="$TIME_DELETE"
            kubectl get deployments $AUTOSCALER -n kube-system -o yaml | sed -e "s/        - --$OPT=.*/        - --$OPT=$TIME_DELETE/g" | kubectl apply -f -
            echo
            unset TIME_DELETE # unset the variable
        fi

        if ! [ -z ${TIME_FAILURE+x} ]; then  # Scale-down-delay-after-failure is set
            OPT="scale-down-delay-after-failure"
            echo "$OPT"="$TIME_FAILURE"
            kubectl get deployments $AUTOSCALER -n kube-system -o yaml | sed -e "s/        - --$OPT=.*/        - --$OPT=$TIME_FAILURE/g" | kubectl apply -f -
            echo
            unset TIME_FAILURE # unset the variable
        fi

        if ! [ -z ${TIME_UNNEEDED+x} ]; then  # Scale-down-unneeded-time is set
            OPT="scale-down-unneeded-time"
            echo "$OPT"="$TIME_UNNEEDED"
            kubectl get deployments $AUTOSCALER -n kube-system -o yaml | sed -e "s/        - --$OPT=.*/        - --$OPT=$TIME_UNNEEDED/g" | kubectl apply -f -
            echo
            unset TIME_UNNEEDED # unset the variable
        fi

        if ! [ -z ${TIME_RECHECK+x} ]; then  # Unremovable-node-recheck-timeout is set
            # Check if this configuration already exists or not
            ANS=$(kubectl get deployment cluster-autoscaler -n kube-system -o yaml | grep -q "unremovable-node-recheck-timeout" &&  echo "Found" || echo "Not Found")
            OPT="unremovable-node-recheck-timeout"
            echo "$OPT"="$TIME_RECHECK"
            if [ "$ANS" = "Found" ]; then # Update the existing one
                kubectl get deployments $AUTOSCALER -n kube-system -o yaml | sed -e "s/        - --$OPT=.*/        - --$OPT=$TIME_RECHECK/g" | kubectl apply -f -
            elif [ "$ANS" = "Not Found" ]; then # Add the new configuration
                kubectl get deployment $AUTOSCALER -n kube-system -o yaml | sed -e "/^        env:.*/i\\
        - --$OPT=$TIME_RECHECK" | kubectl apply -f -
            fi
            echo
            unset TIME_RECHECK # unset the variable
        fi
    }


    # Check for provided flags and read the arguments.
    while [[ $# -gt 0 ]]
    do
        key=$1
        case $key in
           -i)
                    INTERACTIVE="$2"
                    shift
                    ;;
            --scale-down-delay-after-add)
                    TIME_ADD="$2"
                    shift
                    shift
                    ;;

            --scale-down-delay-after-delete)
                    TIME_DELETE="$2"
                    shift
                    shift
                    ;;

            --scale-down-delay-after-failure)
                    TIME_FAILURE="$2"
                    shift
                    shift
                    ;;

            --scale-down-unneeded-time)
                    TIME_UNNEEDED="$2"
                    shift
                    shift
                    ;;

            --unremovable-node-recheck-timeout)
                    TIME_RECHECK="$2"
                    shift
                    shift
                    ;;

            --help)
                    help
                    exit 0
                    ;;

            *)
                    invalid_arg "$1"
                    ;;
        esac
    done

    # Checking of vars
    check_vars

    if [ $MENU = 0 ]; then # Interactive menu is disabled, use flags
        updateAutoScaler
    else  # Interactive menu is enabled
        while true
        do
            selected_item=0 # Starting selection with first option

            run_menu "$selected_item"

            menu_result="$?"

            echo

            # Do according to the selected item
            case "$menu_result"
            in
                0)
                    OPT="scale-down-delay-after-add"
                    # Take input for given option
                    input_time
                    TIME_ADD=$inputTime
                    # Call update-auto-scaler function
                    updateAutoScaler

                    sleep 7 # To wait for the errors to print in-case any occurs
                    ;;
                1)
                    OPT="scale-down-delay-after-delete"
                    # Take input for given option
                    input_time
                    TIME_DELETE=$inputTime
                    # Call update-auto-scaler function
                    updateAutoScaler

                    sleep 7 # To wait for the errors to print in-case any occurs
                    ;;
                2)
                    OPT="scale-down-delay-after-failure"
                    # Take input for given option
                    input_time
                    TIME_FAILURE=$inputTime
                    # Call update auto-scaler function
                    updateAutoScaler

                    sleep 7 # To wait for the errors to print in-case any occurs
                    ;;
                3)
                    OPT="scale-down-unneeded-time"
                    # Take input for given option
                    input_time
                    TIME_UNNEEDED=$inputTime
                    # Call update auto-scaler function
                    updateAutoScaler

                    sleep 7 # To wait for the errors to print in-case any occurs
                    ;;

                4)
                    OPT="unremovable-node-recheck-timeout"
                    # Take input for given option
                    input_time
                    TIME_RECHECK=$inputTime
                    # Call update auto-scaler function
                    updateAutoScaler

                    sleep 7 # To wait for the errors to print in-case any occurs
                    ;;
                5)
                    echo 'Exiting....'
                    exit 0
                    ;;
            esac
        done
    fi
}

subcommand_init_virtual_cluster() {
    OPTS="${@}"

    SCOPE="dex-base"
    __setup_ingress ${SCOPE} ${OPTS}
    SCOPE="dex-app"
    __setup_ingress ${SCOPE} ${OPTS}
}

__setup_ingress() {
    SCOPE=${1}
    shift # past scope

    unset OPTIND OPTARG options

    while getopts "h:ac:wk:" options
    do
        case ${options} in
            (h)
                INGRESS_HOST=${OPTARG}
                ENTIRE_HOST=`echo ${INGRESS_HOST}`

                BASE_ID=`echo ${INGRESS_HOST} | cut -d. -f 2 | sed 's/cde-//g'`
                VC_ID=`echo ${INGRESS_HOST} | cut -d. -f 1`

                K8S_NAMESPACE="dex-base-${BASE_ID}" # All changes only in base name-space

                if [ "${SCOPE}" == "dex-base" ]; then
                    INGRESS_PREFIX="dex-base"
                    INGRESS_HOST=`echo ${INGRESS_HOST/${VC_ID}/service}`
                elif [ "${SCOPE}" == "dex-app" ]; then
                    INGRESS_PREFIX="${SCOPE}-${VC_ID}"
                fi

                SECRET_NAME="tls-${INGRESS_PREFIX}"
                DOMAIN_NAME=${INGRESS_HOST}
                ;;
            (a)
                AUTO_CREATE_CERTS="yes"
                ;;
            (c)
                CERT_PATH=${OPTARG}
                # Verify that the cert-path actually exists
                if ! [ -f ${CERT_PATH} ]; then
                    log_error "No cert file found at location: ${CERT_PATH}.."
                    exit 1
                fi
                ;;
            (k)
                KEY_PATH=${OPTARG}
                # Verify that the key-path actually exists
                if ! [ -f ${KEY_PATH} ]; then
                    log_error "No key file found at location: ${KEY_PATH}.."
                    exit 1
                fi
                ;;
            (w)
                WILDCARD_CERTS="yes"
                INGRESS_PREFIX=${ENTIRE_HOST}

                BASE_ID=`echo ${ENTIRE_HOST} | cut -d. -f 1 | cut -d- -f 3`
                VC_ID=`echo ${INGRESS_HOST} | cut -d- -f 1`

                K8S_NAMESPACE="dex-base-${BASE_ID}" # All changes only in base name-space

                if [ "${SCOPE}" == "dex-base" ]; then
                    INGRESS_PREFIX="dex-base"
                    INGRESS_HOST=`echo ${INGRESS_HOST/${VC_ID}/service}`
                elif [ "${SCOPE}" == "dex-app" ]; then
                    INGRESS_PREFIX="${SCOPE}-${VC_ID}"
                fi

                SECRET_NAME="tls-dex-app"
                DOMAIN_NAME=${INGRESS_HOST}
                ;;
            (?)
                log_error "Invalid option ${OPTARG} passed .. "
                exit 1
                ;;
        esac
    done

    if [ -z "${INGRESS_HOST}" ]; then
        log_error "Missing host value. Use -h to specify the host.."
        exit 1
    fi

    if ! [ -z ${AUTO_CREATE_CERTS} ]; then
        if [ -z ${DOMAIN_NAME} ]; then
            log_error "Missing domain-name value. Use -d to specify domain-name if you want to automatically generate certs (-a option).."
            exit 1
        fi
        auto_create_certs ${DOMAIN_NAME}
    else
        if [ -z "${CERT_PATH}" ]; then
            log_error "Missing cert-path. Use -c to specify cert-path if you have one. Otherwise pass -a for auto-cert-generation.."
            exit 1
        elif [ -z "${KEY_PATH}" ]; then
            log_error "Missing key-path. Use -k to specify key-path in a file if you have. Otherwise pass -a for auto-cert-generation.."
            exit 1
        fi
    fi

    log_info "Creating secrets out of TLS certs"
    run_kubectl_cmd "kubectl create secret tls ${SECRET_NAME} --cert=${CERT_PATH} --key=${KEY_PATH} -o yaml --dry-run | kubectl apply -f - -n ${K8S_NAMESPACE}"

    log_info "Checking if ingresses was already fixed before .. "
    rc=`run_kubectl_cmd "kubectl describe ingress ${INGRESS_PREFIX}-api -n ${K8S_NAMESPACE} | grep ${SECRET_NAME} | grep ${INGRESS_HOST} || true"`
    if [ x"${rc}"x != x""x ]; then
         log_info "Ingress ${INGRESS_PREFIX}-api patched already in ${K8S_NAMESPACE} namespace with the updated tls secret"
         return
    fi
    log_info "Ingresses not already fixed, doing so now .. "

    if [ -z ${WILDCARD_CERTS} ] || [ ${WILDCARD_CERTS} != "yes" ]; then
        # Edit the ingress objects to pass along the tls-certificate
        log_info "Injecting TLS certs in the clusters as a secret object"

        SED_CMD="s/^spec:/spec:\n  tls:\n    - hosts:\n      - ${INGRESS_HOST}\n      secretName: ${SECRET_NAME}/g"
        export KUBE_EDITOR="sed -i \"${SED_CMD}\""
        log_info "${KUBE_EDITOR}"

        run_kubectl_cmd "kubectl edit ingress ${INGRESS_PREFIX}-api -n ${K8S_NAMESPACE}"
    else
        log_info "Not editing ingress because of wildcard certificate feature"
    fi

}

subcommand_init_user_in_virtual_cluster() {
    while getopts "h:u:p:k:" options
    do
        case ${options} in
            (h)
                VIRTUAL_CLUSTER_HOST=${OPTARG}
                K8_NAMESPACE="dex-app-`echo ${VIRTUAL_CLUSTER_HOST} | cut -d. -f 1`"
                ;;
            (u) WORKLOAD_USER=${OPTARG} ;;
            (p)
                PRINCIPAL_FILE=${OPTARG}
                # Verify that the principal file actually exists
                if ! [ -f $PRINCIPAL_FILE ]; then
                    log_error "No principal file found at location: ${PRINCIPAL_FILE}.."
                    exit 1
                fi
                ;;
            (k)
                KEYTAB_FILE=${OPTARG}
                # Verify that the keytab files actually exists
                if ! [ -f ${KEYTAB_FILE} ]; then
                    log_error "No keytab file found at location: ${KEYTAB_FILE}.."
                    exit 1
                fi
                ;;
            (?)
                log_error "Invalid option ${OPTARG} passed .. "
                exit 1
                ;;
        esac
    done

    if [ -z "${VIRTUAL_CLUSTER_HOST}" ]; then
        log_error "Missing -host value. Use -h to specify the host.."
        exit 1
    elif [ -z "${WORKLOAD_USER}" ]; then
        log_error "Missing workload-username. Use -u to specify workload-username.."
        exit 1
    elif [ -z "${PRINCIPAL_FILE}" ]; then
        log_error "Missing kerberos-principal. Use -p to specify kerberos-principal in a file.."
        exit 1
    elif [ -z "${KEYTAB_FILE}" ]; then
        log_error "Missing kerberos-keytab file. Use -k to specify kerberos-keytab in a file.."
        exit 1
    fi

    # Encode the WORKLOAD_USER to remove underscores and replace it with triple hyphens
    WORKLOAD_USER="${WORKLOAD_USER//_/---}"

    SECRET_ENCODING_PRINCIPAL=${WORKLOAD_USER}-krb5-principal
    SECRET_ENCODING_KEYTAB=${WORKLOAD_USER}-krb5-secret

    ## TODO: Delete fails on the first try
    log_info "Deleting old secrets in $K8_NAMESPACE.." 2>&1
    run_kubectl_cmd "kubectl delete --ignore-not-found=true secret ${SECRET_ENCODING_KEYTAB}    -n ${K8_NAMESPACE}"
    run_kubectl_cmd "kubectl delete --ignore-not-found=true secret ${SECRET_ENCODING_PRINCIPAL} -n ${K8_NAMESPACE}"

    log_info "Temporarily copying files to desired names.."
    run_cmd "cp ${KEYTAB_FILE}    ${SECRET_ENCODING_KEYTAB}"
    run_cmd "cp ${PRINCIPAL_FILE} ${SECRET_ENCODING_PRINCIPAL}"

    log_info "Creating new secrets in ${K8_NAMESPACE}.."
    run_kubectl_cmd "kubectl create secret generic ${SECRET_ENCODING_PRINCIPAL} --from-file=./${SECRET_ENCODING_PRINCIPAL} -n ${K8_NAMESPACE}"
    run_kubectl_cmd "kubectl create secret generic ${SECRET_ENCODING_KEYTAB}    --from-file=./${SECRET_ENCODING_KEYTAB}     -n ${K8_NAMESPACE}"

    log_info "Deleting temporary files.."
    run_cmd "rm ${SECRET_ENCODING_KEYTAB} ${SECRET_ENCODING_PRINCIPAL}"
}

subcommand_delete_user_in_virtual_cluster() {
    while getopts "h:u:p:k:" options
    do
        case ${options} in
            (h)
                VIRTUAL_CLUSTER_HOST=${OPTARG}
                K8_NAMESPACE="dex-app-`echo ${VIRTUAL_CLUSTER_HOST} | cut -d. -f 1`"
                ;;
            (u) WORKLOAD_USER=${OPTARG} ;;
            (?)
                log_error "Invalid option ${OPTARG} passed .. "
                exit 1
                ;;
        esac
    done

    if [ -z "${VIRTUAL_CLUSTER_HOST}" ]; then
        log_error "Missing -host value. Use -h to specify the host.."
        exit 1
    elif [ -z "${WORKLOAD_USER}" ]; then
        log_error "Missing workload-username. Use -u to specify workload-username.."
        exit 1
    fi

    # Encode the WORKLOAD_USER to remove underscores and replace it with triple hyphens
    WORKLOAD_USER="${WORKLOAD_USER//_/---}"

    SECRET_ENCODING_PRINCIPAL=${WORKLOAD_USER}-krb5-principal
    SECRET_ENCODING_KEYTAB=${WORKLOAD_USER}-krb5-secret

    log_info "Deleting old secrets in $K8_NAMESPACE.." 2>&1
    run_kubectl_cmd "kubectl delete secret ${SECRET_ENCODING_KEYTAB}    -n ${K8_NAMESPACE}"
    run_kubectl_cmd "kubectl delete secret ${SECRET_ENCODING_PRINCIPAL} -n ${K8_NAMESPACE}"
}

main() {

    option=$1
    if [ x"${option}"x == "x-dx" ]; then
        DRY_RUN="(Dry Run: yes) "
        shift
    fi

    subcommand="$1"
    if [ x"${subcommand}x" == "xx" ]; then
        subcommand="help"
    else
        shift # past sub-command
    fi

    case $subcommand in
        help)
            subcommand_usage
            ;;
        init-virtual-cluster)
            subcommand_init_virtual_cluster "$@"
            ;;
        init-base-cluster)
            subcommand_init_base_cluster "$@"
            ;;
        init-user-in-virtual-cluster)
            subcommand_init_user_in_virtual_cluster "$@"
            ;;
        delete-user-in-virtual-cluster)
            subcommand_delete_user_in_virtual_cluster "$@"
            ;;
        add-spark-config-in-virtual-cluster)
            subcommand_add_spark_config_virtual_cluster "$@"
            ;;
        edit-cluster-autoscaler)
            subcommand_edit_cluster_autoscaler "$@"
            ;;
        *)
            # unknown option
            subcommand_usage
            exit 1
            ;;
    esac

    exit 0
}

main "$@"
exit 0
