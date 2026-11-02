#!/usr/bin/env python3
"""Inspect, transplant and verify Bun standalone module graphs.

`bun build --compile` cannot target Android, so the build compiles OpenCode with a
host Bun and grafts the resulting serialised module graph onto the Android Bun
runtime. This module owns that binary format; build-opencode.sh calls it rather
than re-deriving offsets in the bundler script.

File layout (layout "v1", host Bun 1.3.2 and this repo's Android runtime):

    [bun runtime][string data][module list][Offsets][trailer][total: u64 LE]
                                            |<------ module graph ------>|

    * Offsets is 32 bytes: byte_count u64, modules_ptr (u32 offset, u32 length),
      entry_point_id u32, compile_exec_argv (u32 offset, u32 length), flags u32.
    * Unpatched Bun 1.2.x uses a 24-byte Offsets (no compile_exec_argv/flags).
      The Android runtime in this repo is Bun 1.2.13 plus
      patches/bun/android-support.patch, which installs the 32-byte form; host
      Bun 1.3.2 also emits 32 bytes. transplant() preserves the host layout, or
      widens a 24-byte host with an empty argv and zero flags.
    * The trailer is "\\n---- Bun! ----\\n" and sits at EOF - 8 - len(trailer).
    * total_byte_count == file size.
    * Each CompiledModuleGraphFile is a 36-byte stride: 4 StringPointers
      (offset u32, length u32) + 3 u8 flags + 1 padding byte.
    * All StringPointer offsets are relative to the start of the graph.

The runtime's Offsets struct must match exactly; a 24-byte graph installed on
this Android runtime is read as garbage and silently falls back to Bun's CLI.

Layout "v2" (Bun >= 1.3.11): the module struct becomes a 52-byte stride
(6 StringPointers + 4 u8) and Bun appends trailing data after the trailer. This
tool detects that layout and refuses to transplant it because the pinned Android
runtime reads layout v1. See README for the upgrade status.

Everything here is validated against real standalone binaries produced by
bun-v1.2.13 and bun-v1.3.14 (see README "Standalone binary format").
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys

TRAILER = b"\n---- Bun! ----\n"

# Offsets struct sizes, newest first. 1.3.x is 32 bytes, 1.2.x is 24 bytes.
OFFSETS_SIZES = (32, 24)
# CompiledModuleGraphFile strides: 1.3.11+ then <= 1.3.2.
STRIDES = (52, 36)
# Padding/gap tolerated between the module list and the Offsets struct.
MAX_GAP = 16
# Empty string terminator stored after the module list in some versions.
MAX_ARGV_LENGTH = 4096

# Host bundler emits `__reExport(exports_Undici, undici)`; Android Bun exposes the
# same module object under the global `Undici`. The replacement is byte-identical
# in length, so no offsets need rewriting.
UNDICI_SEARCH = b"__reExport(exports_Undici, undici)"
UNDICI_REPLACE = b"__reExport(exports_Undici, Undici)"

EXIT_OK = 0
EXIT_INVALID = 2
EXIT_UNSUPPORTED = 3


class GraphError(RuntimeError):
    pass


class Graph:
    def __init__(self, **fields):
        self.__dict__.update(fields)

    def as_dict(self):
        return dict(self.__dict__)

    def summary(self):
        return (
            f"layout={self.layout} offsets={self.offsets_size}B stride={self.stride}B "
            f"modules={self.module_count} entry={self.entry_point_id} flags={self.flags} "
            f"payload={self.byte_count}B graph_start={self.graph_start} "
            f"trailer={self.trailer_start} file={self.file_size}"
        )


def _parse_at(data, trailer_start, offsets_size, stride):
    """Try to interpret the bytes before `trailer_start` as this format variant.

    Returns a Graph on a structurally valid parse, otherwise None. Validity
    includes every StringPointer landing inside the string-data region, which is
    what distinguishes a 36-byte module list from a 52-byte one.
    """
    offsets_start = trailer_start - offsets_size
    if offsets_start < 0 or trailer_start + len(TRAILER) > len(data):
        return None

    byte_count, modules_offset, modules_length, entry_point_id = struct.unpack_from(
        "<QIII", data, offsets_start
    )

    if byte_count <= 0 or byte_count > offsets_start:
        return None

    graph_start = offsets_start - byte_count
    if graph_start < 0:
        return None

    # The module list must fit in the payload, and the payload must end at the
    # Offsets struct (trailing bytes are a version-specific NUL terminator).
    if modules_offset + modules_length > byte_count:
        return None
    # The gap holds padding and, for 1.3.x hosts, compile_exec_argv string data.
    # It is not referenced by the module list, so allow up to the argv limit.
    gap = byte_count - (modules_offset + modules_length)
    if gap > MAX_ARGV_LENGTH:
        return None

    if modules_length <= 0 or modules_length % stride != 0:
        return None
    module_count = modules_length // stride
    if module_count > 1_000_000 or entry_point_id >= module_count:
        return None

    argv_offset = argv_length = flags = 0
    if offsets_size >= 32:
        argv_offset, argv_length, flags = struct.unpack_from("<III", data, offsets_start + 20)
        if argv_length > MAX_ARGV_LENGTH or argv_offset + argv_length > byte_count:
            return None

    pointers_per_module = (stride - 4) // 8
    for index in range(module_count):
        base = graph_start + modules_offset + index * stride
        for pointer in range(pointers_per_module):
            offset, length = struct.unpack_from("<II", data, base + pointer * 8)
            if offset + length > modules_offset:
                return None

    total = struct.unpack_from("<Q", data, len(data) - 8)[0]
    trailer_end = trailer_start + len(TRAILER)
    if offsets_size == 24:
        is_v1 = stride == 36 and trailer_end + 8 == len(data) and total == len(data)
    else:
        # 1.3.0-1.3.2: 32-byte Offsets, still the 36-byte module struct. The
        # trailing footer/total is not the 24-byte form's, so do not require it.
        is_v1 = stride == 36

    return Graph(
        layout="v1" if is_v1 else "v2",
        offsets_size=offsets_size,
        offsets_start=offsets_start,
        graph_start=graph_start,
        trailer_start=trailer_start,
        byte_count=byte_count,
        modules_offset=modules_offset,
        modules_length=modules_length,
        module_count=module_count,
        entry_point_id=entry_point_id,
        argv_offset=argv_offset,
        argv_length=argv_length,
        flags=flags,
        stride=stride,
        file_size=len(data),
        total_byte_count=total if is_v1 else None,
    )


def parse(data, expect_stride=None):
    """Locate and validate the module graph inside a standalone Bun binary."""
    if len(data) < 64:
        raise GraphError(f"file is too small to be a standalone Bun binary ({len(data)} bytes)")
    if data[:4] != b"\x7fELF":
        raise GraphError("not an ELF binary (missing \\x7fELF magic)")

    trailer_start = data.rfind(TRAILER)
    if trailer_start < 0:
        raise GraphError('trailer "\\n---- Bun! ----\\n" not found; not a standalone Bun binary')

    strides = (expect_stride,) if expect_stride else STRIDES
    candidates = []
    for offsets_size in OFFSETS_SIZES:
        for stride in strides:
            graph = _parse_at(data, trailer_start, offsets_size, stride)
            if graph:
                candidates.append(graph)

    if not candidates:
        raise GraphError(
            f"could not parse a module graph before the trailer at {trailer_start}; "
            "the standalone binary format is not one this tool understands"
        )

    # Prefer a self-consistent layout v1 graph; otherwise report the newest
    # layout we could parse so the caller can explain the incompatibility.
    for graph in candidates:
        if graph.layout == "v1":
            return graph
    return candidates[0]


def read_binary(path):
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError as error:
        raise GraphError(f"{path}: {error.strerror}") from error


def require_v1(graph, path, expect_stride=None):
    if graph.layout != "v1":
        raise GraphError(
            f"{path}: this binary uses the newer standalone layout (v2: "
            f"{graph.offsets_size}-byte Offsets, {graph.stride}-byte module stride, "
            f"{graph.file_size - (graph.trailer_start + len(TRAILER))} trailing bytes after "
            "the trailer). The Android runtime in this pipeline is built from Bun 1.2.x and "
            "reads layout v1, so the graph cannot be transplanted. See README "
            "\"Upgrade status: Bun 1.3.14\"."
        )
    if expect_stride and graph.stride != expect_stride:
        raise GraphError(
            f"{path}: module graph uses a {graph.stride}-byte stride but {expect_stride} "
            "was expected for the pinned Bun version; the host and target Bun builds do "
            "not match"
        )


def patch_undici(graph_bytes, modules_offset):
    """Point the bundled `undici` re-export at the global Android Bun exposes.

    Only the string-data region is touched, so every offset in the module list
    stays valid.
    """
    region = graph_bytes[:modules_offset]
    count = region.count(UNDICI_SEARCH)
    if count:
        graph_bytes[:modules_offset] = region.replace(UNDICI_SEARCH, UNDICI_REPLACE)
    return count


def cmd_inspect(args):
    graph = parse(read_binary(args.binary), args.expect_stride)
    if args.json:
        print(json.dumps(graph.as_dict(), indent=2, sort_keys=True))
    else:
        print(graph.summary())
        print(f"  module list: [{graph.modules_offset}, {graph.modules_offset + graph.modules_length})")
        print(f"  payload:     [{graph.graph_start}, {graph.offsets_start})")
        print(f"  offsets:     [{graph.offsets_start}, {graph.offsets_start + graph.offsets_size})")
        print(f"  trailer:     [{graph.trailer_start}, {graph.trailer_start + len(TRAILER)})")
        print(f"  trailing:    {graph.file_size - (graph.trailer_start + len(TRAILER))} bytes")
    return EXIT_OK if graph.layout == "v1" else EXIT_UNSUPPORTED


def cmd_transplant(args):
    host = read_binary(args.host)
    host_graph = parse(host)
    require_v1(host_graph, args.host, args.expect_stride)

    bun = read_binary(args.bun)
    if bun[:4] != b"\x7fELF":
        raise GraphError(f"{args.bun}: Android Bun runtime is not an ELF binary")
    # The runtime binary must not already carry a graph. The Bun runtime itself
    # contains the trailer string in its data section, so look for a structurally
    # valid graph instead of matching the marker.
    try:
        existing = parse(bun)
    except GraphError:
        existing = None
    if existing is not None and existing.layout == "v1":
        raise GraphError(f"{args.bun}: runtime binary already contains a module graph")

    # Copy the string data + module list, then write the 32-byte Offsets struct
    # the Android runtime expects. The android-support.patch extends 1.2.13's
    # Offsets with compile_exec_argv and flags, matching host Bun 1.3.2. Dropping
    # those fields (the previous 24-byte form) makes the runtime read the module
    # list as offsets and fall back to Bun's CLI.
    payload = bytearray(host[host_graph.graph_start : host_graph.offsets_start])
    patched = patch_undici(payload, host_graph.modules_offset)
    if host_graph.offsets_size == 32:
        offsets = host[host_graph.offsets_start : host_graph.offsets_start + 32]
    elif host_graph.offsets_size == 24:
        offsets = struct.pack(
            "<QIIIIII",
            host_graph.byte_count,
            host_graph.modules_offset,
            host_graph.modules_length,
            host_graph.entry_point_id,
            host_graph.byte_count,
            0,
            0,
        )
    else:
        raise GraphError(
            f"{args.host}: unsupported Offsets size {host_graph.offsets_size}; "
            "expected 32 (Android runtime) or 24 (unpatched 1.2.x)"
        )
    if len(offsets) != 32:
        raise GraphError(f"{args.host}: could not construct 32-byte Offsets")
    graph_bytes = payload + offsets + TRAILER

    total = len(bun) + len(graph_bytes) + 8
    output = bytearray(bun)
    output += graph_bytes
    output += struct.pack("<Q", total)

    out_dir = os.path.dirname(os.path.abspath(args.output))
    os.makedirs(out_dir, exist_ok=True)
    with open(args.output, "wb") as handle:
        handle.write(output)
    os.chmod(args.output, 0o755)

    # Re-parse what we just wrote: the graft must round-trip.
    result = parse(read_binary(args.output), args.expect_stride)
    require_v1(result, args.output, args.expect_stride)
    if result.offsets_size != 32:
        raise GraphError(
            f"{args.output}: wrote a {result.offsets_size}-byte Offsets struct; "
            "the Android runtime reads the 32-byte form"
        )
    if result.total_byte_count != total or total != os.path.getsize(args.output):
        raise GraphError(f"{args.output}: written binary is not self-consistent")

    print(f"Host graph:  {host_graph.summary()}")
    print(f"Undici fix:  {patched} occurrence(s) rewritten")
    print(f"Android Bun: {len(bun)} bytes")
    print(f"Graph:       {len(graph_bytes)} bytes")
    print(f"Output:      {args.output} ({total} bytes, {result.module_count} modules, "
          f"{result.stride}-byte stride)")
    if not patched:
        print("WARNING: undici re-export pattern not found; the bundle may reference a "
              "global that Android Bun does not expose", file=sys.stderr)
    return EXIT_OK


def cmd_verify(args):
    graph = parse(read_binary(args.binary))
    require_v1(graph, args.binary, args.expect_stride)
    if graph.offsets_size != 32:
        raise GraphError(
            f"{args.binary}: {graph.offsets_size}-byte Offsets; "
            "the Android runtime expects the 32-byte form"
        )
    if graph.total_byte_count != graph.file_size:
        raise GraphError(
            f"{args.binary}: total_byte_count={graph.total_byte_count} does not match "
            f"file size {graph.file_size}"
        )
    print(f"OK: {graph.summary()}")

    if args.json:
        print(json.dumps(graph.as_dict(), indent=2, sort_keys=True))
    return EXIT_OK


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Inspect, transplant and verify Bun standalone module graphs."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(sp):
        sp.add_argument("--expect-stride", type=int, choices=STRIDES, default=None,
                        help="require this CompiledModuleGraphFile stride")

    p_inspect = sub.add_parser("inspect", help="print the module graph layout")
    p_inspect.add_argument("binary")
    p_inspect.add_argument("--json", action="store_true")
    add_common(p_inspect)
    p_inspect.set_defaults(func=cmd_inspect)

    p_transplant = sub.add_parser(
        "transplant", help="graft the host module graph onto the Android Bun runtime"
    )
    p_transplant.add_argument("--host", required=True, help="host standalone binary")
    p_transplant.add_argument("--bun", required=True, help="Android Bun runtime binary")
    p_transplant.add_argument("--output", required=True, help="output standalone binary")
    add_common(p_transplant)
    p_transplant.set_defaults(func=cmd_transplant)

    p_verify = sub.add_parser("verify", help="validate a standalone binary")
    p_verify.add_argument("binary")
    p_verify.add_argument("--json", action="store_true")
    add_common(p_verify)
    p_verify.set_defaults(func=cmd_verify)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except GraphError as error:
        print(f"error: {error}", file=sys.stderr)
        return EXIT_INVALID


if __name__ == "__main__":
    sys.exit(main())
