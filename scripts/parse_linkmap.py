#!/usr/bin/env python3
"""Parse a macOS ld64 linker map file and summarize size by component.

Usage: python3 parse_linkmap.py build/gleepack.map

The macOS linker map has sections like:
  # Object files:
  [  0] linker synthesized
  [  1] /path/to/foo.o
  ...
  # Sections:
  # Address  Size  Segment  Section
  ...
  # Symbols:
  # Address  Size  File  Name
  0x...  0x...  [  1] _symbol_name
  ...
  # Dead Stripped Symbols:
  ...

We parse the Symbols section and attribute each symbol's size to a component
based on the object file path.
"""

import sys
import re
from collections import defaultdict
from pathlib import Path


def classify_object(path: str) -> str:
    """Classify an object file path into a component name."""
    # linker synthesized
    if path == "linker synthesized":
        return "linker"

    # Static NIF archives (from lib/ directories)
    if "/lib/crypto/" in path and ".a(" in path:
        return "nif: crypto"
    if "/lib/asn1/" in path and ".a(" in path:
        return "nif: asn1"

    # OpenSSL (system libcrypto.a)
    if "libcrypto.a" in path:
        return "openssl (libcrypto)"

    # ERTS bundled libraries (from emulator subdirs, as archives)
    if "/zstd/" in path:
        return "erts: zstd"
    if "/pcre/" in path:
        return "erts: pcre"
    if "/ryu/" in path:
        return "erts: ryu"
    if "micro-openssl" in path:
        return "erts: micro-openssl"

    # ERTS internal libs (archives)
    if "liberts_internal" in path:
        return "erts: internal lib"
    if "libethread" in path:
        return "erts: ethread"

    # Direct .o files from the emulator build (obj/.../opt/jit/*.o)
    # The "jit" in the path is the build variant, not the component.
    # Classify by filename.
    basename = Path(path).stem  # e.g. "beam_asm_global"

    # asmjit library
    if "/asmjit/" in path:
        return "jit: asmjit lib"

    # JIT codegen (beam_asm*, beam_jit*, instr_*, process_main, asm_load)
    jit_prefixes = ("beam_asm", "beam_jit", "instr_", "process_main", "asm_load")
    if any(basename.startswith(p) or basename == p for p in jit_prefixes):
        return "jit: codegen"

    # BIF implementations
    if basename.startswith("erl_bif_") or basename == "bif":
        return "erts: BIFs"

    # Allocator subsystem
    if basename.startswith("erl_") and ("alloc" in basename or "fit_alloc" in basename):
        return "erts: allocators"

    # Beam loader/transform
    if basename.startswith("beam_"):
        return "erts: beam loader"

    # NIF/driver infrastructure
    if basename in ("driver_tab", "erl_nif", "erl_drv_thread"):
        return "erts: nif/driver infra"

    # System/OS interface
    sys_files = (
        "sys", "sys_drivers", "sys_float", "sys_time", "sys_signal",
        "erl_main", "erl_child_setup", "unix_prim_file",
        "erl_poll", "erl_check_io",
    )
    if basename in sys_files or basename.startswith("sys_"):
        return "erts: sys (OS interface)"

    # Scheduler/process
    if basename in ("erl_process", "erl_process_dump", "erl_process_lock",
                     "erl_trace", "erl_tracer_nif", "erl_fun",
                     "erl_gc", "erl_message", "erl_proc_sig_queue"):
        return "erts: scheduler/process"

    # I/O and distribution
    if basename.startswith("dist") or basename in ("external", "erl_node_tables",
                                                     "erl_node_container_utils"):
        return "erts: distribution"

    # Port/IO
    if basename in ("io", "erl_io_queue", "erl_port_task", "erl_port",
                     "erl_async"):
        return "erts: port/IO"

    # Core data types
    if basename in ("atom", "big", "binary", "copy", "erl_binary",
                     "erl_bits", "erl_map", "erl_term", "erl_unicode",
                     "erl_utils", "hash", "index", "register",
                     "erl_atom_table", "erl_math", "erl_arith",
                     "erl_db", "erl_db_hash", "erl_db_tree",
                     "erl_db_catree", "erl_db_util",
                     "erl_hashmap", "erl_bs", "erl_md5"):
        return "erts: core data types"

    # Preloaded BEAM code
    if basename == "preload":
        return "erts: preloaded beams"

    # System .tbd stubs
    if path.endswith(".tbd"):
        return "system stubs"

    # Catch-all for remaining emulator .o files
    if "obj/" in path and path.endswith(".o"):
        return "erts: other"

    return f"other: {Path(path).name}"


