#!/usr/bin/env bash
# =============================================================================
#  Regenerate the committed SPIR-V headers (*_frag.h / *_vert.h / *_comp.h) for the native
#  Vulkan compositor's post-process shaders.
#
#  The Android NDK build does NOT compile GLSL; instead every *.frag / *.vert / *.comp in
#  this directory is pre-compiled to a SPIR-V uint32 array header that is #included
#  by VulkanRendererContext.cpp. Run this whenever you edit a shader, then commit
#  the regenerated *.h alongside the *.frag/*.vert/*.comp source.
#
#  Requires glslangValidator on PATH (e.g. the Vulkan SDK or the termux package).
#
#  Usage:   ./gen_shaders.sh            # regenerate all shaders
#           ./gen_shaders.sh nis crt    # regenerate only the named shaders
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v glslangValidator >/dev/null 2>&1; then
    echo "error: glslangValidator not found on PATH" >&2
    exit 1
fi

gen() {
    local src="$1"          # e.g. nis.frag
    local base="${src%.*}"  # nis
    local ext="${src##*.}"  # frag | vert
    local vn="${base}_code"
    if [ "$ext" = "vert" ]; then
        vn="${base}_vert_code"
    elif [ "$ext" = "comp" ]; then
        vn="${base}_comp_code"
    fi
    local out="${base}_${ext}.h"
    echo "  ${src} -> ${out}  (--vn ${vn})"
    if [ "$(basename "${src}")" = "nis.frag" ] || [ "$ext" = "comp" ]; then
        if [ "$GLSLANG_HAS_OS" -eq 1 ]; then
            glslangValidator -V --target-env vulkan1.0 -Os "${src}" --vn "${vn}" -o "${out}"
        else
            echo "  note: glslangValidator has no -Os support; compiling without optimization" >&2
            glslangValidator -V --target-env vulkan1.0 "${src}" --vn "${vn}" -o "${out}"
        fi
    else
        glslangValidator -V "${src}" --vn "${vn}" -o "${out}"
    fi
}

shaders=()
if [ "$#" -gt 0 ]; then
    for name in "$@"; do
        for f in "${name}.frag" "${name}.vert" "${name}.comp"; do
            [ -f "$f" ] && shaders+=("$f")
        done
    done
else
    for f in *.frag *.vert *.comp; do
        [ -f "$f" ] && shaders+=("$f")
    done
fi

# Probe -Os only when a selected shader uses it. A failed probe must not
# prevent unrelated shaders from being regenerated.
GLSLANG_HAS_OS=0
needs_os=0
for s in "${shaders[@]}"; do
    if [ "$(basename "$s")" = "nis.frag" ] || [ "${s##*.}" = "comp" ]; then
        needs_os=1
        break
    fi
done

if [ "$needs_os" -eq 1 ]; then
    if probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/glslang-os-probe.XXXXXX")"; then
        probe_src="${probe_dir}/probe.comp"
        probe_spv="${probe_dir}/probe.spv"
        if cat > "$probe_src" <<'GLSL' &&
#version 450
layout(local_size_x = 1) in;
void main() {}
GLSL
            glslangValidator -S comp -V --target-env vulkan1.0 -Os "$probe_src" -o "$probe_spv" >/dev/null 2>&1; then
            GLSLANG_HAS_OS=1
        else
            echo "  note: optimizer probe failed; compiling without optimization" >&2
        fi
        rm -rf "$probe_dir" || true
    else
        echo "  note: could not create optimizer probe directory; compiling without optimization" >&2
    fi
fi

for s in "${shaders[@]}"; do
    gen "$s"
done

echo "done."
