#!/usr/bin/env bash
# Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
#
# 检查note13-5G-15内核源码树是否可以作为构建输入。
#
# 内核树里存在只靠大小写区分的同名文件，例如
# include/uapi/linux/netfilter/xt_CONNMARK.h与xt_connmark.h、
# net/netfilter/xt_DSCP.c与xt_dscp.c。macOS默认的APFS大小写不敏感，一对文件只能
# 落地一个，git在core.ignorecase=true下会把另一个报成修改。这类"修改"不是本地
# 编辑，但直接从工作树取源码构建一定会漏掉其中一半。
#
# 本检查区分两种情况：
#   1. 碰撞名称解析为同一文件对象，且当前字节匹配另一成员的HEAD blob：认定为
#      大小写折叠，构建从git对象库读取当前HEAD，脚本报告限制后返回0。
#   2. 其它修改：本地编辑会被git archive静默丢弃，直接失败。

set -euo pipefail

if [[ $# -ne 1 ]]; then
	echo "用法: check-kernel-worktree.sh <kernel-source-dir>" >&2
	exit 2
fi

source_dir="$1"
if [[ ! -d "${source_dir}" ]]; then
	echo "内核源码目录不存在:${source_dir}" >&2
	exit 2
fi
if [[ ! -e "${source_dir}/.git" ]]; then
	echo "内核源码目录不是git工作树:${source_dir}" >&2
	exit 2
fi

tracked="$(git -C "${source_dir}" ls-files)"
collisions="$(printf '%s\n' "${tracked}" | tr 'A-Z' 'a-z' | LC_ALL=C sort | uniq -d)"
# 只扫描一遍 tracked，保留发生大小写碰撞的组（折叠名|原路径|原路径...），
# 供下面对每个修改文件 O(1) 定位候选，避免逐个全量扫 tracked 的 O(n*m)。
collision_groups="$(
	printf '%s\n' "${tracked}" | awk -F'|' '
		{ folded = tolower($0); k[folded] = k[folded] (k[folded] == "" ? "" : "|") $0; c[folded]++ }
		END { for (f in k) if (c[f] > 1) print f "|" k[f] }
	'
)"
modified="$(git -C "${source_dir}" diff --name-only HEAD)"
untracked="$(git -C "${source_dir}" ls-files --others --exclude-standard)"

if [[ -n "${untracked}" ]]; then
	echo "内核工作树存在未跟踪文件，构建只使用当前HEAD，这些文件不会进入产物:" >&2
	printf '%s\n' "${untracked}" >&2
	exit 5
fi

# 报告时保留原始大小写路径，比较时统一折叠成小写。

unexpected=""
case_folded_modified=false
if [[ -n "${modified}" ]]; then
	while IFS= read -r changed; do
		[[ -z "${changed}" ]] && continue
		work_path="${source_dir}/${changed}"
		if [[ ! -e "${work_path}" ]]; then
			# 该跟踪文件在当前工作树缺失（大小写落地缺一半，或已删除）。构建走
			# git archive HEAD，其 HEAD blob 仍会完整导出，产物无损，不算会丢失的修改。
			continue
		fi
		folded="$(printf '%s' "${changed}" | tr 'A-Z' 'a-z')"
		# 该文件若属于某个只靠大小写区分的碰撞组，内容与 HEAD 一致即视为折叠无害。
		found_case_fold=false
		if [[ -n "${collision_groups}" ]]; then
			while IFS= read -r group; do
				[[ -z "${group}" || "${group%%|*}" != "${folded}" ]] && continue
				while IFS= read -r candidate; do
					[[ -z "${candidate}" || "${candidate}" == "${changed}" ]] && continue
					candidate_path="${source_dir}/${candidate}"
					if [[ -e "${candidate_path}" && "${work_path}" -ef "${candidate_path}" ]]; then
						if git -C "${source_dir}" show "HEAD:${candidate}" | cmp -s -- "${work_path}" -; then
							found_case_fold=true
							break
						fi
					fi
				done <<<"$(printf '%s' "${group#*|}" | tr '|' '\n')"
				[[ "${found_case_fold}" == "true" ]] && break
			done <<<"${collision_groups}"
		fi
		if [[ "${found_case_fold}" == "true" ]]; then
			case_folded_modified=true
			continue
		fi
		# 到此处：工作树文件存在，但既非落地缺失也非大小写折叠，即本地真实编辑。
		unexpected="${unexpected}${changed}"$'\n'
	done <<<"${modified}"
fi
unexpected="${unexpected%$'\n'}"

if [[ -n "${unexpected}" ]]; then
	echo "内核工作树存在本地修改，构建从git对象库读取当前HEAD，这些修改会被丢弃:" >&2
	printf '%s\n' "${unexpected}" >&2
	echo "请先在内核仓提交并推送这些改动。" >&2
	exit 5
fi

if [[ "${case_folded_modified}" == "true" ]]; then
	collision_count="$(printf '%s\n' "${collisions}" | wc -l | tr -d ' ')"
	echo "==> 内核树有${collision_count}组只靠大小写区分的文件，当前文件系统大小写不敏感。"
	echo "==> 构建从git对象库读取当前HEAD，不使用工作树，因此这些差异不影响产物。"
	echo "==> 直接对工作树执行内核编译只能在大小写敏感的Linux文件系统上进行。"
fi

exit 0
