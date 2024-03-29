#!/bin/bash

set -e
set -a

SCRIPT_DIR=$(cd -P $(dirname $0) && pwd -P)
cd $SCRIPT_DIR

if ! command -v dpkg >/dev/null; then
    echo >&2 "error - please run on deb based distributions"
    exit 1
fi

IMAGE=${IMAGE:=kylin-desktop}
TAG=${TAG:=v10-$(date +%Y%m%d)}
MIRROR=${MIRROR:=http://archive.kylinos.cn/kylin/KYLIN-ALL}
SUITE=${SUITE:=10.1-2303-updates}
EXTRA_SUITES=${EXTRA_SUITES:=10.1}
REGISTRY=${REGISTRY:=192.168.1.71:5000}

v4Server=0
v4Desktop=0

noPolicy=0
noPush=0

usage() {
    cat <<EOF
$(basename $0) [OPTIONS]
OPTIONS:
    -h, --help                  Print this help message.
    --v4-server                 Build oci image for Kylin V4 Server.
    --v4-desktop                Build oci image for Kylin V4 Desktop.
    -n, --name <name>           Image name (default "$IMAGE").
    -t, --tag <tag>             Image tag (default "$TAG").
    -m, --mirror <mirror>       APT repository URL (default "$MIRROR").
    --suite                     Enable APT repository suite (default "$SUITE").
    --extra-suites              Enable APT repository extra suites (default "$EXTRA_SUITES").
    -r, --registry <registry>   Image registry to push (default "$REGISTRY").
    --no-policy                 Do not generate default policy (i.e., "insecureAcceptAnything").
    --no-push                   Do not push image to registry (i.e., local container & image will be kept).
EOF
    exit 1
}

# parse options

if ! options=$(getopt -o 'hn:t:m:r:' \
    -l 'help,v4-server,v4-desktop,name:,tag:,mirror:,suite:,extra-suites:,registry:,no-policy,no-push' -- "$@"); then
    usage
fi
eval set -- "$options"
unset options

while [ $# -gt 0 ]; do
    case $1 in
    --v4-server)
        v4Server=1
        v4Desktop=0
        shift
        ;;
    --v4-desktop)
        v4Server=0
        v4Desktop=1
        shift
        ;;
    -n | --name)
        opt_image="$2"
        shift 2
        ;;
    -t | --tag)
        opt_tag="$2"
        shift 2
        ;;
    -m | --mirror)
        MIRROR="$2"
        shift 2
        ;;
    --suite)
        opt_suite="$2"
        shift 2
        ;;
    --extra-suites)
        opt_extra_suites="$2"
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

if [ $v4Server -ne 0 ]; then
    IMAGE=${opt_image:=kylin-server}
    TAG=${opt_tag:=v4-$(date +%Y%m%d)}
    SUITE=${opt_suite:=4.0.2sp4-server}
    EXTRA_SUITES=${opt_extra_suites:=}
fi

if [ $v4Desktop -ne 0 ]; then
    IMAGE=${opt_image:=kylin-desktop}
    TAG=${opt_tag:=v4-$(date +%Y%m%d)}
    SUITE=${opt_suite:=4.0.2sp4}
    EXTRA_SUITES=${opt_extra_suites:=}
fi

if [ $(id -u) -eq 0 ]; then
    echo >&2 "error - please run as a non-root user"
    exit 1
fi

if [ -z "$(command -v buildah || :)" ]; then
    echo >&2 "error - buildah not found"
    exit 1
fi

if [ ! -e /etc/containers/policy.json ]; then
    if [ $noPolicy -ne 0 ]; then
        echo >&2 "error - /etc/containers/policy.json does not exist"
        exit 1
    else
        sudo mkdir -p /etc/containers
        sudo tee /etc/containers/policy.json <<EOF
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

buildah unshare bash -e mkoci-deb-impl.sh
