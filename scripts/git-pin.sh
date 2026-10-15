#!/bin/bash
# scripts/git-pin.sh — L1-owned provisioning of the pinned git (2.56.0).
#
# This is the single source of truth for the git pin. It is shipped to the VM
# via hcloud_server.user_data (cloud-init first boot) so the pin survives an
# image rebuild, and it self-copies to /opt/git-pin.sh so an operator can
# re-run `bash /opt/git-pin.sh` to repair a clobbered binary (the old L2 copy
# lived only in ephemeral /tmp and was lost on cleanup — issue #2323).
#
# #2323 layout contract (GUARDS NEVER OVERWRITE BINARIES):
#   /opt/git-2.56.0/bin/git  -> the REAL compiled ELF binary. NEVER a guard,
#                               never a script. Guards must never be written
#                               over this path (that is what clobbered the pin
#                               and broke `git --version`).
#   /usr/local/bin/git       -> a WRAPPER script that execs the pinned binary.
#                               Any guard/shim belongs HERE, at its own path,
#                               exec'ing the preserved binary. The wrapper is
#                               idempotently (re)installed below.
set -euo pipefail

GIT_PREFIX=/opt/git-2.56.0
GIT_VERSION=2.56.0
GIT_TARBALL_URL="https://www.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.gz"
SELF_COPY=/opt/git-pin.sh

# ── Minimal helpers (self-contained — L1 module owns this, no lib.sh) ──
__log() { echo "[$(date -Iseconds)] [$1] $2"; }
info()  { __log "INFO"  "$1"; }
warn()  { __log "WARN"  "$1"; }
error() { __log "ERROR" "$1"; }

package_installed() {
	dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

apt_install() {
	local pkg="$1"
	if package_installed "$pkg"; then
		info "Package already installed: $pkg"
		return 0
	fi
	info "Installing: $pkg"
	apt-get install -y --no-install-recommends "$pkg" || {
		# Fresh images may have stale/absent package lists; refresh and retry.
		info "apt-get update + retry install for $pkg"
		apt-get update -qq
		apt-get install -y --no-install-recommends "$pkg"
	}
}

# true if $1 is a real compiled binary (ELF magic \x7fELF), not a script.
is_elf() {
	[ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]
}

# ── Persist a canonical copy for operator re-runs (was /tmp-ephemeral) ──
if [ "$(readlink -f "$0")" != "$SELF_COPY" ]; then
	mkdir -p "$(dirname "$SELF_COPY")"
	cp "$0" "$SELF_COPY.tmp"
	chmod 0755 "$SELF_COPY.tmp"
	mv "$SELF_COPY.tmp" "$SELF_COPY"
	info "saved canonical script to $SELF_COPY (re-run: bash $SELF_COPY)"
fi

# ── Idempotent short-circuit with clobber detection ──
# Skip only if the existing git is a REAL compiled binary. If a guard script
# was written over the binary (issue #2323), the file is an executable text
# script rather than ELF — trigger a rebuild/repair instead of blindly skipping.
if [ -x "$GIT_PREFIX/bin/git" ]; then
	if is_elf "$GIT_PREFIX/bin/git"; then
		info "git ${GIT_VERSION} already provisioned as a real ELF binary at $GIT_PREFIX/bin/git — skipping"
		"$GIT_PREFIX/bin/git" --version
		exit 0
	fi
	warn "existing $GIT_PREFIX/bin/git is NOT an ELF binary (clobbered by a guard?) — rebuilding/repairing"
fi

info "git ${GIT_VERSION} not found (or not a real binary) — building from $GIT_TARBALL_URL"

# ── Toolchain (idempotent) ──
# Cargo is required for git 2.49+ because libgitcore (Rust bindings used by
# `make all`) links a Rust static lib; without it `make` fails with
# `cargo: not found` / Error 127 (observed in head deploy 37075271395).
apt_install build-essential
apt_install libcurl4-openssl-dev
apt_install libssl-dev
apt_install libexpat1-dev
apt_install gettext
apt_install zlib1g-dev
apt_install cargo
apt_install wget

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

info "Fetching $GIT_TARBALL_URL"
if ! wget -q --show-progress=off "$GIT_TARBALL_URL" -O "$WORK/git.tar.gz"; then
	error "wget failed for $GIT_TARBALL_URL (workdir preserved at $WORK for diagnostics)"
	trap - EXIT
	exit 1
fi

info "Extracting"
tar -xzf "$WORK/git.tar.gz" -C "$WORK"
SRC_DIR=$(find "$WORK" -maxdepth 1 -type d -name "git-${GIT_VERSION}*" | head -1)
if [ -z "$SRC_DIR" ]; then
	error "Could not locate extracted git-${GIT_VERSION}* directory under $WORK"
	exit 1
fi

pushd "$SRC_DIR" >/dev/null
info "Configuring --prefix=$GIT_PREFIX"
if ! ./configure --prefix="$GIT_PREFIX"; then
	popd >/dev/null
	error "./configure failed for git ${GIT_VERSION} (workdir preserved at $WORK)"
	exit 1
fi
info "Building (nproc=$(nproc))"
if ! make -j"$(nproc)" all; then
	popd >/dev/null
	error "make failed for git ${GIT_VERSION} (workdir preserved at $WORK)"
	exit 1
fi
info "Installing to $GIT_PREFIX"
if ! make install; then
	popd >/dev/null
	error "make install failed for git ${GIT_VERSION} (workdir preserved at $WORK)"
	exit 1
fi
popd >/dev/null

if [ ! -x "$GIT_PREFIX/bin/git" ] || ! is_elf "$GIT_PREFIX/bin/git"; then
	error "git ${GIT_VERSION} build/install completed but $GIT_PREFIX/bin/git is missing or not a real ELF binary"
	exit 1
fi

# ── PATH shadowing + wrapper layout ──
# /usr/local/bin precedes /usr/bin on the default Ubuntu PATH, so by placing
# git here we shadow the distro git (/usr/bin/git) without touching apt state.
#
# The main `git` is a WRAPPER script (not a symlink to the binary): per issue
# #2323, any guard/shim must live at its OWN path and `exec` the preserved
# binary — never be written over the binary. If the binary were ever clobbered
# again, the wrapper still correctly execs it (and the ELF check above triggers
# a rebuild on the next run).
mkdir -p /usr/local/bin
WRAPPER=/usr/local/bin/git
cat > "$WRAPPER.tmp" <<EOF
#!/bin/bash
# Wrapper for the pinned git — #2323 layout contract. This guard lives at its
# own path and execs the preserved binary at $GIT_PREFIX/bin/git; it must
# never be written over the binary itself. Exec this file (blame the git gate,
# not the verified binary) if a version check fails.
exec "$GIT_PREFIX/bin/git" "\$@"
EOF
chmod 0755 "$WRAPPER.tmp"
mv -f "$WRAPPER.tmp" "$WRAPPER"

# git-* helpers (git-receive-pack, git-upload-pack, ...) are not guards — a
# plain symlink is fine and covers SSH-based git operations over the wire.
# Idempotent: ln -sf re-links on re-run.
for bin in "$GIT_PREFIX"/bin/*; do
	[ -e "$bin" ] || continue
	[ "$(basename "$bin")" = "git" ] && continue
	ln -sf "$bin" "/usr/local/bin/$(basename "$bin")"
done

INSTALLED_VERSION=$("$GIT_PREFIX/bin/git" --version)
info "git ${INSTALLED_VERSION} provisioned at $GIT_PREFIX/bin/git ($WRAPPER execs it)"