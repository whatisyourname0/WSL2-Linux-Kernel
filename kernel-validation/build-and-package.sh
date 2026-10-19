#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

expected_revision=${EXPECTED_SOURCE_COMMIT:?EXPECTED_SOURCE_COMMIT is required}
repository=${SOURCE_REPOSITORY:?SOURCE_REPOSITORY is required}
source_ref=${SOURCE_REF:?SOURCE_REF is required}
source_dir=${SOURCE_DIR:?SOURCE_DIR is required}
build_root=${BUILD_ROOT:?BUILD_ROOT is required}
output_dir=${OUTPUT_DIR:?OUTPUT_DIR is required}
jobs=${JOBS:-2}
arch=x86

[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid expected commit SHA." >&2; exit 2; }
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo "JOBS must be a positive integer." >&2; exit 2; }
mkdir -p "$build_root" "$output_dir"
exec > >(tee -a "$output_dir/build.log") 2>&1

source_revision=$(git -C "$source_dir" rev-parse HEAD)
[[ "$source_revision" == "$expected_revision" ]] || {
    echo "Source checkout mismatch: expected $expected_revision, got $source_revision." >&2
    exit 1
}
source_tree=$(git -C "$source_dir" rev-parse HEAD^{tree})
config_path="$source_dir/arch/x86/configs/config-wsl"
[[ -s "$config_path" ]] || { echo "Submitted WSL config is missing." >&2; exit 1; }
source_status=$(git -C "$source_dir" status --porcelain --untracked-files=all)
[[ -z "$source_status" ]] || { printf 'Source checkout is dirty:\n%s\n' "$source_status" >&2; exit 1; }

build_dir="$build_root/kbuild"
modules_dir="$build_root/modules"
headers_dir="$build_root/headers"
perf_build_dir="$build_root/perf-build"
perf_dir="$build_root/perf"
mkdir -p "$build_dir" "$modules_dir" "$headers_dir" "$perf_build_dir" "$perf_dir"
cp -- "$config_path" "$build_dir/.config"

export TZ=UTC
export KBUILD_BUILD_USER=github-actions
export KBUILD_BUILD_HOST=ubuntu-24.04
export KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git -C "$source_dir" show -s --format=%ct "$source_revision")
export KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_TIMESTAMP=$(git -C "$source_dir" show -s --format=%cI "$source_revision")

echo "Source repository: $repository"
echo "Source ref: $source_ref"
echo "Verified source commit: $source_revision"
echo "Source tree: $source_tree"
echo "Submitted config blob: $(git -C "$source_dir" rev-parse "$source_revision:arch/x86/configs/config-wsl")"
echo "Build jobs: $jobs"
echo "Build root: runner temporary storage"
gcc --version | head -n 1
as --version | head -n 1
ld --version | head -n 1

make -s -C "$source_dir" O="$build_dir" ARCH="$arch" KCONFIG_CONFIG="$build_dir/.config" olddefconfig

required_config=(
    CONFIG_64BIT=y
    CONFIG_MODULES=y
    CONFIG_MODVERSIONS=y
    CONFIG_SND=m
    CONFIG_SND_PCM=m
    CONFIG_SND_JACK=y
    CONFIG_SND_JACK_INPUT_DEV=y
    CONFIG_SND_VIRTIO=m
    CONFIG_VIRTIO=y
)
for option in "${required_config[@]}"; do
    grep -qxF "$option" "$build_dir/.config" || {
        echo "Required submitted config option did not resolve: $option" >&2
        exit 1
    }
done
cp -- "$build_dir/.config" "$output_dir/kernel_config.resolved"
"$source_dir/scripts/diffconfig" "$config_path" "$build_dir/.config" > "$output_dir/kernel_config.diff"

kernel_release=$(make -s -C "$source_dir" O="$build_dir" ARCH="$arch" KCONFIG_CONFIG="$build_dir/.config" kernelrelease)
printf '%s\n' "$kernel_release" | tee "$output_dir/kernel.release"

echo "Building full x86 WSL kernel and configured modules."
make -C "$source_dir" O="$build_dir" ARCH="$arch" KCONFIG_CONFIG="$build_dir/.config" -j"$jobs" bzImage modules

module_path="$build_dir/sound/virtio/virtio_snd.ko"
symvers_path="$build_dir/Module.symvers"
kernel_image_path="$build_dir/arch/x86/boot/bzImage"
for required in "$module_path" "$symvers_path" "$kernel_image_path" "$build_dir/System.map"; do
    [[ -s "$required" ]] || { echo "Required full-build output is missing: $required" >&2; exit 1; }