def parse_map(map_path: str):
    with open(map_path, errors='replace') as f:
        lines = f.readlines()

    # Phase 1: parse object file table
    obj_files = {}  # index -> path
    in_objects = False
    in_symbols = False
    in_dead = False

    component_sizes = defaultdict(int)
    component_symbol_count = defaultdict(int)
    dead_sizes = defaultdict(int)

    for line in lines:
        line = line.rstrip()

        if line.startswith("# Object files:"):
            in_objects = True
            in_symbols = False
            in_dead = False
            continue
        if line.startswith("# Sections:"):
            in_objects = False
            continue
        if line.startswith("# Symbols:"):
            in_symbols = True
            in_objects = False
            in_dead = False
            continue
        if line.startswith("# Dead Stripped Symbols:"):
            in_dead = True
            in_symbols = False
            continue

        if in_objects:
            m = re.match(r'\[\s*(\d+)\]\s+(.*)', line)
            if m:
                idx = int(m.group(1))
                path = m.group(2).strip()
                obj_files[idx] = path

        if in_symbols:
            # Format: 0xADDR  0xSIZE  [IDX] _name
            m = re.match(r'0x[0-9A-Fa-f]+\s+0x([0-9A-Fa-f]+)\s+\[\s*(\d+)\]\s+(.*)', line)
            if m:
                size = int(m.group(1), 16)
                idx = int(m.group(2))
                path = obj_files.get(idx, "unknown")
                component = classify_object(path)
                component_sizes[component] += size
                component_symbol_count[component] += 1

        if in_dead:
            # Dead stripped symbols have a size too
            m = re.match(r'<<dead>>\s+0x([0-9A-Fa-f]+)\s+\[\s*(\d+)\]\s+(.*)', line)
            if m:
                size = int(m.group(1), 16)
                idx = int(m.group(2))
                path = obj_files.get(idx, "unknown")
                component = classify_object(path)
                dead_sizes[component] += size

    return component_sizes, component_symbol_count, dead_sizes, obj_files


def fmt_size(n: int) -> str:
    if n >= 1024 * 1024:
        return f"{n / (1024*1024):.1f} MB"
    if n >= 1024:
        return f"{n / 1024:.1f} KB"
    return f"{n} B"


def main():
    if len(sys.argv) < 2:
        print("Usage: parse_linkmap.py <map_file>", file=sys.stderr)
        sys.exit(1)

    sizes, counts, dead, obj_files = parse_map(sys.argv[1])

    total = sum(sizes.values())
    total_dead = sum(dead.values())

    # Sort by size descending
    sorted_components = sorted(sizes.items(), key=lambda x: -x[1])

    print(f"{'Component':<30} {'Linked':>10} {'Symbols':>8} {'Dead-stripped':>14} {'% of total':>10}")
    print("-" * 76)
    for comp, size in sorted_components:
        pct = 100 * size / total if total else 0
        d = dead.get(comp, 0)
        c = counts.get(comp, 0)
        print(f"{comp:<30} {fmt_size(size):>10} {c:>8} {fmt_size(d):>14} {pct:>9.1f}%")
    print("-" * 76)
    print(f"{'TOTAL':<30} {fmt_size(total):>10} {sum(counts.values()):>8} {fmt_size(total_dead):>14}")

    # Also print the "additional" components (not emulator core/jit)
    print()
    print("=== Additional libraries (not emulator core/jit) ===")
    additional = 0
    for comp, size in sorted_components:
        if not comp.startswith("erts: emulator") and not comp.startswith("erts: jit") and comp != "linker":
            additional += size
    print(f"Total additional: {fmt_size(additional)} ({100*additional/total:.1f}% of binary)")

    # Print what was dead-stripped
    if total_dead:
        print()
        print("=== Dead-stripped by component ===")
        sorted_dead = sorted(dead.items(), key=lambda x: -x[1])
        for comp, size in sorted_dead:
            if size > 0:
                print(f"  {comp:<30} {fmt_size(size):>10}")
        print(f"  {'TOTAL dead-stripped':<30} {fmt_size(total_dead):>10}")


if __name__ == "__main__":
    main()
