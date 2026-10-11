#!/usr/bin/env bash
# Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)

set -euo pipefail

if [[ "$#" -gt 1 || ("$#" -eq 1 && "$1" != "--dry-run") ]]; then
	echo "用法:$0 [--dry-run]" >&2
	exit 2
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_dir="${project_dir}/kernel/source"
prebuilt_dir="${CDH_KERNEL_OUTPUT:-${CDH_KERNEL_PREBUILT:-${project_dir}/out/kernel}}"
prebuilt_parent="$(dirname "${prebuilt_dir}")"
builder_target="android16-6.12"
builder_image="${CDH_KERNEL_BUILDER:-ghcr.io/feicong/droid-ddk:${builder_target}}"
local_version="-4k-cdh"
# 复用判据只认这个串 + kernelrelease（见下方 SHA256SUMS 分支），不含 git HEAD：
# 内核源码/生成头（如 fs/cdh_vendor_rules.h）改动后必须同步把版本号 +1，否则会
# 静默复用旧 Image（v5 = 重定向表加 /vendor/bin/dlkm_loader_mainline）。
build_recipe="lineage-23-gki-virtio-wifi-cdh-modules-v10"
jobs="${CDH_KERNEL_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')}"
volume="cdh-16-kernel-$$_${RANDOM}"
publish_candidate=""
publish_backup=""
source_has_git=0
kernel_config="kernel/build/lineage-kernel.config"
module_dirs=(
	"kernel/modules/goodix_fingerprint"
	"kernel/modules/cpu_probe"
	"kernel/modules/device_info"
	"kernel/modules/virtio_media"
)

if [[ "${1:-}" == "--dry-run" ]]; then
	python3 - "${builder_image}" "${builder_target}" "${jobs}" "${build_recipe}" <<'PY'
import json
import sys

print(json.dumps({
    "builderImage": sys.argv[1],
    "target": sys.argv[2],
    "jobs": sys.argv[3],
    "buildRecipe": sys.argv[4],
    "platformArgument": False,
    "publishedFiles": [
        "Image",
        "config",
        "Module.symvers",
        "kernelrelease.txt",
        "build-recipe.txt",
        "modules/cdh_media.ko",
        "modules/cdh_cpu_probe.ko",
        "modules/cdh_device_info.ko",
        "modules/cdh_goodix_fingerprint.ko",
        "modules/cdh_virt_wifi.ko",
        "modules/cfg80211.ko",
        "modules/mac80211.ko",
        "modules/mac80211_hwsim.ko",
        "modules/libarc4.ko",
        "modules/rfkill.ko",
        "modules/virtio_console.ko",
        "SHA256SUMS",
    ],
}, separators=(",", ":")))
PY
	exit 0
fi

