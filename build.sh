#!/bin/sh
# Moraine: build a minimal Alpine-based LLM inference image for the AMD BC-250.
#
#   ./build.sh [all|builder|packages|rootfs|image|shell|clean]
#
# Runs on any x86_64 Linux host as root (it uses chroot and bind mounts).
# Everything happens inside an Alpine builder chroot under ./work, so the host
# only needs sh, curl, tar, mount and chroot.
set -eu

HERE=${HERE:-$(cd "$(dirname "$0")" && pwd)}
. "$HERE/config.env"
# Optional local overrides (not tracked): same variables as config.env.
[ -f "$HERE/config.local" ] && . "$HERE/config.local"

WORK=${WORK:-$HERE/work}
B=$WORK/builder          # Alpine builder chroot
T=$B/target              # target rootfs (/target inside the builder)
OUT=$WORK/out

# Build order matters: nothing depends on another local package at build
# time, but keep the cheap ones first so failures show up early.
PKG_ORDER="moraine-base cyan-skillfish-governor-smu mesa-radv-minimal llama-cpp-vulkan bc250-amdgpu-40cu moraine-setup"

TARGET_PKGS="
	alpine-baselayout alpine-keys alpine-release apk-tools musl-utils
	busybox busybox-openrc busybox-mdev-openrc openrc kmod
	linux-lts linux-firmware-amdgpu linux-firmware-rtl_nic
	e2fsprogs dropbear dropbear-openrc ca-certificates-bundle
	moraine-base cyan-skillfish-governor-smu mesa-radv-minimal
	llama-cpp-vulkan bc250-amdgpu-40cu moraine-setup
	amdgpu_top@testing nano
	$EXTRA_PACKAGES
"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

MOUNTS=""
bind_mount() { mkdir -p "$2"; mount --bind "$1" "$2"; MOUNTS="$2 $MOUNTS"; }
proc_mount() { mkdir -p "$1"; mount -t proc proc "$1"; MOUNTS="$1 $MOUNTS"; }
umount_all() {
	for m in $MOUNTS; do umount -l "$m" 2>/dev/null || :; done
	MOUNTS=""
}
trap umount_all EXIT INT TERM

# Run a command inside the target rootfs.
tchroot() {
	chroot "$T" /usr/bin/env -i HOME=/root TERM="${TERM:-dumb}" \
		PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -c "$*"
}

# Run a command inside the builder with a clean environment.
bchroot() {
	chroot "$B" /usr/bin/env -i HOME=/root TERM="${TERM:-dumb}" \
		PATH=/usr/sbin:/usr/bin:/sbin:/bin JOBS="${JOBS:-$(nproc)}" \
		PACKAGER="moraine <moraine@localhost>" \
		/bin/sh -c "$*"
}

builder_mounts() {
	grep -qs " $B/proc " /proc/mounts || proc_mount "$B/proc"
	grep -qs " $B/dev " /proc/mounts || bind_mount /dev "$B/dev"
	grep -qs " $B/sys " /proc/mounts || bind_mount /sys "$B/sys"
	cp -L /etc/resolv.conf "$B/etc/resolv.conf"
}

# --------------------------------------------------------------------------
stage_builder() {
	log "Builder chroot ($ALPINE_BRANCH)"
	local base="$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$ARCH"
	if [ ! -x "$B/sbin/apk" ]; then
		mkdir -p "$B"
		local rel
		rel=$(curl -fsSL "$base/latest-releases.yaml" |
			awk '/file: alpine-minirootfs-/ { print $2; exit }')
		[ -n "$rel" ] || die "could not find minirootfs in $base"
		curl -fsSL "$base/$rel" | tar -xz -C "$B"
		if [ -n "$EXTRA_CA_BUNDLE" ]; then
			cat "$EXTRA_CA_BUNDLE" >> "$B/etc/ssl/certs/ca-certificates.crt"
		fi
	fi
	printf '%s/%s/main\n%s/%s/community\n' \
		"$ALPINE_MIRROR" "$ALPINE_BRANCH" "$ALPINE_MIRROR" "$ALPINE_BRANCH" \
		> "$B/etc/apk/repositories"
	builder_mounts
	bchroot "apk update -q && apk add -q alpine-sdk e2fsprogs dosfstools mtools sfdisk"
	if [ ! -f "$B/root/.abuild/abuild.conf" ]; then
		rm -rf "$B/root/.abuild"
		bchroot "abuild-keygen -a -n && cp /root/.abuild/*.rsa.pub /etc/apk/keys/"
	fi
	mkdir -p "$B/repo" "$B/build"
}

