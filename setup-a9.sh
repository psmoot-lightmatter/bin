#!/bin/bash
# Source this file, don't execute it.
# Or execute with --deploy <ip-address> to copy to remote target.

# Handle command line arguments if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$1" == "--deploy" && -n "$2" ]]; then
        ip_address="$2"
        script_path="$(readlink -f "${0}")"
        remote_path="/run/media/root-mmcblk0p2/home/$USER/setup-a9.sh"

        echo "Deploying setup-a9.sh to ${ip_address}:${remote_path}"
        scp "$script_path" "petalinux@${ip_address}:${remote_path}"
        exit $?
    elif [[ "$1" == "--deploy" ]]; then
        echo "Error: --deploy option requires an IP address"
        echo "Usage: $0 --deploy <ip-address>"
        exit 1
    else
        echo "Usage: $0 --deploy <ip-address>"
        echo "Or source this file to set up environment variables"
        exit 1
    fi
fi

congo_root=$(dirname $(readlink -f ${BASH_SOURCE[0]}))/congo
export LD_LIBRARY_PATH=${congo_root}/lib:${congo_root}/lib/grpc_libs
export PYTHONPATH=${congo_root}/lib

source /run/media/root-mmcblk0p2/home/petalinux/notebook/test_env/bin/activate
