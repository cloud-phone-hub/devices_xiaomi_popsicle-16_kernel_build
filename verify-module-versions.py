#!/usr/bin/env python3
# Copyright (c) 2025-2026 fei_cong(https://github.com/feicong/feicong-course)
# 由 verify-module-versions.js 移植为 Python 实现。
# 校验编译出 .ko 模块的符号版本 CRC 与内核 Module.symvers 是否一致。

import struct
import sys


def parse_symvers(text, label):
    """解析文本格式的 Module.symvers：每行 '0x<CRC> 名 符号owner 类型'。"""
    versions = {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        fields = line.split(None)
        if len(fields) < 4 or len(fields[0]) != 10 or not fields[0].startswith("0x"):
            raise ValueError(f"{label}: invalid Module.symvers line: {line}")
        try:
            crc = int(fields[0][2:], 16)
        except ValueError:
            raise ValueError(f"{label}: invalid Module.symvers line: {line}")
        name = fields[1]
        if not name or name in versions:
            raise ValueError(f"{label}: invalid duplicate symbol {name}")
        versions[name] = crc
    if not versions:
        raise ValueError(f"{label}: empty Module.symvers")
    return versions


def parse_regular(buffer, label):
    """解析 .ko 的 __versions 段（regular 编码）：每条固定 64 字节，偏移 8 起为名。"""
    record_size = 64
    name_offset = 8
    if not buffer or len(buffer) % record_size != 0:
        raise ValueError(f"{label}: invalid __versions size {len(buffer)}")
    versions = {}
    for offset in range(0, len(buffer), record_size):
        end = buffer.find(b"\0", offset + name_offset)
        if end < 0 or end >= offset + record_size:
            raise ValueError(f"{label}: unterminated symbol at {offset}")
        name = buffer[offset + name_offset:end].decode("ascii")
        if not name or name in versions:
            raise ValueError(f"{label}: invalid duplicate symbol {name}")
        versions[name] = struct.unpack_from("<I", buffer, offset)[0]
    return versions


def parse_extended(crcs, names, label):
    """解析 .ko 的 extended 编码：CRC 数组 + 按 \\0 分隔的符号名流。"""
    symbols = [s for s in names.decode("ascii").split("\0") if s]
    if not symbols or len(crcs) != len(symbols) * 4:
        raise ValueError(f"{label}: extended version count mismatch")
    versions = {}
    for index, name in enumerate(symbols):
        if name in versions:
            raise ValueError(f"{label}: duplicate extended symbol {name}")
        versions[name] = struct.unpack_from("<I", crcs, index * 4)[0]
    return versions


def compare_versions(expected, actual, label):
    if len(expected) != len(actual):
        raise ValueError(f"{label}: symbol count {len(actual)}, expected {len(expected)}")
    for name, crc in expected.items():
        if actual.get(name) != crc:
            raise ValueError(f"{label}: CRC mismatch for {name}")


def verify(paths):
    expected = parse_symvers(open(paths[0], encoding="utf8").read(), "expected")
    regular = parse_regular(open(paths[1], "rb").read(), "actual regular")
    extended = parse_extended(
        open(paths[2], "rb").read(), open(paths[3], "rb").read(), "actual extended")
    compare_versions(expected, regular, "expected/actual regular")
    compare_versions(expected, extended, "expected/actual extended")
    compare_versions(regular, extended, "actual regular/extended")
    print(f"module versions OK: {len(regular)} symbols")


def self_test():
    regular = bytearray(64)
    struct.pack_into("<I", regular, 0, 0x12345678)
    regular[8:14] = b"symbol"
    crcs = struct.pack("<I", 0x12345678)
    names = b"symbol\0"
    expected = parse_symvers("0x12345678\tsymbol\tvmlinux\tEXPORT_SYMBOL\n", "self-test")
    compare_versions(expected, parse_regular(bytes(regular), "self-test regular"),
                     "self-test regular")
    compare_versions(expected, parse_extended(crcs, names, "self-test extended"),
                     "self-test extended")
    print("module version verifier self-test OK")


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
    elif len(sys.argv) == 5:
        verify(sys.argv[1:])
    else:
        sys.stderr.write(
            "usage: verify-module-versions.py MODULE_SYMVERS ACTUAL_REGULAR "
            "ACTUAL_EXT_CRCS ACTUAL_EXT_NAMES\n")
        sys.exit(2)


if __name__ == "__main__":
    main()