# --------------------------------------------------------------------------
check_kernel_pin() {
	local ab="$HERE/packages/bc250-amdgpu-40cu/APKBUILD" want have
	want="$(sed -n 's/^_kver=//p' "$ab")-r$(sed -n 's/^_krel=//p' "$ab")"
	have=$(bchroot "apk search -e -v linux-lts" | awk 'NR==1 { sub(/^linux-lts-/, "", $1); print $1 }')
	[ "$have" = "$want" ] || die "linux-lts in $ALPINE_BRANCH is '$have' but \
bc250-amdgpu-40cu targets '$want'. Bump _kver/_krel in $ab (and reset pkgrel)."
}

stage_packages() {
	builder_mounts
	local p src list="${*:-$PKG_ORDER}"
	case " $list " in *" bc250-amdgpu-40cu "*) check_kernel_pin ;; esac
	for p in $list; do
		[ -d "$HERE/packages/$p" ] || die "no such package: $p"
		log "Package: $p"
		src="$HERE/packages/$p"
		rm -rf "$B/build/$p"
		cp -r "$src" "$B/build/$p"
		# Local-only packages are re-summed every time. For packages with
		# downloads, the first build pins checksums back into the tree
		# (trust on first use) and later builds verify against them.
		if ! awk '/^source="/ { s = 1 } s { print } s && /"[[:space:]]*$/ && !/^source="$/ { exit }' \
				"$src/APKBUILD" | grep -q '://'; then
			bchroot "cd /build/$p && abuild -F checksum"
		elif grep -q '^sha512sums=""' "$src/APKBUILD"; then
			bchroot "cd /build/$p && abuild -F checksum"
			cp "$B/build/$p/APKBUILD" "$src/APKBUILD"
		fi
		bchroot "cd /build/$p && REPODEST=/repo abuild -F -r"
	done
	ls -1 "$B/repo/build/$ARCH/"*.apk "$B/repo/build/noarch/"*.apk 2>/dev/null || :
}

