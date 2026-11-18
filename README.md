# 静态 AArch64 `updateEngine` 编译说明

本目录提供独立构建静态 AArch64 `updateEngine` 的配方脚本 [build-updateEngine.sh](build-updateEngine.sh)，用于生成 SDK 中 `device/rockchip/common/tools/aarch64/updateEngine` 预置工具。

## 依赖归档与编译标志

脚本固定下载（或复用输出目录中的离线缓存）并校验以下依赖归档的 SHA-256：

- **zlib 1.3.1**（`zlib-1.3.1.tar.xz`，SHA-256：`38ef96b8dfe510d42707d9c781877914792541133e1870841463bfa73f883e32`）
- **bzip2 1.0.8**（`bzip2-1.0.8.tar.gz`，SHA-256：`ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269`）
- **OpenSSL 3.2.1**（`openssl-3.2.1.tar.gz`，SHA-256：`83c7329fe52c850677d75e5d0b0ca245309b97e8ecbcfdc1dfdc4ab9fac35b39`）
- **libcurl 8.6.0**（`curl-8.6.0.tar.xz`，SHA-256：`3ccd55d91af9516539df80625f818c734dc6f2ecf9bada33c76765e99121db15`）

构建 `updateEngine` 时使用 SDK 预置 GCC `10.3-2021.07`（`aarch64-none-linux-gnu-`），并通过命令行覆盖 `Makefile` 默认 `CFLAGS`（避免交叉编译误引入宿主 `/usr/include`），显式启用全部正式标志：

- `RecoveryNoUi=true`（仅构建无 UI 的 `updateEngine`）
- `-DUSE_UPDATEENGINE=ON -DSUCCESSFUL_BOOT=ON -DHAVE_OPENSSL`
- `-D_LARGEFILE_SOURCE -D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64 -O2 -g0 -D_FORTIFY_SOURCE=1 -I. -fPIC`
- `-mcpu=cortex-a53 -fstack-protector-strong`（由 `ARCH_CFLAGS` 控制，对齐原 Buildroot 工具链封装）
- `-static -Wl,--start-group -lcurl -lbz2 -lssl -lcrypto -lz -ldl -lpthread -lc -Wl,--end-group`

## 构建与替换

在 SDK 根目录或本仓库根目录执行（请先提交源码修改，以便 `--version` 生成对应提交的 `GIT_COMMIT_INFO`）：

```bash
./external/recovery/build-updateEngine.sh /tmp/updateengine-build
```

宿主机需具备 `curl`、`tar`、`xz`、`gzip`、`make`、`perl`、`sha256sum` 及 SDK AArch64 GCC 10.3 工具链（可用 `CROSS_COMPILE` 指定其他 `aarch64*-linux-gnu-` 前缀，`JOBS` 控制并行数）。若构建离线环境，可将上述 4 个归档文件预先放入输出目录，脚本校验 SHA-256 通过后直接解压使用。

脚本在独立临时工作目录中完成静态库与二进制构建，不污染源码树；生成 `stripped` 的静态 AArch64 `updateEngine` 并校验 ELF、库版本和 `--version`（若安装了 `qemu-aarch64-static`）后，再替换 SDK 预置工具：

```bash
install -m 0755 /tmp/updateengine-build/updateEngine \
  device/rockchip/common/tools/aarch64/updateEngine
```

若需要直接更新已展开的 rootfs 目录（重新运行 `ubuntu24.04/mk-image.sh` 时会自动通过 `device/rockchip/common/tools/install.sh` 同步）：

```bash
sudo install -m 0755 device/rockchip/common/tools/aarch64/updateEngine \
  ubuntu24.04/binary/usr/bin/updateEngine
```
