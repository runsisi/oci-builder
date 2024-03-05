#!/bin/bash

set -e

: IMAGE=${IMAGE:=kylin-desktop}
: TAG=${TAG:=4}
: REGISTRY=${REGISTRY:=192.168.1.71:5000}

: SUITE=${SUITE:=10.1-2303-updates}
: EXTRA_SUITES=${EXTRA_SUITES:=10.1}

contName=
imageId=
buildDir=
rootfsDir=
noPolicy=0
noPush=0

SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)

usage() {
  cat << EOOPTS
$(basename $0) [OPTIONS]
OPTIONS:
  -h, --help                  Print this help message.
  -n, --name <name>           Image name (default "$IMAGE").
  -t, --tag <tag>             Image tag (default "$TAG").
  -r, --registry <registry>   Image registry to push (default "$REGISTRY").
  --no-policy                 Do not generate default policy (i.e., "insecureAcceptAnything").
  --no-push                   Do not push image to registry (i.e., local image will be kept).
EOOPTS
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
  echo >&2 "error: please run as root."
  exit 1
fi

if [ ! -e /etc/containers/policy.json ]; then
  if [ $noPolicy -gt 0 ]; then
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

podmanPath="$(command -v podman || :)"
dockerPath="$(command -v docker || :)"

if [ -n "$podmanPath" ]; then
  docker() {
    "$podmanPath" "$@"
  }
elif [ -n "$dockerPath" ]; then
  docker() {
      "$dockerPath" "$@"
    }
else
  echo >&2 "error: podman & docker not found."
  echo >&2
  usage
fi

chrootPath="$(command -v chroot || :)"
if [ -z "$chrootPath" ]; then
  echo >&2 "error: chroot not found."
  echo >&2
  usage
fi

chroot() {
  PATH='/usr/sbin:/usr/bin:/sbin:/bin' "$chrootPath" "$rootfsDir" "$@"
}

# cleanup on exit

trap exit INT TERM
trap cleanup_on_exit EXIT
cleanup_on_exit() {
  if [ $noPush -eq 0 ]; then
    rm -rf "$buildDir"
  fi

  test -n "$contName" && buildah rm $contName
  if [ $noPush -eq 0 ]; then
    test -n "$imageId" && buildah rmi $imageId
  fi
}

# setup

contName=$(buildah from scratch)
buildDir="$(mktemp -d ${TMPDIR:-/var/tmp}/mkoci.XXXXXXXXXX)"
rootfsDir="$buildDir/rootfs"

# build

export DEBOOTSTRAP_DIR="$SCRIPT_DIR/debootstrap"
"$DEBOOTSTRAP_DIR/debootstrap" \
--no-check-gpg \
--components main,universe,multiverse,restricted \
--variant minbase \
--include vim \
--extra-suites $EXTRA_SUITES \
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

chroot sh -c 'apt-get update && apt-get dist-upgrade -y'

chroot apt-get autoremove
chroot apt-get clean
chroot rm -rf /var/lib/apt/lists/*
chroot rm -f /var/cache/apt/*.bin

# commit

# Docker mounts tmpfs at /dev and procfs at /proc so we can remove them
rm -rf "$rootfsDir/dev" "$rootfsDir/proc"
mkdir -p "$rootfsDir/dev" "$rootfsDir/proc"

# make sure /etc/resolv.conf has something useful in it
mkdir -p "$rootfsDir/etc"
cat > "$rootfsDir/etc/resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

tarFile="$buildDir/rootfs.tar"
touch "$tarFile"

tar --numeric-owner --create --auto-compress --file "$tarFile" --directory "$rootfsDir" --transform='s,^./,,' .

cat > "$buildDir/Dockerfile" << EOF
FROM scratch
ADD $(basename "$tarFile") /
EOF

# if our generated image has a decent shell, let's set a default command
for shell in /bin/bash /usr/bin/fish /usr/bin/zsh /bin/sh; do
  if [ -x "$rootfsDir/$shell" ]; then
    echo 'CMD ["'"$shell"'"]' >> "$buildDir/Dockerfile"
    break
  fi
done

docker build -t $TAG "$buildDir"


buildah config --cmd /bin/bash $contName
imageId=$(buildah commit $contName $IMAGE:$TAG)

# push

if [ $noPush -eq 0 ]; then
  buildah push --tls-verify=false $imageId $REGISTRY/$IMAGE:$TAG
fi