cleanup() {
	docker volume rm -f "${volume}" >/dev/null 2>&1 || true
	if [[ -n "${publish_candidate}" && -d "${publish_candidate}" ]]; then
		rm -rf "${publish_candidate}"
	fi
	if [[ -n "${publish_backup}" && -d "${publish_backup}" && ! -e "${prebuilt_dir}" ]]; then
		mv "${publish_backup}" "${prebuilt_dir}" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

for command_name in docker tar sha256sum; do
	if ! command -v "${command_name}" >/dev/null 2>&1; then
		echo "缺少命令:${command_name}" >&2
		exit 2
	fi
done
for source_file in \
	Makefile \
	arch/arm64/configs/gki_defconfig \
	arch/arm64/configs/lineageos/virtio.config \
	arch/arm64/configs/lineageos/peripheral/wifi.config; do
	if [[ ! -f "${source_dir}/${source_file}" ]]; then
		echo "缺少内核源码文件:${source_dir}/${source_file}" >&2
		exit 3
	fi
done
if [[ -d "${source_dir}/.git" || -f "${source_dir}/.git" ]]; then
	if ! command -v git >/dev/null 2>&1; then
		echo "带Git元数据的内核源码需要git命令" >&2
		exit 2
	fi
	git -C "${source_dir}" rev-parse --verify HEAD >/dev/null
	source_has_git=1
	# macOS默认文件系统无法完整表达只靠大小写区分的内核路径。Git输入从
	# 当前HEAD导入Linux Docker volume，因此先拒绝未提交的工作树修改。
	"$(dirname "${BASH_SOURCE[0]}")/check-kernel-worktree.sh" "${source_dir}"
fi
for module_dir in "${module_dirs[@]}"; do
	if [[ ! -f "${project_dir}/${module_dir}/Kbuild" ]]; then
		echo "缺少内核模块源码:${project_dir}/${module_dir}" >&2
		exit 3
	fi
done
if [[ ! -f "${project_dir}/${kernel_config}" ]]; then
	echo "缺少内核配置:${project_dir}/${kernel_config}" >&2
	exit 3
fi
if [[ "${CDH_REFRESH_KERNEL:-0}" != "1" && \
	-f "${prebuilt_dir}/Image" && \
	-f "${prebuilt_dir}/kernelrelease.txt" && \
	-f "${prebuilt_dir}/build-recipe.txt" && \
	-f "${prebuilt_dir}/SHA256SUMS" && \
	"$(<"${prebuilt_dir}/kernelrelease.txt")" == "6.12.23${local_version}" && \
	"$(<"${prebuilt_dir}/build-recipe.txt")" == "${build_recipe}" ]]; then
	if (cd "${prebuilt_dir}" && sha256sum -c SHA256SUMS >/dev/null); then
		echo "==> 复用Android16派生内核: ${prebuilt_dir}/Image"
		exit 0
	fi
fi

docker volume create "${volume}" >/dev/null
if [[ "${source_has_git}" == "1" ]]; then
	git -C "${source_dir}" archive --format=tar HEAD | \
		docker run --rm -i -v "${volume}:/src" "${builder_image}" \
		bash -c 'set -euo pipefail; tar -xf - -C /src'
else
	COPYFILE_DISABLE=1 tar -C "${source_dir}" -cf - \
		--exclude='./build' --exclude='./out' --exclude='./output' . | \
		docker run --rm -i -v "${volume}:/src" "${builder_image}" \
		bash -c 'set -euo pipefail; tar -xf - -C /src'
fi
COPYFILE_DISABLE=1 tar -C "${project_dir}" -cf - \
	--exclude='*.ko' --exclude='*.o' --exclude='.*.cmd' \
	--exclude='Module.symvers' --exclude='modules.order' \
	"${kernel_config}" "${module_dirs[@]}" | \
	docker run --rm -i -v "${volume}:/src" "${builder_image}" \
	bash -c 'set -euo pipefail; tar -xf - -C /src'

docker run --rm \
	-v "${volume}:/src" \
	-e "CDH_KERNEL_JOBS=${jobs}" \
	-e "CDH_KERNEL_LOCALVERSION=${local_version}" \
	-e "CDH_KERNEL_BUILD_RECIPE=${build_recipe}" \
	"${builder_image}" bash -c '
set -euo pipefail
cd /src
mkdir -p out export/modules
make O=/src/out ARCH=arm64 LLVM=1 gki_defconfig
KCONFIG_CONFIG=/src/out/.config scripts/kconfig/merge_config.sh -m -r \
	/src/out/.config \
	arch/arm64/configs/lineageos/virtio.config \
	arch/arm64/configs/lineageos/peripheral/wifi.config \
	kernel/build/lineage-kernel.config
scripts/config --file out/.config \
	--set-str LOCALVERSION "${CDH_KERNEL_LOCALVERSION}" \
	--disable LOCALVERSION_AUTO \
	--module VIRTIO_CONSOLE
make O=/src/out ARCH=arm64 LLVM=1 olddefconfig
make O=/src/out ARCH=arm64 LLVM=1 -j"${CDH_KERNEL_JOBS}" Image modules
for module_dir in \
	kernel/modules/goodix_fingerprint \
	kernel/modules/cpu_probe \
	kernel/modules/device_info \
	kernel/modules/virtio_media; do
	make O=/src/out ARCH=arm64 LLVM=1 -j"${CDH_KERNEL_JOBS}" M="/src/${module_dir}" modules
done
cp out/arch/arm64/boot/Image export/Image
cp out/.config export/config
cp out/Module.symvers export/Module.symvers
make O=/src/out ARCH=arm64 LLVM=1 -s kernelrelease >export/kernelrelease.txt
for module_name in virtio_console.ko rfkill.ko cfg80211.ko mac80211.ko mac80211_hwsim.ko libarc4.ko cdh_virt_wifi.ko; do
	mapfile -t matches < <(find out -type f -name "${module_name}" -print)
	if [[ "${#matches[@]}" -ne 1 ]]; then
		echo "内核模块数量异常:${module_name} count=${#matches[@]}" >&2
		exit 9
	fi
	cp "${matches[0]}" "export/modules/${module_name}"
done
for module_path in \
	kernel/modules/goodix_fingerprint/cdh_goodix_fingerprint.ko \
	kernel/modules/cpu_probe/cdh_cpu_probe.ko \
	kernel/modules/device_info/cdh_device_info.ko \
	kernel/modules/virtio_media/cdh_media.ko; do
	if [[ ! -s "${module_path}" ]]; then
		echo "内核模块构建产物缺失:${module_path}" >&2
		exit 9
	fi
	cp "${module_path}" export/modules/
done
llvm-strip --strip-debug export/modules/*.ko
printf "%s\n" "${CDH_KERNEL_BUILD_RECIPE}" >export/build-recipe.txt
(cd export && sha256sum Image config Module.symvers kernelrelease.txt build-recipe.txt modules/*.ko >SHA256SUMS)
'

mkdir -p "${prebuilt_dir}"
publish_candidate="$(mktemp -d "${prebuilt_dir}.new.XXXXXX")"
docker run --rm -v "${volume}:/src" "${builder_image}" \
	tar -C /src/export -cf - . | tar -C "${publish_candidate}" -xf -

test "$(<"${publish_candidate}/kernelrelease.txt")" = "6.12.23${local_version}"
test "$(<"${publish_candidate}/build-recipe.txt")" = "${build_recipe}"
(cd "${publish_candidate}" && sha256sum -c SHA256SUMS)
if [[ -e "${prebuilt_dir}" ]]; then
	if [[ ! -d "${prebuilt_dir}" || -L "${prebuilt_dir}" ]]; then
		echo "Android16内核缓存路径不是实际目录:${prebuilt_dir}" >&2
		exit 9
	fi
	publish_backup="${prebuilt_dir}.old.$$.${RANDOM}"
	mv "${prebuilt_dir}" "${publish_backup}"
fi
if [[ -e "${prebuilt_dir}" ]]; then
	echo "Android16内核缓存发布期间出现同名路径:${prebuilt_dir}" >&2
	exit 9
fi
mv "${publish_candidate}" "${prebuilt_dir}"
publish_candidate=""
if [[ -n "${publish_backup}" ]]; then
	rm -rf "${publish_backup}"
	publish_backup=""
fi
echo "==> Android16派生内核构建完成"
echo "    ${prebuilt_dir}/Image"
echo "    ${prebuilt_dir}/modules/{virtio_console,rfkill,cfg80211,mac80211,mac80211_hwsim,libarc4,cdh_virt_wifi,cdh_goodix_fingerprint,cdh_cpu_probe,cdh_device_info,cdh_media}.ko"
