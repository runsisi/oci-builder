# cleanup on exit

contName=
rootfsDir=
imageId=

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
    $MIRROR gutsy

# tweaks

# prevent init scripts from running during install/update
cat >"$rootfsDir/usr/sbin/policy-rc.d" <<EOF
#!/bin/sh
exit 101
EOF
chmod +x "$rootfsDir/usr/sbin/policy-rc.d"

# prevent upstart scripts from running during install/update
buildah run $contName -- dpkg-divert --local --rename --add /sbin/initctl
cat >"$rootfsDir/sbin/initctl" <<EOF
#!/bin/sh
exit 0
EOF
chmod +x "$rootfsDir/sbin/initctl"

rm -f "$rootfsDir/etc/apt/apt.conf.d/01autoremove-kernels"

if strings "$rootfsDir/usr/bin/dpkg" | grep -q unsafe-io; then
    # force dpkg not to call sync() after package extraction (speeding up installs)
    cat >"$rootfsDir/etc/dpkg/dpkg.cfg.d/oci-apt-speedup" <<EOF
force-unsafe-io
EOF
fi

if [ -d "$rootfsDir/etc/apt/apt.conf.d" ]; then
    aptGetClean='"rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true";'
    cat >"$rootfsDir/etc/apt/apt.conf.d/oci-clean" <<EOF
DPkg::Post-Invoke { ${aptGetClean} };
APT::Update::Post-Invoke { ${aptGetClean} };

Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
EOF

    cat >"$rootfsDir/etc/apt/apt.conf.d/oci-no-languages" <<EOF
Acquire::Languages "none";
EOF

    cat >"$rootfsDir/etc/apt/apt.conf.d/oci-gzip-indexes" <<EOF
Acquire::GzipIndexes "true";
Acquire::CompressionTypes::Order:: "gz";
EOF

    cat >"$rootfsDir/etc/apt/apt.conf.d/oci-autoremove-suggests" <<EOF
Apt::AutoRemove::SuggestsImportant "false";
EOF
fi

# finalize

buildah run $contName -- sh -c 'apt-get -f install -y && apt-get update && apt-get dist-upgrade -y'

buildah run $contName -- apt-get autoremove
buildah run $contName -- apt-get clean
rm -rf "$rootfsDir/var/lib/apt/lists"/*
rm -f "$rootfsDir/var/cache/apt"/*.bin

# locales
rm -rf "$rootfsDir"/usr/{{lib,share}/locale,bin/localedef}
# do not delete ISO8859-1.so, gdb needs it
ls --hide ISO8859-1.so --hide gconv-modules "$rootfsDir"/usr/lib/aarch64-linux-gnu/gconv 2>/dev/null | xargs -d '\n' -I{} rm -rf "$rootfsDir"/usr/lib/aarch64-linux-gnu/gconv/{}
# docs and man pages
rm -rf "$rootfsDir"/usr/share/{man,doc,info}
# ldconfig
rm -f "$rootfsDir"/etc/ld.so.cache
rm -rf "$rootfsDir"/var/cache/ldconfig
mkdir -p -m 755 "$rootfsDir"/var/cache/ldconfig

# commit

buildah config --cmd /bin/bash $contName
imageId=$(buildah commit $contName $IMAGE:$TAG)

# push

if [ $noPush -eq 0 ]; then
    buildah push --tls-verify=false $imageId $REGISTRY/$IMAGE:$TAG
    buildah push --tls-verify=false $imageId $REGISTRY/$IMAGE:latest
    echo ">>> pushed \"$IMAGE:$TAG\" to registry"
fi
