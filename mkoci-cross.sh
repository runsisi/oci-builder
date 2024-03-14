#!/bin/bash

set -e

#
# usage:
#   buildah unshare sh mkoci-cross.sh
#

podman pull docker.io/library/ubuntu:23.04

buildah rm ubuntu-23.04 2> /dev/null || :
buildah rmi ubuntu-23.04-cross-builder 2> /dev/null || :
buildah from --name ubuntu-23.04 ubuntu:23.04
root=$(buildah mount ubuntu-23.04)

sed -i 's@http://ports.ubuntu.com@http://mirrors.ustc.edu.cn@' $root/etc/apt/sources.list
buildah run ubuntu-23.04 -- apt update
buildah run ubuntu-23.04 -- apt install -y \
make git vim python3 wget unzip \
gcc g++ \
gcc-x86-64-linux-gnu gcc-mingw-w64-x86-64

wget -P $root/opt http://192.168.1.71/xcubed/oci-builder/go1.22.1.linux-arm64.tar.gz
wget -P $root/opt http://192.168.1.71/xcubed/oci-builder/node-v20.11.1-linux-arm64.tar.xz
wget -P $root/opt http://192.168.1.71/xcubed/oci-builder/node-sass.node
tar xzf $root/opt/go1.22.1.linux-arm64.tar.gz -C $root/opt
tar xf $root/opt/node-v20.11.1-linux-arm64.tar.xz -C $root/opt
rm -f $root/opt/go1.22.1.linux-arm64.tar.gz
rm -f $root/opt/node-v20.11.1-linux-arm64.tar.xz

echo 'export PATH=/opt/go/bin:/opt/node-v20.11.1-linux-arm64/bin:$PATH' >> $root/root/.bashrc
echo 'registry=https://registry.npmmirror.com/' >> $root/root/.npmrc
echo 'export SASS_BINARY_PATH=/opt/node-sass.node' >> $root/root/.bashrc

buildah run ubuntu-23.04 -- apt dist-upgrade -y
buildah run ubuntu-23.04 -- apt autoremove
buildah run ubuntu-23.04 -- apt clean
rm -rf $root/var/lib/apt/lists/*
rm -rf $root/usr/{{lib,share}/locale,bin/localedef}
ls --hide ISO8859-1.so --hide gconv-modules $root/usr/lib/aarch64-linux-gnu/gconv 2> /dev/null | xargs -d '\n' -I{} rm -rf $root/usr/lib/aarch64-linux-gnu/gconv/{}
rm -rf $root/usr/share/{man,doc,info}
rm -f $root/etc/ld.so.cache
rm -rf $root/var/cache/ldconfig
mkdir -p -m 755 $root/var/cache/ldconfig

buildah umount ubuntu-23.04

buildah commit ubuntu-23.04 ubuntu-23.04-cross-builder
buildah push --tls-verify=false ubuntu-23.04-cross-builder:latest 192.168.1.71:5000/ubuntu-23.04-cross-builder:$(date +%Y%m%d)