done
module_vermagic=$(modinfo -F vermagic "$module_path")
[[ "${module_vermagic%% *}" == "$kernel_release" ]] || {
    echo "virtio_snd.ko vermagic does not match kernel release $kernel_release." >&2
    exit 1
}
module_depends=$(modinfo -F depends "$module_path")
[[ -n "$module_depends" ]] || { echo "virtio_snd.ko has no recorded module dependencies." >&2; exit 1; }

echo "Installing all configured modules into a private staging path."
make -C "$source_dir" O="$build_dir" ARCH="$arch" KCONFIG_CONFIG="$build_dir/.config" \
    INSTALL_MOD_PATH="$modules_dir" INSTALL_MOD_STRIP=1 modules_install
depmod -b "$modules_dir" -F "$build_dir/System.map" "$kernel_release"
installed_modules="$modules_dir/lib/modules/$kernel_release"
[[ -s "$installed_modules/modules.dep" && -s "$installed_modules/modules.builtin" ]] || {
    echo "modules_install/depmod did not produce the release module index." >&2
    exit 1
}
mapfile -d '' -t installed_drivers < <(find "$installed_modules" -type f \
    \( -name 'virtio_snd.ko' -o -name 'virtio_snd.ko.gz' -o -name 'virtio_snd.ko.xz' -o -name 'virtio_snd.ko.zst' \) -print0)
