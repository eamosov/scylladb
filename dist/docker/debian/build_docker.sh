#!/bin/bash -ex

#
# Copyright (C) 2021-present ScyllaDB
#

#
# SPDX-License-Identifier: AGPL-3.0-or-later
#

product="$(<build/SCYLLA-PRODUCT-FILE)"
version="$(sed 's/-/~/' <build/SCYLLA-VERSION-FILE)"
release="$(<build/SCYLLA-RELEASE-FILE)"

mode="release"

if uname -m | grep x86_64 ; then
  arch="amd64"
fi

if uname -m | grep aarch64 ; then
  arch="arm64"
fi


print_usage() {
    echo "usage: $0 [--mode mode]"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)
            mode="$2"
            shift 2
            ;;
        *)
            print_usage
            ;;
    esac
done

container="$(buildah from docker.io/ubuntu:22.04)"

packages=(
    "build/dist/$mode/debian/${product}_$version-$release-1_$arch.deb"
    "build/dist/$mode/debian/$product-server_$version-$release-1_$arch.deb"
    "build/dist/$mode/debian/$product-conf_$version-$release-1_$arch.deb"
    "build/dist/$mode/debian/$product-kernel-conf_$version-$release-1_$arch.deb"
    "build/dist/$mode/debian/$product-node-exporter_$version-$release-1_$arch.deb"
    "tools/java/build/debian/$product-tools_$version-$release-1_all.deb"
    "tools/java/build/debian/$product-tools-core_$version-$release-1_all.deb"
    "tools/jmx/build/debian/$product-jmx_$version-$release-1_all.deb"
    "tools/cqlsh/build/debian/$product-cqlsh_$version-$release-1_all.deb"
    "tools/python3/build/debian/$product-python3_$version-$release-1_$arch.deb"
)

bcp() { buildah copy "$container" "$@"; }
run() { buildah run "$container" "$@"; }
bconfig() { buildah config "$@" "$container"; }

agent=scylla-manager.tar.gz
bcp "${packages[@]}" packages/

bcp dist/docker/etc etc/
bcp dist/docker/scylla-housekeeping-service.sh /scylla-housekeeping-service.sh

bcp dist/docker/scyllasetup.py /scyllasetup.py
bcp dist/docker/commandlineparser.py /commandlineparser.py
bcp dist/docker/docker-entrypoint.py /docker-entrypoint.py

bcp dist/docker/scylla_bashrc /scylla_bashrc
bcp dist/docker/debian/$agent packages/ 

run apt-get -y clean expire-cache
run apt-get -y update
run apt-get -y upgrade
run apt-get -y --no-install-suggests install dialog apt-utils
run bash -ec "echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections"
run bash -ec "rm -rf /etc/rsyslog.conf"
run apt-get -y --no-install-suggests install hostname supervisor openjdk-11-jre-headless python2 python3 python3-yaml curl rsyslog sudo iproute2 xfsprogs vim less iputils-ping net-tools
run bash -ec "echo LANG=C.UTF-8 > /etc/default/locale"
run bash -ec "dpkg -i packages/*.deb"
run apt-get -y clean all
run tar -C opt/scylladb -xzf packages/$agent scripts
run tar -C etc/scylla -xzf packages/$agent  --strip-components 1 etc/scylla-manager-agent.yaml
run tar -C opt/scylladb/bin -xzf packages/$agent scylla-manager-agent
bcp dist/docker/debian/scylla-manager-agent.conf /etc/supervisord.conf.d/
run rm -rf packages
run bash -ec "cat /scylla_bashrc >> /etc/bash.bashrc"
run mkdir -p /etc/supervisor.conf.d
run mkdir -p /var/log/scylla
run chown -R scylla:scylla /var/lib/scylla
run sed -i -e 's/^SCYLLA_ARGS=".*"$/SCYLLA_ARGS="--log-to-syslog 0 --log-to-stdout 1 --default-log-level info --network-stack posix"/' /etc/default/scylla-server

run mkdir -p /opt/scylladb/supervisor
run touch /opt/scylladb/SCYLLA-CONTAINER-FILE
bcp dist/common/supervisor/scylla-server.sh /opt/scylladb/supervisor/scylla-server.sh
bcp dist/common/supervisor/scylla-jmx.sh /opt/scylladb/supervisor/scylla-jmx.sh
bcp dist/common/supervisor/scylla-node-exporter.sh /opt/scylladb/supervisor/scylla-node-exporter.sh
bcp dist/common/supervisor/scylla_util.sh /opt/scylladb/supervisor/scylla_util.sh

bconfig --env PATH=/opt/scylladb/python3/bin:/usr/bin:/usr/sbin
bconfig --env LANG=C.UTF-8
bconfig --env LANGUAGE=
bconfig --env LC_ALL=C.UTF-8
bconfig --entrypoint  '["/docker-entrypoint.py"]'
bconfig --cmd  ''
bconfig --port 10000 --port 9042 --port 9160 --port 9180 --port 7000 --port 7001 --port 22
bconfig --volume "/var/lib/scylla"

mkdir -p build/$mode/dist/docker/
image="oci-archive:build/$mode/dist/docker/$product-$version-$release"
buildah commit "$container" "$image"

echo "Image is now available in $image."
