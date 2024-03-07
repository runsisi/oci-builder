#!/bin/bash

set -e

if ! command -v dpkg > /dev/null; then
  echo >&2 "error - please run on deb based distributions"
  exit 1
fi

IMAGE=${IMAGE:=kylin-desktop}
TAG=${TAG:=v10-$(date +%Y%m%d)}
SUITE=${SUITE:=10.1-2303-updates}
EXTRA_SUITES=${EXTRA_SUITES:=10.1}
REGISTRY=${REGISTRY:=192.168.1.71:5000}

v4Server=0
v4Desktop=0
contName=
imageId=
rootfsDir=
noPolicy=0
noPush=0

SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)

usage() {
  cat << EOOPTS
$(basename $0) [OPTIONS]
OPTIONS:
  -h, --help                  Print this help message.
  --v4-server                 Build oci image for Kylin V4 Server.
  --v4-desktop                Build oci image for Kylin V4 Desktop.
  -n, --name <name>           Image name (default "$IMAGE").
  -t, --tag <tag>             Image tag (default "$TAG").
  --suite                     Enable apt repository suite (default "$SUITE").
  --extra-suites              Enable apt repository extra suites (default "$EXTRA_SUITES").
  -r, --registry <registry>   Image registry to push (default "$REGISTRY").
  --no-policy                 Do not generate default policy (i.e., "insecureAcceptAnything").
  --no-push                   Do not push image to registry (i.e., local container & image will be kept).
EOOPTS
  exit 1
}

# parse options

if ! options=$(getopt -o 'hn:t:r:' \
    -l 'help,v4-server,v4-desktop,name:,tag:,suite:,extra-suites:,registry:,no-policy,no-push' -- "$@"); then
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
      opt_name="$2"
      shift 2
      ;;
    -t | --tag)
      opt_tag="$2"
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

if [ $(id -u) -ne 0 ]; then
  echo >&2 "error - please run as root"
  exit 1
fi

if [ ! -e /etc/containers/policy.json ]; then
  if [ $noPolicy -ne 0 ]; then
    echo >&2 "error - /etc/containers/policy.json does not exist"
    exit 1
  else
    mkdir -p /etc/containers
    cat > /etc/containers/policy.json <<EOF
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

buildahPath="$(command -v buildah || :)"
if [ -z "$buildahPath" ]; then
  echo >&2 "error - buildah not found"
  exit 1
fi

chrootPath="$(command -v chroot || :)"
if [ -z "$chrootPath" ]; then
  echo >&2 "error - chroot not found"
  exit 1
fi

buildah() {
  "$buildahPath" "$@"
}

chroot() {
  PATH='/usr/sbin:/usr/bin:/sbin:/bin' "$chrootPath" "$rootfsDir" "$@"
}

# cleanup on exit

trap exit INT TERM
trap cleanup_on_exit EXIT
cleanup_on_exit() {
  if [ $noPush -eq 0 ]; then
    test -n "$contName" && buildah rm $contName
    test -n "$imageId" && buildah rmi $imageId
  else
    test -n "$contName" && echo "container: $contName"
    test -n "$imageId" && echo "image id:  $imageId"
  fi
}

# setup

contName=$(buildah from scratch)
rootfsDir=$(buildah mount $contName)

# build

includes=
extra_cmdline=

if [ $v4Server -ne 0 ] || [ $v4Desktop -ne 0 ]; then
  includes="$includes,kylin-keyring"

  # needs zstd support only post impish, i.e., 21.10
  extra_cmdline="$extra_cmdline --extractor dpkg-deb"
  extra_cmdline="$extra_cmdline --no-merged-usr"
fi

if [ -n "$EXTRA_SUITES" ]; then
  extra_cmdline="$extra_cmdline --extra-suites $EXTRA_SUITES"
fi

if [ -n "$includes" ]; then
  extra_cmdline="$extra_cmdline --include $includes"
fi

export DEBOOTSTRAP_DIR="$SCRIPT_DIR/debootstrap"
"$DEBOOTSTRAP_DIR/debootstrap" \
--no-check-gpg \
--components main,universe,multiverse,restricted \
--variant minbase \
$extra_cmdline \
$SUITE "$rootfsDir" \
http://archive.kylinos.cn/kylin/KYLIN-ALL gutsy

# tweaks

# prevent init scripts from running during install/update
cat > "$rootfsDir/usr/sbin/policy-rc.d" <<EOF
#!/bin/sh
exit 101
EOF
chmod +x "$rootfsDir/usr/sbin/policy-rc.d"

# prevent upstart scripts from running during install/update
chroot dpkg-divert --local --rename --add /sbin/initctl
cat > "$rootfsDir/sbin/initctl" <<EOF
#!/bin/sh
exit 0
EOF
chmod +x "$rootfsDir/sbin/initctl"

rm -f "$rootfsDir/etc/apt/apt.conf.d/01autoremove-kernels"

if strings "$rootfsDir/usr/bin/dpkg" | grep -q unsafe-io; then
  # force dpkg not to call sync() after package extraction (speeding up installs)
  cat > "$rootfsDir/etc/dpkg/dpkg.cfg.d/oci-apt-speedup" <<EOF
force-unsafe-io
EOF
fi

if [ -d "$rootfsDir/etc/apt/apt.conf.d" ]; then
  aptGetClean='"rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true";'
  cat > "$rootfsDir/etc/apt/apt.conf.d/oci-clean" <<EOF
DPkg::Post-Invoke { ${aptGetClean} };
APT::Update::Post-Invoke { ${aptGetClean} };

Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
EOF

  cat > "$rootfsDir/etc/apt/apt.conf.d/oci-no-languages" <<EOF
Acquire::Languages "none";
EOF

  cat > "$rootfsDir/etc/apt/apt.conf.d/oci-gzip-indexes" <<EOF
Acquire::GzipIndexes "true";
Acquire::CompressionTypes::Order:: "gz";
EOF

  cat > "$rootfsDir/etc/apt/apt.conf.d/oci-autoremove-suggests" <<EOF
Apt::AutoRemove::SuggestsImportant "false";
EOF
fi

# finalize

chroot sh -c 'apt-get -f install -y && apt-get update && apt-get dist-upgrade -y'

chroot apt-get autoremove
chroot apt-get clean
rm -rf "$rootfsDir/var/lib/apt/lists"/*
rm -f "$rootfsDir/var/cache/apt"/*.bin

# commit

buildah config --cmd /bin/bash $contName
imageId=$(buildah commit $contName $IMAGE:$TAG)

# push

if [ $noPush -eq 0 ]; then
  buildah push --tls-verify=false $imageId $REGISTRY/$IMAGE:$TAG
  echo "success - pushed \"$IMAGE:$TAG\" to registry"
fi