[[ "${#installed_drivers[@]}" -eq 1 ]] || {
    echo "Expected one installed virtio_snd module; found ${#installed_drivers[@]}." >&2
    exit 1
}
installed_driver=${installed_drivers[0]}
driver_relative=${installed_driver#"$installed_modules"/}
grep -Fq "$driver_relative:" "$installed_modules/modules.dep" || {
    echo "depmod did not index the installed virtio_snd module." >&2
    exit 1
}
installed_vermagic=$(modinfo -F vermagic "$installed_driver")
[[ "${installed_vermagic%% *}" == "$kernel_release" ]] || {
    echo "Installed module vermagic does not match kernel release $kernel_release." >&2
    exit 1
}
installed_driver_sha256=$(sha256sum "$installed_driver" | awk '{print $1}')
# Resolve the complete dependency closure without loading anything on the runner.
modprobe --dirname "$modules_dir" --set-version "$kernel_release" --show-depends virtio_snd > "$build_root/module-load-plan.txt"
grep -Fq "$driver_relative" "$build_root/module-load-plan.txt"
sed "s|$modules_dir/||g" "$build_root/module-load-plan.txt" > "$output_dir/virtio_snd.load-plan.txt"
grep -F "$driver_relative:" "$installed_modules/modules.dep" > "$output_dir/virtio_snd.modules.dep"

echo "Installing the public WSL UAPI headers and perf tool."
make -s -C "$source_dir" O="$build_dir" ARCH="$arch" KCONFIG_CONFIG="$build_dir/.config" \
    INSTALL_HDR_PATH="$headers_dir" headers_install
make -C "$source_dir/tools/perf" O="$perf_build_dir" JOBS="$jobs" \
    NO_JEVENTS=1 NO_JVMTI=1 NO_LIBTRACEEVENT=1 \
    install DESTDIR="$perf_dir" prefix=/
[[ -s "$headers_dir/include/linux/version.h" ]] || { echo "Installed UAPI headers are missing." >&2; exit 1; }
[[ -x "$perf_dir/bin/perf" ]] || { echo "Installed perf binary is missing." >&2; exit 1; }
"$perf_dir/bin/perf" --version | tee "$output_dir/perf.version.txt"

cp -- "$config_path" "$output_dir/kernel_config.submitted"
cp -- "$module_path" "$output_dir/virtio_snd.ko"
cp -- "$symvers_path" "$output_dir/Module.symvers"
cp -- "$kernel_image_path" "$output_dir/bzImage"
modinfo "$output_dir/virtio_snd.ko" > "$output_dir/virtio_snd.modinfo.txt"

vhdx_path="$output_dir/wsl-kernel-artifacts.vhdx"
[[ ! -e "$vhdx_path" ]] || { echo "Refusing to overwrite $vhdx_path." >&2; exit 1; }
bash "$source_dir/Microsoft/scripts/gen_artifacts_vhdx.sh" \
    "$modules_dir" "$headers_dir" "$perf_dir" "$kernel_release" "$vhdx_path"
qemu-img check "$vhdx_path"
qemu-img info --output=json "$vhdx_path" > "$output_dir/qemu-img-info.json"

roundtrip_raw="$build_root/wsl-kernel-artifacts-roundtrip.raw"
qemu-img convert -p -f vhdx -O raw "$vhdx_path" "$roundtrip_raw"
e2fsck -fn "$roundtrip_raw"
debugfs -R "cat /$kernel_release/modules/modules.dep" "$roundtrip_raw" 2>/dev/null > "$build_root/modules.dep.roundtrip"
for image_path in \
    "/$kernel_release/modules/modules.dep" \
    "/$kernel_release/modules/$driver_relative" \
    "/$kernel_release/linux-headers/include/linux/version.h" \
    "/$kernel_release/perf/bin/perf"; do
    debugfs -R "stat $image_path" "$roundtrip_raw" > "$build_root/debugfs-stat.txt" 2>&1
    grep -Fq 'Inode:' "$build_root/debugfs-stat.txt" || {
        echo "Packaged VHDX is missing $image_path." >&2
        exit 1
    }
done
grep -Fq "$driver_relative:" "$build_root/modules.dep.roundtrip" || {
        echo "Packaged modules.dep does not index $driver_relative." >&2
        exit 1
    }

cmp "$installed_modules/modules.dep" "$build_root/modules.dep.roundtrip"
debugfs -R "dump /$kernel_release/modules/$driver_relative $build_root/virtio_snd.roundtrip" "$roundtrip_raw"
cmp "$installed_driver" "$build_root/virtio_snd.roundtrip"

export SOURCE_REVISION="$source_revision" SOURCE_TREE="$source_tree" SOURCE_REPOSITORY="$repository" SOURCE_REF="$source_ref"
export KERNEL_RELEASE="$kernel_release" CONFIG_BLOB_SHA
CONFIG_BLOB_SHA=$(git -C "$source_dir" rev-parse "$source_revision:arch/x86/configs/config-wsl")
export CONFIG_BLOB_SHA
export VALIDATION_HARNESS_REPOSITORY=${VALIDATION_HARNESS_REPOSITORY:?VALIDATION_HARNESS_REPOSITORY is required}
export VALIDATION_HARNESS_REF=${VALIDATION_HARNESS_REF:?VALIDATION_HARNESS_REF is required}
export VALIDATION_HARNESS_COMMIT=${VALIDATION_HARNESS_COMMIT:?VALIDATION_HARNESS_COMMIT is required}
export MODULE_DEPENDS="$module_depends" MODULE_VERMAGIC="$module_vermagic" INSTALLED_DRIVER="$driver_relative"
export SOURCE_CONFIG_SHA256="$(sha256sum "$config_path" | awk '{print $1}')"
export RESOLVED_CONFIG_SHA256="$(sha256sum "$build_dir/.config" | awk '{print $1}')"
export MODULE_SHA256="$(sha256sum "$module_path" | awk '{print $1}')"
export SYMVERS_SHA256="$(sha256sum "$symvers_path" | awk '{print $1}')"
export BZIMAGE_SHA256="$(sha256sum "$kernel_image_path" | awk '{print $1}')"
export VHDX_SHA256="$(sha256sum "$vhdx_path" | awk '{print $1}')"
export INSTALLED_MODULE_SHA256="$installed_driver_sha256"
export VHDX_BYTES="$(stat -c '%s' "$vhdx_path")"
export GEN_ARTIFACTS_SCRIPT_SHA256="$(sha256sum "$source_dir/Microsoft/scripts/gen_artifacts_vhdx.sh" | awk '{print $1}')"
export BUILD_SCRIPT_SHA256="$(sha256sum "$0" | awk '{print $1}')"
workflow_file="${GITHUB_WORKSPACE:-$(pwd)}/.github/workflows/kernel-exact-build.yml"
[[ -s "$workflow_file" ]] || { echo "Validation workflow file is missing: $workflow_file" >&2; exit 1; }
export WORKFLOW_FILE_SHA256="$(sha256sum "$workflow_file" | awk '{print $1}')"
export JOBS="$jobs"
export BUILD_TIMESTAMP="$KBUILD_BUILD_TIMESTAMP"
final_source_status=$(git -C "$source_dir" status --porcelain --untracked-files=all)
[[ -z "$final_source_status" ]] || { printf 'Build modified the source checkout:\n%s\n' "$final_source_status" >&2; exit 1; }
python3 - "$output_dir/build-manifest.json" "$output_dir/qemu-img-info.json" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys

out = pathlib.Path(os.environ["OUTPUT_DIR"])
qemu_info = json.loads(pathlib.Path(sys.argv[2]).read_text())

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def first_line(command):
    return subprocess.check_output(command, text=True).splitlines()[0]

manifest = {
    "schemaVersion": 1,
    "status": "built-and-packaged; boot/runtime not tested",
    "validationHarness": {
        "repository": os.environ["VALIDATION_HARNESS_REPOSITORY"],
        "ref": os.environ["VALIDATION_HARNESS_REF"],
        "commit": os.environ["VALIDATION_HARNESS_COMMIT"],
        "workflowSha256": os.environ["WORKFLOW_FILE_SHA256"],
        "buildScriptSha256": os.environ["BUILD_SCRIPT_SHA256"],
    },
    "source": {
        "repository": os.environ["SOURCE_REPOSITORY"],
        "ref": os.environ["SOURCE_REF"],
        "commit": os.environ["SOURCE_REVISION"],
        "tree": os.environ["SOURCE_TREE"],
        "configBlob": os.environ["CONFIG_BLOB_SHA"],
        "configSha256": os.environ["SOURCE_CONFIG_SHA256"],
    },
    "build": {
        "architecture": "x86_64 (ARCH=x86)",
        "jobs": int(os.environ["JOBS"]),
        "buildTimestamp": os.environ["BUILD_TIMESTAMP"],
        "gcc": first_line(["gcc", "--version"]),
        "assembler": first_line(["as", "--version"]),
        "linker": first_line(["ld", "--version"]),
        "fullKernelAndModules": True,
        "modulesInstallCompleted": True,
        "headersInstallCompleted": True,
        "perfInstallCompleted": True,
        "perfBuildOptions": [f"JOBS={os.environ['JOBS']}", "NO_JEVENTS=1", "NO_JVMTI=1", "NO_LIBTRACEEVENT=1"],
        "resolvedConfigSha256": os.environ["RESOLVED_CONFIG_SHA256"],
        "requiredOptions": {
            "CONFIG_MODULES": "y",
            "CONFIG_MODVERSIONS": "y",
            "CONFIG_SND": "m",
            "CONFIG_SND_PCM": "m",
            "CONFIG_SND_JACK": "y",
            "CONFIG_SND_JACK_INPUT_DEV": "y",
            "CONFIG_SND_VIRTIO": "m",
            "CONFIG_VIRTIO": "y",
        },
    },
    "module": {
        "path": os.environ["INSTALLED_DRIVER"],
        "sha256": os.environ["MODULE_SHA256"],
        "installedSha256": os.environ["INSTALLED_MODULE_SHA256"],
        "vermagic": os.environ["MODULE_VERMAGIC"],
        "depends": os.environ["MODULE_DEPENDS"],
        "modulesDepIndexed": True,
        "dependencyClosureResolved": True,
        "packagedModuleBytesVerified": True,
    },
    "kernel": {
        "release": os.environ["KERNEL_RELEASE"],
        "bzImageSha256": os.environ["BZIMAGE_SHA256"],
        "moduleSymversSha256": os.environ["SYMVERS_SHA256"],
    },
    "package": {
        "builder": "Microsoft/scripts/gen_artifacts_vhdx.sh at the exact source commit",
        "builderScriptSha256": os.environ["GEN_ARTIFACTS_SCRIPT_SHA256"],
        "layout": "<release>/{modules,linux-headers,perf}",
        "vhdxSha256": os.environ["VHDX_SHA256"],
        "vhdxBytes": int(os.environ["VHDX_BYTES"]),
        "qemuImgInfo": qemu_info,
        "roundtripE2fsckPassed": True,
        "moduleHeaderAndPerfPathsVerified": True,
    },
    "runtimeCompatibility": {
        "proven": False,
        "bootTested": False,
        "moduleLoaded": False,
        "reason": "This CI job validates the exact source config, coherent build, and artifact layout only; it does not boot WSL or prove compatibility with a Microsoft-shipped kernel binary.",
    },
}
(out / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY

echo "Build and package complete; WSL boot/runtime compatibility remains untested."
