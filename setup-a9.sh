# Source this file, don't execute it.

congo_root=$(dirname $(readlink -f ${BASH_SOURCE[0]}))/congo
export LD_LIBRARY_PATH=${congo_root}/lib:${congo_root}/lib/grpc_libs
export PYTHONPATH=${media_home}/congo/lib
