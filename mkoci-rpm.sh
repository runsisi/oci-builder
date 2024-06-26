#!/bin/bash

set -e

SCRIPT_DIR=$(cd -P $(dirname $0) && pwd -P)
cd $SCRIPT_DIR

if ! command -v rpm >/dev/null; then
    echo >&2 "error - please run on rpm based distributions"
    exit 1
fi

IMAGE=${IMAGE:=kylin-server-v10}
TAG=${TAG:=$(date +%Y%m%d)}
REGISTRY=${REGISTRY:=192.168.1.71:5000}

noPolicy=0
noPush=0

install_packages="coreutils bash rootfiles yum"

usage() {
    cat <<EOF
$(basename $0) [OPTIONS]
OPTIONS:
    -h, --help                  Print this help message.
    -n, --name <name>           Image name (default "$IMAGE").
    -t, --tag <tag>             Image tag (default "$TAG").
    -r, --registry <registry>   Image registry to push (default "$REGISTRY").
    --no-policy                 Do not generate default policy (i.e., "insecureAcceptAnything").
    --no-push                   Do not push image to registry (i.e., local container & image will be kept).
EOF
    exit 1
}

# parse options

if ! options=$(getopt -o 'hn:t:r:' -l 'help,name:,tag:,registry:,no-policy,no-push' -- "$@"); then
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
    --no-policy)
        noPolicy=1
        shift
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

if [ $(id -u) -ne 0 ]; then
    echo >&2 "error - please run as root"
    exit 1
fi

if [ -z "$(command -v buildah || :)" ]; then
    echo >&2 "error - buildah not found"
    exit 1
fi

if [ "$_CONTAINERS_USERNS_CONFIGURED" = "done" ]; then
    echo >&2 "error - please do not run under buildah unshare"
    exit 1
fi

if [ ! -e /etc/containers/policy.json ]; then
    if [ $noPolicy -ne 0 ]; then
        echo >&2 "error - /etc/containers/policy.json does not exist"
        exit 1
    else
        mkdir -p /etc/containers
        cat >/etc/containers/policy.json <<EOF
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ]
}
EOF
    fi
fi

# cleanup on exit

contName=
rootfsDir=
imageId=

trap exit INT TERM
trap cleanup_on_exit EXIT
cleanup_on_exit() {
    rm -f $yum_config

    if [ $noPush -eq 0 ]; then
        test -n "$contName" && buildah rm $contName
        test -n "$imageId" && buildah rmi -f $imageId
    else
        test -n "$rootfsDir" && buildah umount $contName
        test -n "$contName" && echo ">>> container: $contName"
        test -n "$imageId" && echo ">>> image id:  $imageId"
    fi
}

# setup

contName=$(buildah from scratch)
rootfsDir=$(buildah mount $contName)

# build

if [ -f /etc/dnf/dnf.conf ] && command -v dnf >/dev/null; then
    alias yum=dnf
fi

yum_config=$(mktemp)

cat >$yum_config <<EOF
[mkoci]
name = mkoci
baseurl = file:///$SCRIPT_DIR/kylin
gpgcheck = 0
EOF

mkdir -m 755 "$rootfsDir"/dev
mknod -m 600 "$rootfsDir"/dev/console c 5 1
mknod -m 600 "$rootfsDir"/dev/initctl p
mknod -m 666 "$rootfsDir"/dev/full c 1 7
mknod -m 666 "$rootfsDir"/dev/null c 1 3
mknod -m 666 "$rootfsDir"/dev/ptmx c 5 2
mknod -m 666 "$rootfsDir"/dev/random c 1 8
mknod -m 666 "$rootfsDir"/dev/tty c 5 0
mknod -m 666 "$rootfsDir"/dev/tty0 c 4 0
mknod -m 666 "$rootfsDir"/dev/urandom c 1 9
mknod -m 666 "$rootfsDir"/dev/zero c 1 5

if [ -n "$install_packages" ]; then
    yum -c "$yum_config" --installroot="$rootfsDir" --releasever=/ --setopt=tsflags=nodocs \
        --setopt=group_package_types=mandatory -y install $install_packages
fi

cat >"$rootfsDir"/etc/sysconfig/network <<EOF
NETWORKING=yes
HOSTNAME=localhost.localdomain
EOF

# finalize

yum -c $yum_config --installroot="$rootfsDir" --refresh -y upgrade

yum -c $yum_config --installroot="$rootfsDir" -y clean all

# locales
rm -rf "$rootfsDir"/usr/{{lib,share}/locale,bin/localedef,sbin/build-locale-archive}
# do not delete ISO8859-1.so, gdb needs it
ls --hide ISO8859-1.so --hide gconv-modules "$rootfsDir"/usr/lib/gconv 2>/dev/null |
    xargs -d '\n' -I{} rm -rf "$rootfsDir"/usr/lib/gconv/{}
ls --hide ISO8859-1.so --hide gconv-modules "$rootfsDir"/usr/lib64/gconv 2>/dev/null |
    xargs -d '\n' -I{} rm -rf "$rootfsDir"/usr/lib64/gconv/{}
# docs and man pages
rm -rf "$rootfsDir"/usr/share/{man,doc,info,gnome/help}
# cracklib
rm -rf "$rootfsDir"/usr/share/cracklib
# i18n
rm -rf "$rootfsDir"/usr/share/i18n
# yum cache
rm -rf "$rootfsDir"/var/cache/yum
mkdir -p -m 755 "$rootfsDir"/var/cache/yum
# sln
rm -rf "$rootfsDir"/sbin/sln
# ldconfig
# on kylin yum fails if ld.so.cache is removed
# rm -f "$rootfsDir"/etc/ld.so.cache
rm -rf "$rootfsDir"/var/cache/ldconfig
mkdir -p -m 755 "$rootfsDir"/var/cache/ldconfig

# commit

buildah config --cmd /bin/bash $contName
imageId=$(buildah commit $contName $IMAGE:$TAG)

buildah tag $imageId $IMAGE:latest

# push

if [ $noPush -eq 0 ]; then
    buildah push --tls-verify=false $imageId $REGISTRY/$IMAGE:$TAG
    buildah push --tls-verify=false $imageId $REGISTRY/$IMAGE:latest
    echo ">>> pushed \"$IMAGE:$TAG\" to registry"
fi
