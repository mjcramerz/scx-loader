#!/usr/bin/env bash
set -Eeuo pipefail

umask 022

die() {
    printf 'build-deb: %s\n' "$1" >&2
    exit 1
}

build_root=
dpkg_buildpackage=/usr/bin/dpkg-buildpackage
skip_dpkg_builddeps=0

while (($#)); do
    case $1 in
        --build-root)
            (($# >= 2)) || die "--build-root requires a value"
            build_root=$2
            shift 2
            ;;
        --dpkg-buildpackage)
            (($# >= 2)) || die "--dpkg-buildpackage requires a value"
            dpkg_buildpackage=$2
            shift 2
            ;;
        --)
            shift
            (($# == 0)) || die "unexpected arguments after --"
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n $build_root ]] || die "--build-root is required"
[[ $build_root == /* ]] || die "build root must be absolute"
[[ $build_root != / ]] || die "refusing to use / as the build root"
[[ $build_root != *$'\n'* ]] || die "build root contains a newline"
[[ -x $dpkg_buildpackage ]] || die "dpkg-buildpackage is not executable: $dpkg_buildpackage"

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd -P)
[[ -f $repo_root/debian/control ]] || die "missing debian/control"
[[ -f $repo_root/debian/rules ]] || die "missing debian/rules"
[[ -f $repo_root/debian/changelog ]] || die "missing debian/changelog"

for command in git tar dpkg-parsechangelog dpkg-checkbuilddeps python3 cargo; do
    command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done
command -v rustc >/dev/null 2>&1 || die "required command not found: rustc"

source_package=$(dpkg-parsechangelog -l "$repo_root/debian/changelog" -S Source)
debian_version=$(dpkg-parsechangelog -l "$repo_root/debian/changelog" -S Version)
upstream_version=${debian_version%-*}
[[ $source_package =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || die "invalid source package name"
[[ $upstream_version =~ ^[0-9][0-9A-Za-z.+:~]*$ ]] || die "invalid upstream version"

check_build_dependencies() {
    local output missing
    if output=$(dpkg-checkbuilddeps "$repo_root/debian/control" 2>&1); then
        return 0
    fi

    missing=${output#*unmet build dependencies: }
    if [[ $output == "dpkg-checkbuilddeps: error: unmet build dependencies: "* ]] \
        && [[ $missing == "cargo rustc" ]] \
        && cargo --version >/dev/null 2>&1 \
        && rustc --version >/dev/null 2>&1; then
        printf '%s\n' \
            'build-deb: warning: using executable cargo/rustc toolchain outside dpkg' \
            'build-deb: warning: Debian control dependencies remain unchanged for installed builds' >&2
        skip_dpkg_builddeps=1
        return 0
    fi

    printf '%s\n' "$output" >&2
    die "Debian build dependencies are not installed"
}

check_build_dependencies

mkdir -p -- "$build_root"
build_root=$(CDPATH='' cd -- "$build_root" && pwd -P)
source_root="$build_root/${source_package}-${upstream_version}"
[[ $source_root == "$build_root/"* ]] || die "source root escaped build root"
[[ $source_root != "$build_root" ]] || die "invalid source root"
rm -rf -- "$source_root"

tmp_root=$(mktemp -d "$build_root/.${source_package}.XXXXXX")
cleanup() {
    if [[ -n ${tmp_root:-} ]]; then
        rm -rf -- "$tmp_root"
    fi
}
trap cleanup EXIT

git -C "$repo_root" archive --format=tar HEAD | tar -xf - -C "$tmp_root"
mv -- "$tmp_root" "$source_root"
tmp_root=

rm -rf -- "$source_root/debian"
cp -a -- "$repo_root/debian" "$source_root/debian"
mkdir -p -- "$source_root/.cargo"
(
    cd -- "$source_root"
    cargo vendor --locked >> .cargo/config.toml
    python3 debian/sanitize-vendor-checksums.py
    python3 debian/update-vendor-copyright --source-root .
)

orig_tarball="$build_root/${source_package}_${upstream_version}.orig.tar.xz"
tar --create --xz --file "$orig_tarball" \
    --directory "$build_root" \
    --exclude="${source_package}-${upstream_version}/debian" \
    --sort=name --mtime='1970-01-01 00:00:00 UTC' \
    --owner=0 --group=0 --numeric-owner \
    "${source_package}-${upstream_version}"

printf 'building %s %s in %s\n' "$source_package" "$debian_version" "$build_root"
buildpackage_args=(--build=full --no-sign)
if ((skip_dpkg_builddeps)); then
    buildpackage_args+=(--no-check-builddeps)
fi
(
    cd -- "$source_root"
    exec "$dpkg_buildpackage" "${buildpackage_args[@]}"
)

printf 'artifacts: %s\n' "$build_root"