# --------------------------------------------------------------------------
write_generated_config() {
	local kr

	# Branding (Alpine stays visible as the base).
	local alp
	alp=$(cat "$T/etc/alpine-release" 2>/dev/null)
	cat > "$T/etc/os-release" <<-EOF
		NAME="Moraine"
		ID=moraine
		ID_LIKE=alpine
		VERSION_ID=$MORAINE_VERSION
		PRETTY_NAME="Moraine $MORAINE_VERSION (Alpine Linux $alp)"
		HOME_URL="$MORAINE_URL"
	EOF
	printf '\nMoraine %s - LLM inference for the AMD BC-250 (Alpine Linux %s)\nKernel \\r on \\m (\\l)\n\n' \
		"$MORAINE_VERSION" "$alp" > "$T/etc/issue"
	cp "$T/etc/issue" "$T/etc/issue.net"   # replaced at boot by moraine-issue
	printf '\n  Moraine %s\n\n' \
		"$MORAINE_VERSION" > "$T/etc/motd"

	echo "$HOSTNAME" > "$T/etc/hostname"
	mkdir -p "$T/srv/models"   # abuild policy forbids packages owning /srv
	[ -e "$T/models" ] || ln -s srv/models "$T/models"   # short path, same place
	printf '127.0.0.1\t%s localhost\n::1\t\tlocalhost\n' "$HOSTNAME" > "$T/etc/hosts"

	mkdir -p "$T/etc/kernel"
	echo "root=LABEL=moraine-root rootfstype=ext4 modules=ext4 rw quiet loglevel=0 nowatchdog $CMDLINE_EXTRA" \
		| sed 's/ *$//' > "$T/etc/kernel/cmdline"

	cat > "$T/etc/conf.d/moraine-gtt" <<-EOF
		GTT_RESERVE_MB="$GTT_RESERVE_MB"
		GTT_MB="$GTT_MB"
	EOF

	sed -i "s/^options amdgpu bc250_cc_write_mode=.*/options amdgpu bc250_cc_write_mode=$CU_UNLOCK_MODE/" \
		"$T/etc/modprobe.d/bc250-40cu.conf"
	if [ -n "$AMDGPU_DISABLE_CU" ]; then
		echo "options amdgpu disable_cu=$AMDGPU_DISABLE_CU" > "$T/etc/modprobe.d/bc250-disable-cu.conf"
	fi

	cat > "$T/etc/conf.d/llama-server" <<-EOF
		# Generated by build.sh from config.env. Option notes: README.md,
		# "Where the memory goes". Apply changes: rc-service llama-server restart
		LLAMA_MODEL="$LLAMA_MODEL"
		LLAMA_HOST="$LLAMA_HOST"
		LLAMA_PORT="$LLAMA_PORT"
		LLAMA_CTX="$LLAMA_CTX"
		LLAMA_ARGS="$LLAMA_ARGS"
		LLAMA_API_KEY="$LLAMA_API_KEY"
		LLAMA_BOOT_PROGRESS="yes"
		LLAMA_LOAD_TIMEOUT="900"
		LLAMA_LOG_MAX_KB="10240"
	EOF
	chmod 600 "$T/etc/conf.d/llama-server"

	# Templates placed on the FAT boot partition (see moraine-espimport).
	local esp="$T/usr/share/moraine/esp"
	mkdir -p "$esp"
	cp "$T/etc/conf.d/llama-server" "$esp/llama-server.conf.example"
	cat > "$esp/README.txt" <<-'EOF'
		Moraine - boot partition settings
		====================================================

		Files in this folder are applied on every boot:

		  authorized_keys     SSH public keys for root (one per line),
		                      in addition to password login.
		  root-password       One line, the new root password. Applied once
		                      and then deleted from this partition.
		  llama-server.conf   Replaces /etc/conf.d/llama-server. Start from
		                      llama-server.conf.example (rename it).
		  skip-llama          Empty file: don't start the LLM server on the
		                      next boot (safe mode if a model doesn't fit).
		                      Removed after use.

		Default login (console and SSH):  root / moraine
		moraine-setup asks you to change it on first login. You can also set
		it here with root-password, and add SSH keys with authorized_keys.

		Models go on the Linux partition, default path:
		  /models   (a USB drive with .gguf files works too: moraine-setup finds them)
		e.g.  scp model.gguf root@moraine:/models/
		Then log in and pick it in moraine-setup; the LLM server stays off
		until a model is chosen.

		API:    http://<box>:8080/v1   (OpenAI compatible)
		Status: ssh root@<box> moraine-status
	EOF

	# Root access: SSH keys and/or password.
	mkdir -p "$T/root/.ssh" && chmod 700 "$T/root/.ssh"
	if [ -s "$HERE/$SSH_AUTHORIZED_KEYS" ] || [ -s "$SSH_AUTHORIZED_KEYS" ]; then
		kr="$SSH_AUTHORIZED_KEYS"; [ -s "$kr" ] || kr="$HERE/$SSH_AUTHORIZED_KEYS"
		install -m600 "$kr" "$T/root/.ssh/authorized_keys"
	fi
	# SSH password login is always enabled; keys work in addition.
	echo 'DROPBEAR_OPTS="-b /etc/issue.net"' > "$T/etc/conf.d/dropbear"
	if [ -n "$ROOT_PASSWORD" ]; then
		printf 'root:%s\n' "$ROOT_PASSWORD" | chroot "$T" /usr/sbin/chpasswd -c sha512
		# moraine-setup nags until the shipped default is changed.
		if [ "$ROOT_PASSWORD" = moraine ]; then : > "$T/etc/moraine/default-password"; fi
	else
		# '*' = no valid password (key login only)
		sed -i 's/^root:[^:]*:/root:*:/' "$T/etc/shadow"
		[ -s "$T/root/.ssh/authorized_keys" ] ||
			printf '\n\033[1;33mWARNING:\033[0m no ROOT_PASSWORD and no SSH keys baked in; add them via the ESP (moraine/README.txt).\n'
	fi

}

enable_services() {
	local rl svc
	add() { rl=$1; shift; mkdir -p "$T/etc/runlevels/$rl"
		for svc; do
			[ -e "$T/etc/init.d/$svc" ] || die "service $svc not installed"
			ln -sf "/etc/init.d/$svc" "$T/etc/runlevels/$rl/$svc"
		done; }
	rm -rf "$T/etc/runlevels"
	add sysinit  devfs dmesg moraine-gtt mdev hwdrivers
	add boot     modules sysctl hostname bootmisc syslog root fsck localmount \
	             seedrng networking moraine-growroot moraine-espimport moraine-issue
	add default  ntpd dropbear cyan-skillfish-governor-smu
	# llama-server only starts at boot once a model is configured
	# (moraine-setup enables it when you save a model).
	[ -n "$LLAMA_MODEL" ] && add default llama-server
	add shutdown killprocs mount-ro savecache
	:
	mkdir -p "$T/etc/runlevels/nonetwork"
}

stage_rootfs() {
	builder_mounts
	[ -f "$B/repo/build/$ARCH/APKINDEX.tar.gz" ] || die "no local packages; run ./build.sh packages"
	log "Target rootfs"

	grep -qs " $T/" /proc/mounts && die "something is still mounted under $T"
	rm -rf "$T"
	mkdir -p "$T/etc/apk/keys" "$T/var/lib/moraine" "$T/etc/moraine"
	cp "$B"/etc/apk/keys/* "$T/etc/apk/keys/"
	: > "$T/etc/moraine/image-build"

	# Local repo lives in the image too, so `apk fix`/reinstalls work on-device.
	cp -a "$B/repo" "$T/var/lib/moraine/repo"

	# edge/testing is tagged: its packages are only used when asked for
	# explicitly (apk add foo@testing), so it never upgrades stable ones.
	printf '%s/%s/main\n%s/%s/community\n/var/lib/moraine/repo/build\n@testing %s/edge/testing\n' \
		"$ALPINE_MIRROR" "$ALPINE_BRANCH" "$ALPINE_MIRROR" "$ALPINE_BRANCH" "$ALPINE_MIRROR" \
		> "$T/etc/apk/repositories"

	# Phase 1: bootstrap just enough of a root to run apk inside it.
	# `apk --root` runs package scripts in a new namespace, which fails in
	# some containers; anything that failed here is re-run in phase 2.
	bchroot "apk add --root /target --initdb --arch $ARCH --no-cache \
		-X $ALPINE_MIRROR/$ALPINE_BRANCH/main \
		alpine-baselayout alpine-keys busybox busybox-binsh apk-tools" || :
	chroot "$T" /bin/busybox --install -s

	# Phase 2: everything else, with apk running inside the target, so
	# scripts and triggers execute natively.
	proc_mount "$T/proc"
	bind_mount /dev "$T/dev"
	bind_mount /sys "$T/sys"
	cp -L /etc/resolv.conf "$T/etc/resolv.conf"
	local cabundle="$T/etc/ssl/certs/ca-certificates.crt"
	if [ -n "$EXTRA_CA_BUNDLE" ] && [ -f "$cabundle" ]; then
		cp "$cabundle" "$cabundle.moraine-orig"
		cat "$EXTRA_CA_BUNDLE" >> "$cabundle"
	fi
	tchroot "apk fix -q --no-cache"
	# shellcheck disable=SC2086
	tchroot "apk add --no-cache $(echo $TARGET_PKGS)"

	log "Configure"
	cp -a "$HERE/overlay/." "$T/"
	write_generated_config
	enable_services

	log "Initramfs + UKI"
	local kr
	kr=$(cat "$T/usr/share/kernel/lts/kernel.release")
	chroot "$T" /sbin/depmod -a "$kr"
	chroot "$T" /usr/sbin/moraine-mkuki -o /boot/BOOTX64.EFI "$kr"
	umount_all
	builder_mounts

	[ -f "$cabundle.moraine-orig" ] && mv -f "$cabundle.moraine-orig" "$cabundle"
	rm -f "$T/etc/moraine/image-build"
	rm -rf "$T/var/cache/apk/"* "$T/etc/resolv.conf"
	log "Rootfs size: $(du -sh "$T" | cut -f1)"
}

# --------------------------------------------------------------------------
stage_image() {
	[ -f "$T/boot/BOOTX64.EFI" ] || die "no UKI in target; run ./build.sh rootfs"
	grep -qs " $T/" /proc/mounts && die "something is still mounted under $T"
	builder_mounts
	log "Disk image"
	mkdir -p "$B/out" "$OUT"

	local used root_mb esp_mb total_mb
	esp_mb=$ESP_SIZE_MB
	used=$(du -sm "$T" | cut -f1)
	root_mb=${ROOT_SIZE_MB:-$((used + used / 4 + 256))}

	mv "$T/boot/BOOTX64.EFI" "$B/out/BOOTX64.EFI"
	bchroot "
		set -e
		cd /out
		rm -f esp.img root.img disk.img
		mkfs.vfat -C -F 32 -s 1 -n MORAINE esp.img $((esp_mb * 1024)) >/dev/null
		mmd -i esp.img ::/EFI ::/EFI/BOOT ::/moraine
		mcopy -i esp.img BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI
		mcopy -i esp.img /target/usr/share/moraine/esp/* ::/moraine/

		truncate -s ${root_mb}M root.img
		mkfs.ext4 -q -F -L moraine-root -m 1 -d /target root.img

		truncate -s $((1 + esp_mb + root_mb + 1))M disk.img
		sfdisk -q disk.img <<-EOF
			label: gpt
			start=2048, size=$((esp_mb * 2048)), type=U, name=\"ESP\"
			start=$(((1 + esp_mb) * 2048)), size=$((root_mb * 2048)), type=L, name=\"moraine-root\"
		EOF
		dd if=esp.img  of=disk.img bs=1M seek=1 conv=notrunc status=none
		dd if=root.img of=disk.img bs=1M seek=$((1 + esp_mb)) conv=notrunc status=none
		rm -f esp.img root.img
	"
	mv "$B/out/disk.img" "$OUT/$IMAGE_NAME"
	cp "$B/out/BOOTX64.EFI" "$OUT/BOOTX64.EFI"
	log "Done: $OUT/$IMAGE_NAME ($(du -h "$OUT/$IMAGE_NAME" | cut -f1))"
	echo "    Write it with:  dd if=$OUT/$IMAGE_NAME of=/dev/<disk> bs=4M conv=fsync status=progress"
}

# --------------------------------------------------------------------------
[ -n "${BC250_SOURCE_ONLY:-}" ] && return 0 2>/dev/null
[ "$(id -u)" = 0 ] || die "must run as root (chroot + bind mounts)"

case "${1:-all}" in
	builder)  stage_builder ;;
	packages) shift; stage_builder; stage_packages "$@" ;;
	rootfs)   stage_builder; stage_rootfs ;;
	image)    stage_image ;;
	all)      stage_builder; stage_packages; stage_rootfs; umount_all; stage_image ;;
	shell)    builder_mounts; chroot "$B" /bin/sh -l ;;
	clean)    umount_all; rm -rf "$WORK" ;;
	*)        die "usage: $0 [all|builder|packages|rootfs|image|shell|clean]" ;;
esac
