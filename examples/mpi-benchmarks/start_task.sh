#!/usr/bin/env bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# This script installs Mellanox OFED drivers on RHEL 8.4
set -x -e

# THIS SCRIPT NEEDS TO BE IDEMPOTENT

INSTALL_PREFIX="/mnt"
TEMP_PREFIX="$(pwd)/temp"
STATUS_PREFIX="${INSTALL_PREFIX}/ts"

# Create the status directory if it doesn't exist
mkdir -p "${STATUS_PREFIX}"

# create modules dir
mkdir -p /usr/share/Modules/modulefiles/mpi/

install_dependencies () {
    dnf install -y git perl tcsh tk tcl gcc-c++ gcc-gfortran kernel-modules-extra kernel-devel nfs4-acl-tools.x86_64 nfs-utils.x86_64
    dnf install -y libtool python36-devel kernel-rpm-macros elfutils-libelf-devel automake rpm-build gdb-headless patch autoconf
    dnf install -y numactl-devel environment-modules
}

install_mofed () {
    status_file="${STATUS_PREFIX}/mofed_installed"
    if [ -f "${status_file}" ]; then
        echo "Mellanox OFED already installed. Skipping."
        return
    fi

    # Download and install Mellanox OFED drivers
    # ref: https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/enable-infiniband#manual-installation
    MOFED_OS_NAME="rhel"
    MOFED_OS_VERSION="8.4"
    MOFED_VERSION="5.8-3.0.7.0"
    MOFED_PLATFORM="x86_64"

    MOFED_TEMP_PREFIX="${TEMP_PREFIX}/mofed"
    mkdir -p "${MOFED_TEMP_PREFIX}"

    pushd "${MOFED_TEMP_PREFIX}"
    mkdir -p src
    mkdir -p tmp

    MOFED_INSTALLER_URL="http://content.mellanox.com/ofed/MLNX_OFED-${MOFED_VERSION}/MLNX_OFED_LINUX-${MOFED_VERSION}-${MOFED_OS_NAME}${MOFED_OS_VERSION}-${MOFED_PLATFORM}.tgz"
    curl -L "${MOFED_INSTALLER_URL}" -o mofed.tgz

    tar -xvf mofed.tgz --strip-components=2 -C "src"

    cd src
    KERNEL=( $(rpm -q kernel | sed 's/kernel\-//g') )
    KERNEL=${KERNEL[-1]}
    yum install -y kernel-devel-${KERNEL}
    ./mlnxofedinstall --tmpdir ${MOFED_TEMP_PREFIX}/tmp --kernel $KERNEL --kernel-sources /usr/src/kernels/${KERNEL} --add-kernel-support --skip-repo
    popd

    # cleanup
    rm -rf "${MOFED_TEMP_PREFIX}"
    touch "${status_file}"
}

install_hpcx () {
    status_file="${STATUS_PREFIX}/hpcx_installed"
    if [ -f "${status_file}" ]; then
        echo "HPC-X already installed. Skipping."
        return
    fi

    HPCX_VERSION="2.13.1"
    HPCX_OS_NAME="redhat8"
    HPCX_CUDA_VERSION="11"
    HPCX_URL="https://content.mellanox.com/hpc/hpc-x/v${HPCX_VERSION}/hpcx-v${HPCX_VERSION}-gcc-MLNX_OFED_LINUX-5-${HPCX_OS_NAME}-cuda${HPCX_CUDA_VERSION}-gdrcopy2-nccl2.12-x86_64.tbz"

    HPCX_INSTALL_DIR="${INSTALL_PREFIX}/hpcx"
    mkdir -p "${HPCX_INSTALL_DIR}"
    curl -L "${HPCX_URL}" -o hpcx.tbz
    tar -xvf hpcx.tbz -C "${HPCX_INSTALL_DIR}" --strip-components=1
    rm hpcx.tbz

    cat << EOF > /usr/share/Modules/modulefiles/mpi/hpcx
#%Module1.0
#
#  HPC-X module for use with 'environment-modules' package:
#
conflict mpi
module load ${HPCX_INSTALL_DIR}/modulefiles/hpcx
EOF
    touch "${status_file}"
}

