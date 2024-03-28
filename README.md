# buildah

容器镜像构建依赖 [buildah](https://github.com/containers/buildah) 命令行工具，该工具没有官方构建好的可执行文件，需要进行本地构建。

Kylin V10 上构建的 buildah 由于依赖高版本 GLIBC，无法在 Kylin V4 系统上运行，但 Kylin V4 上构建的 buildah 可以在 Kylin V10 上运行。

在 Kylin V4 上构建 buildah 会存在一些依赖的问题需要解决（gpgme 及及其依赖的 gpg-error, libassuan 开发包都没有带 `.pc` 文件，需要手工创建）。

可以通过如下链接下载在 Kylin V4 Server 上构建的 buildah (v1.34.1) 可执行文件（可以拷贝到 V4/V10 机器上运行，且不区分 Server/Desktop）。

http://git.xcube.com/xcube/-/packages

# build scripts

mkoci-rpm.sh 用于构建 Kylin V10 Server 容器镜像，支持在 Kylin V10 Server 宿主机上运行。

由于制作基础镜像使用的 rpm 安装源参数读取自宿主机，因此制作不同 Kylin V10 Server 版本镜像（如 2204, 2310 等），需要在安装有不同 Kylin V10 Server 版本的宿主机上运行。

```sh
❯ ./mkoci-rpm.sh -h
mkoci-rpm.sh [OPTIONS]
OPTIONS:
  -h, --help                  Print this help message.
  -n, --name <name>           Image name (default "kylin-server").
  -t, --tag <tag>             Image tag (default "10-20240307").
  -r, --registry <registry>   Image registry to push (default "192.168.1.71:5000").
  --no-policy                 Do not generate default policy (i.e., "insecureAcceptAnything").
  --no-push                   Do not push image to registry (i.e., local container & image will be kept).
```

mkoci-deb.sh 用于构建 Kylin V10 Desktop 以及 Kylin V4 Server/Desktop 容器镜像，支持在 Kylin V10 Desktop 以及 Kylin V4 Server/Desktop 宿主机上运行，可以在同一台机器上完成所有三种系统容器镜像的构建。

由于制作基础镜像使用的 deb 安装源参数来自命令行参数，因此制作不同版本镜像（如 4.0.2sp3, 4.0.2sp3 等），需要通过 `--suite`, `--extra-suites` 指定安装源（当前 V4 默认使用最新的 4.0.2sp4 版本）。

```sh
❯ ./mkoci-deb.sh -h
mkoci-deb.sh [OPTIONS]
OPTIONS:
  -h, --help                  Print this help message.
  --v4-server                 Build oci image for Kylin V4 Server.
  --v4-desktop                Build oci image for Kylin V4 Desktop.
  -n, --name <name>           Image name (default "kylin-desktop").
  -t, --tag <tag>             Image tag (default "v10-20240307").
  -m, --mirror <mirror>       APT repository URL (default "http://archive.kylinos.cn/kylin/KYLIN-ALL").
  --suite                     Enable APT repository suite (default "10.1-2303-updates").
  --extra-suites              Enable APT repository extra suites (default "10.1").
  -r, --registry <registry>   Image registry to push (default "192.168.1.71:5000").
  --no-policy                 Do not generate default policy (i.e., "insecureAcceptAnything").
  --no-push                   Do not push image to registry (i.e., local container & image will be kept).
```

mkoci-cross.sh 用于构建基于 Ubuntu 23.04 的交叉编译容器镜像，镜像架构为 arm64，因此脚本需要在 arm64 机器上运行。

# image building

## Kylin V10 Server

```sh
$ sudo ./mkoci-rpm.sh
```

## Kylin V10 Desktop

```sh
$ sudo ./mkoci-deb.sh
```

## Kylin V4 Server

```sh
$ sudo ./mkoci-deb.sh --v4-server
```

## Kylin V4 Desktop

```sh
$ sudo ./mkoci-deb.sh --v4-desktop
```

## Ubuntu cross builder

```sh
$ buildah unshare sh mkoci-cross.sh
```

# image registry

如果镜像构建成功，默认会推送到如下的镜像仓库，可以通过构建脚本的 `--no-push` 选项禁止这一行为，也可以通过 `--registry` 选项修改默认推送的镜像仓库。

http://192.168.1.71:5000/image/kylin-server

http://192.168.1.71:5000/image/kylin-desktop

http://192.168.1.71:5000/image/ubuntu-23.04-cross-builder
