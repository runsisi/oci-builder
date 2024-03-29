#!/bin/bash

set -e

IMAGE=${IMAGE:=ubuntu-23.04-cross-builder}
TAG=${TAG:=$(date +%Y%m%d)}
REGISTRY=${REGISTRY:=192.168.1.71:5000}

TOOLS_URL=${TOOLS_URL:=http://192.168.1.71/dev-tools}

contName=
imageId=
rootfsDir=
noPush=0

usage() {
    cat <<EOF
buildah unshare sh $(basename $0) [OPTIONS]
OPTIONS:
    -h, --help                  Print this help message.
    -n, --name <name>           Image name (default "$IMAGE").
    -t, --tag <tag>             Image tag (default "$TAG").
    -r, --registry <registry>   Image registry to push (default "$REGISTRY").
    --no-push                   Do not push image to registry (i.e., local container & image will be kept).
EOF
    exit 1
}

# parse options

if ! options=$(getopt -o 'hn:t:r:' -l 'help,name:,tag:,registry:,no-push' -- "$@"); then
    usage
fi
eval set -- "$options"
unset options

while [ $# -gt 0 ]; do
    case $1 in
    -n | --name)
        IMAGE="$2"
        shift 2
        ;;
    -t | --tag)
        TAG="$2"
        shift 2
        ;;
    -r | --registry)
        REGISTRY="$2"
        shift 2
        ;;
    --no-push)
        noPush=1
        shift
        ;;
    -h | --help) usage ;;
    --)
        shift
        break
        ;;
    esac
done

if [ $# -gt 0 ]; then
    echo >&2 "error - excess arguments \"$*\""
    echo >&2
    usage
fi

if [ "$_CONTAINERS_USERNS_CONFIGURED" != "done" ]; then
    echo >&2 "error - should run with buildah unshare"
    echo >&2
    usage
fi

buildahPath="$(command -v buildah || :)"
if [ -z "$buildahPath" ]; then
    echo >&2 "error - buildah not found"
    exit 1
fi

buildah() {
    "$buildahPath" "$@"
}

# cleanup on exit

trap exit INT TERM
trap cleanup_on_exit EXIT
cleanup_on_exit() {
    if [ $noPush -eq 0 ]; then
        test -n "$contName" && buildah rm $contName
        test -n "$imageId" && buildah rmi $imageId
    else
        test -n "$rootfsDir" && buildah umount $contName
        test -n "$contName" && echo ">>> container: $contName"
        test -n "$imageId" && echo ">>> image id:  $imageId"
    fi
}

# setup

podman pull docker.io/library/ubuntu:23.04

contName=$(buildah from ubuntu:23.04)
rootfsDir=$(buildah mount $contName)

# build

sed -i 's@http://ports.ubuntu.com@http://mirrors.ustc.edu.cn@' $rootfsDir/etc/apt/sources.list
buildah run $contName -- apt update
buildah run $contName -- apt install -y \
    make git vim python3 wget unzip \
    gcc g++ \
    gcc-x86-64-linux-gnu gcc-mingw-w64-x86-64

wget -P $rootfsDir/opt $TOOLS_URL/go1.22.1.linux-arm64.tar.gz
wget -P $rootfsDir/opt $TOOLS_URL/node-v20.11.1-linux-arm64.tar.xz
wget -P $rootfsDir/opt $TOOLS_URL/node-sass.node
tar xzf $rootfsDir/opt/go1.22.1.linux-arm64.tar.gz -C $rootfsDir/opt
tar xf $rootfsDir/opt/node-v20.11.1-linux-arm64.tar.xz -C $rootfsDir/opt
rm -f $rootfsDir/opt/go1.22.1.linux-arm64.tar.gz
rm -f $rootfsDir/opt/node-v20.11.1-linux-arm64.tar.xz

echo 'export PATH=/opt/go/bin:/opt/node-v20.11.1-linux-arm64/bin:$PATH' >>$rootfsDir/root/.bashrc
echo 'registry=https://registry.npmmirror.com/' >>$rootfsDir/root/.npmrc
echo 'ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/' >>$rootfsDir/root/.npmrc
echo 'export SASS_BINARY_PATH=/opt/node-sass.node' >>$rootfsDir/root/.bashrc
cat >$rootfsDir/root/.gitconfig <<EOF
[alias]
    br = branch
    st = status
    ci = commit
    co = checkout
    log1 = log --oneline
    cp = cherry-pick
[safe]
    directory = *
EOF

buildah run $contName -- apt dist-upgrade -y
buildah run $contName -- apt autoremove
buildah run $contName -- apt clean
rm -rf $rootfsDir/var/lib/apt/lists/*
rm -rf $rootfsDir/usr/{{lib,share}/locale,bin/localedef}
ls --hide ISO8859-1.so --hide gconv-modules $rootfsDir/usr/lib/aarch64-linux-gnu/gconv 2>/dev/null |
    xargs -d '\n' -I{} rm -rf $rootfsDir/usr/lib/aarch64-linux-gnu/gconv/{}
rm -rf $rootfsDir/usr/share/{man,doc,info}
rm -f $rootfsDir/etc/ld.so.cache
rm -rf $rootfsDir/var/cache/ldconfig
mkdir -p -m 755 $rootfsDir/var/cache/ldconfig

# commit

imageId=$(buildah commit $contName $IMAGE:$TAG)

# push

if [ $noPush -eq 0 ]; then
    buildah push --tls-verify=false $imageId $REGISTRY/$IMAGE:$TAG
    buildah push --tls-verify=false $imageId $REGISTRY/$IMAGE:latest
    echo ">>> pushed \"$IMAGE:$TAG\" to registry"
fi
