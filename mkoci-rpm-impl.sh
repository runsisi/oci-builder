if [ "$_CONTAINERS_USERNS_CONFIGURED" != "done" ]; then
    echo >&2 "error - should run with buildah unshare"
    echo >&2
    usage
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
# yum fails if ld.so.cache is removed
# rm -f "$rootfsDir"/etc/ld.so.cache
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