install_intel_benchmarks () {
    mpi_impl=$1

    # check if arguments are valid
    if [ "$mpi_impl" != "hpcx" ]; then
        echo "Invalid MPI implementation: ${mpi_impl}"
        exit 1
    fi

    status_file="${STATUS_PREFIX}/intel_benchmarks_installed_${mpi_impl}"
    if [ -f "${status_file}" ]; then
        echo "Intel MPI Benchmarks (${mpi_impl}) already installed. Skipping."
        return
    fi

    module purge
    module load mpi/${mpi_impl}

    #--------
    # Install Intel Benchmarks
    #--------
    mkdir -p "${INSTALL_PREFIX}/intel_benchmarks/${mpi_impl}"
    pushd "${INSTALL_PREFIX}/intel_benchmarks/${mpi_impl}"

    curl -L -O https://github.com/intel/mpi-benchmarks/archive/refs/tags/IMB-v2021.3.tar.gz
    tar -xvf IMB-v2021.3.tar.gz --strip-components=1
    rm IMB-v2021.3.tar.gz

    # Build Intel MPI Benchmarks
    make CC=mpicc CXX=mpicxx
    popd

    touch "${status_file}"
}

install_osu_benchmarks () {
    #--------
    # Install OSU Benchmarks
    #--------
    mpi_impl=$1

    # check if arguments are valid
    if [ "$mpi_impl" != "hpcx" ]; then
        echo "Invalid MPI implementation: ${mpi_impl}"
        exit 1
    fi

    status_file="${STATUS_PREFIX}/osu_benchmarks_installed_${mpi_impl}"
    if [ -f "${status_file}" ]; then
        echo "OSU Benchmarks (${mpi_impl}) already installed. Skipping."
        return
    fi

    module purge
    module load mpi/${mpi_impl}

    curl -L https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-7.0.1.tar.gz -O
    tar -xvf osu-micro-benchmarks-7.0.1.tar.gz
    pushd osu-micro-benchmarks-7.0.1

    ./configure CC=mpicc CXX=mpicxx --prefix=/mnt/osu-micro-benchmarks/${mpi_impl}
    make -j $(nproc)
    make install
    popd

    rm -rf osu-micro-benchmarks-7.0.1.tar.gz osu-micro-benchmarks-7.0.1
    touch "${status_file}"
}

hpc_tuning() {
    # Disable some unneeded services by default (administrators can re-enable if desired)
    systemctl disable firewalld

    # Update memory limits
    message="HPC tuning for Azure"
    if ! grep -q "$message" /etc/security/limits.conf; then
        echo "Updating /etc/security/limits.conf"
        cat << EOF >> /etc/security/limits.conf
# $message
*               hard    memlock         unlimited
*               soft    memlock         unlimited
*               hard    nofile          65535
*               soft    nofile          65535
*               hard    stack           unlimited
*               soft    stack           unlimited
EOF
    fi
}

save_batch_utils () {
    # This function has utility functions for Batch tasks
    cat << EOF > /mnt/batch_utils.sh
#!/usr/bin/env bash

# This script has utility functions for Batch tasks
get_openmpi_hosts_with_slots () {
    # convert "<num nodes> <node ip> <num slots> ... " to "<node ip>:<num slots>,<node ip><num slots>, ... "
    echo "\$CCP_NODES_CORES" | awk '{for (i=2; i<=NF; i+=2) {printf "%s:%s,", \$i, \$(i+1)}}' | sed 's/,$//'
}

get_hosts () {
    # convert "<ip>;<ip>;..." to "<ip>\n<ip>\n.."
    echo "\$AZ_BATCH_NODE_LIST" | sed 's/;/\n/g'
}

get_hosts_with_slots () {
    # convert "num nodes> <node ip> <num slots> to "<node ip> slots=<num slots>\n<node ip> slots=<num slots>\n..."
    echo "\$CCP_NODES_CORES" | awk '{for (i=2; i<=NF; i+=2) {printf "%s slots=%s\n", \$i, \$(i+1)}}'
}

export AZ_BATCH_OMPI_HOSTS=\$(get_openmpi_hosts_with_slots)

EOF
}

install_dependencies
install_mofed
install_hpcx
hpc_tuning

source /etc/profile.d/modules.sh
install_intel_benchmarks hpcx
install_osu_benchmarks hpcx

# save batch_utils to /mnt/batch_utils.sh
save_batch_utils
