#!/usr/bin/env sh
set -eu

if [ "$(id -u)" -eq 0 ]; then
	SUDO=""
elif command -v sudo >/dev/null 2>&1; then
	SUDO="sudo"
else
	printf '%s\n' 'error: apt setup requires root or sudo' >&2
	exit 1
fi

packages="
clang lld llvm
python3 python3-pip python3-venv pipx
usbmuxd usbutils libimobiledevice-utils
pkg-config zlib1g-dev libpython3-dev gcc g++ curl
libxml2-dev libncurses-dev libz3-dev gnupg2
libc6-dev libcurl4-openssl-dev
"

$SUDO apt-get update
# Package expansion is intentional: each whitespace-delimited name is an argument.
# shellcheck disable=SC2086
$SUDO apt-get install -y $packages

# Up to and including LLVM 18, ld64.lld miswires `_objc_msgSend$<selector>`
# stubs, which breaks Objective-C plugins at runtime. Ubuntu 24.04 still
# ships 18 as the unversioned `lld`, so install the newest versioned
# `lld-<N>` at or above 19 and point a stable name at its ld64.lld.
min_lld=19
newest=""
for candidate in $(apt-cache pkgnames lld- 2>/dev/null | sed -n 's/^lld-\([0-9][0-9]*\)$/\1/p' | sort -rn); do
	if [ "$candidate" -ge "$min_lld" ]; then
		newest="$candidate"
		break
	fi
done

have_fixed_lld() {
	for bin in /usr/bin/ld64.lld-*; do
		[ -x "$bin" ] || continue
		version="${bin##*/ld64.lld-}"
		case "$version" in
		'' | *[!0-9]*) continue ;;
		esac
		[ "$version" -ge "$min_lld" ] && return 0
	done
	return 1
}

if ! have_fixed_lld && [ -n "$newest" ]; then
	$SUDO apt-get install -y "lld-$newest" || true
fi

# Put the newest fixed ld64.lld on PATH under its unversioned name, unless
# something xcross does not manage already owns that path.
best_version=0
best=""
for bin in /usr/bin/ld64.lld-*; do
	[ -x "$bin" ] || continue
	version="${bin##*/ld64.lld-}"
	case "$version" in
	'' | *[!0-9]*) continue ;;
	esac
	[ "$version" -lt "$min_lld" ] && continue
	if [ "$version" -gt "$best_version" ]; then
		best_version="$version"
		best="$bin"
	fi
done

if [ -n "$best" ]; then
	stable=/usr/local/bin/ld64.lld
	managed=0
	if [ ! -e "$stable" ] && [ ! -L "$stable" ]; then
		managed=1
	elif [ -L "$stable" ]; then
		case "$(readlink "$stable")" in
		*/ld64.lld-*) managed=1 ;;
		esac
	fi
	if [ "$managed" -eq 1 ]; then
		$SUDO ln -sf "$best" "$stable"
		printf 'ld64.lld: %s -> %s\n' "$stable" "$best"
	else
		printf 'warning: %s is not managed by xcross; leaving it alone (wanted %s)\n' "$stable" "$best" >&2
	fi
fi

if ! command -v swift >/dev/null 2>&1; then
	swiftly_dir="$(mktemp -d)"
	trap 'rm -rf "$swiftly_dir"' EXIT HUP INT TERM
	curl -fsSL "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" \
		-o "$swiftly_dir/swiftly.tar.gz"
	tar -xzf "$swiftly_dir/swiftly.tar.gz" -C "$swiftly_dir"
	"$swiftly_dir/swiftly" init --quiet-shell-followup
	. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
	hash -r
fi

pipx install --force pymobiledevice3
pipx ensurepath
