#!/bin/sh
# This file will be in /init_functions.sh inside the initramfs.
IP=172.16.42.1
ROOT_PARTITION_UNLOCKED=0
ROOT_PARTITION_RESIZED=0

setup_log() {
	# Save stdout/stderr for later
	exec 6>&1
	exec 7>&2
	# Redirects all output to a subshell which prepends "PMOS: " to each line
	# and then pipes to the logfile and the kernel logbuffer.
	# shellcheck disable=SC3001
	exec > >(awk '$0="PMOS: "$0' - | tee -a /pmOS_init.log /dev/kmsg >/dev/null)
	exec 2>&1

	echo "### postmarketOS initramfs ###"
	echo "NOTE: All output from the initramfs gets redirected to"
	echo "the kernel log buffer (dmesg) and /pmOS_init.log in the ramdisk"
}

# Reconfigure logging before switch_root
reconfigure_logging() {
	echo "Reconfiguring stdout/stderr $1"
	# For debugging, allow logging to the console
	if [ -n "$1" ] || grep -q PMOS_NO_OUTPUT_REDIRECT /proc/cmdline; then
		exec 1>&6 6>&-
		exec 2>&7 7>&-
		return
	fi

	# Pipe to /dev/null and delete the original stdout/stderr
	exec >/dev/null 6>&-
	exec 2>/dev/null 7>&-
}

mount_proc_sys_dev() {
	# mdev
	mount -t proc -o nodev,noexec,nosuid proc /proc || echo "Couldn't mount /proc"
	mount -t sysfs -o nodev,noexec,nosuid sysfs /sys || echo "Couldn't mount /sys"
	mount -t devtmpfs -o mode=0755,nosuid dev /dev || echo "Couldn't mount /dev"
	mount -t tmpfs -o nosuid,nodev,mode=0755 run /run || echo "Couldn't mount /run"

	mkdir /config
	mount -t configfs -o nodev,noexec,nosuid configfs /config

	# /dev/pts (needed for telnet)
	mkdir -p /dev/pts
	mount -t devpts devpts /dev/pts

	# Set up fd symlinks for I/O redirects
	ln -s /proc/self/fd /dev/fd
	ln -sf /proc/self/fd/0 /dev/stdin
	ln -sf /proc/self/fd/1 /dev/stdout
	ln -sf /proc/self/fd/2 /dev/stderr
}

setup_firmware_path() {
	# Add the postmarketOS-specific path to the firmware search paths.
	# This should be sufficient on kernel 3.10+, before that we need
	# the kernel calling udev (and in our case /usr/lib/firmwareload.sh)
	# to load the firmware for the kernel.
	echo "Configuring kernel firmware image search path"
	SYS=/sys/module/firmware_class/parameters/path
	if ! [ -e "$SYS" ]; then
		echo "Kernel does not support setting the firmware image search path. Skipping."
		return
	fi
	# shellcheck disable=SC3037
	echo -n /lib/firmware/postmarketos >$SYS
}

# shellcheck disable=SC3043
load_modules() {
	local file="$1"
	local modules="$2"
	[ -f "$file" ] && modules="$modules $(cat "$file")"
	# shellcheck disable=SC2086
	modprobe -a $modules
}

setup_mdev() {
	# Start mdev daemon
	mdev -d
}

setup_udev() {
	# Use udev to coldplug all devices so that they can be used via libinput (e.g.
	# by unl0kr). This is the same series of steps performed by the udev,
	# udev-trigger and udev-settle RC services. See also:
	# - https://git.alpinelinux.org/aports/tree/main/eudev/setup-udev
	# - https://git.alpinelinux.org/aports/tree/main/udev-init-scripts/APKBUILD
	if command -v udevd > /dev/null && command -v udevadm > /dev/null; then
		udevd -d
		udevadm trigger --type=devices --action=add
		udevadm settle
	fi
}

get_uptime_seconds() {
	# Get the current system uptime in seconds - ignore the two decimal places.
	awk -F '.' '{print $1}' /proc/uptime
}

setup_dynamic_partitions() {
	command -v make-dynpart-mappings > /dev/null || return
	attempt_start=$(get_uptime_seconds)
	wait_seconds=10
	slot_number=0
	for super_partition in $1; do
		# Wait for mdev
		echo "Waiting for super partition $super_partition..."
		while [ ! -b "$super_partition" ]; do
			if [ "$(get_uptime_seconds)" -ge $(( attempt_start + wait_seconds )) ]; then
				echo "ERROR: Super partition $super_partition failed to show up!"
				return;
			fi
			sleep 0.1
		done
		make-dynpart-mappings "$super_partition" "$slot_number"
		slot_number=$(( slot_number + 1 ))
	done
}

mount_subpartitions() {
	try_parts="/dev/disk/by-partlabel/userdata /dev/disk/by-partlabel/system* /dev/mapper/system*"
	android_parts=""
	for x in $try_parts; do
		[ -e "$x" ] && android_parts="$android_parts $x"
	done

	attempt_start=$(get_uptime_seconds)
	wait_seconds=10
	echo "Trying to mount subpartitions for $wait_seconds seconds..."
	while [ -z "$(find_boot_partition)" ]; do
		partitions="$android_parts $(grep -v "loop\|ram" < /proc/diskstats |\
			sed 's/\(\s\+[0-9]\+\)\+\s\+//;s/ .*//;s/^/\/dev\//')"
		for partition in $partitions; do
			case "$(kpartx -l "$partition" 2>/dev/null | wc -l)" in
				2)
					echo "Mount subpartitions of $partition"
					kpartx -afs "$partition"
					# Ensure that this was the *correct* subpartition
					# Some devices have mmc partitions that appear to have
					# subpartitions, but aren't our subpartition.
					if [ -n "$(find_boot_partition)" ]; then
						break
					fi
					kpartx -d "$partition"
					continue
					;;
				*)
					continue
					;;
			esac
		done
		if [ "$(get_uptime_seconds)" -ge $(( attempt_start + wait_seconds )) ]; then
			echo "ERROR: failed to mount subpartitions!"
			return;
		fi
		sleep 0.1;
	done
}

find_root_partition() {
	# The partition layout is one of the following:
	# a) boot, root partitions on sdcard
	# b) boot, root partition on the "system" partition (which has its
	#    own partition header! so we have partitions on partitions!)
	#
	# mount_subpartitions() must get executed before calling
	# find_root_partition(), so partitions from b) also get found.

	# Short circuit all autodetection logic if pmos_root= or
	# pmos_root_uuid= is supplied on the kernel cmdline
	# shellcheck disable=SC2013
	if [ "$ROOT_PARTITION_UNLOCKED" = 0 ]; then
		for x in $(cat /proc/cmdline); do
			[ "$x" = "${x#pmos_root_uuid=}" ] && continue
			DEVICE="$(findfs UUID="${x#pmos_root_uuid=}")"
		done

		for x in $(cat /proc/cmdline); do
			[ "$x" = "${x#pmos_root=}" ] && continue
			DEVICE="${x#pmos_root=}"
		done

		# On-device installer: before postmarketOS is installed,
		# we want to use the installer partition as root. It is the
		# partition behind pmos_root. pmos_root will either point to
		# reserved space, or to an unfinished installation.
		# p1: boot
		# p2: (reserved space) <--- pmos_root
		# p3: pmOS_install
		# Details: https://postmarketos.org/on-device-installer
		if [ -n "$DEVICE" ]; then
			next="$(echo "$DEVICE" | sed 's/2$/3/')"

			# If the next partition is labeled pmOS_install (and
			# not pmOS_deleteme), then postmarketOS is not
			# installed yet.
			if blkid | grep "$next" | grep -q pmOS_install; then
				DEVICE="$next"
			fi
		fi
	fi

	# Try partitions in /dev/mapper and /dev/dm-* first
	if [ -z "$DEVICE" ]; then
		for id in pmOS_install pmOS_root crypto_LUKS; do
			for path in /dev/mapper /dev/dm; do
				DEVICE="$(blkid | grep "$path" | grep "$id" \
					| cut -d ":" -f 1 | head -n 1)"
				[ -z "$DEVICE" ] || break 2
			done
		done
	fi

	# Then try all devices
	if [ -z "$DEVICE" ]; then
		for id in pmOS_install pmOS_root crypto_LUKS; do
			DEVICE="$(blkid | grep "$id" | cut -d ":" -f 1 \
				| head -n 1)"
			[ -z "$DEVICE" ] || break
		done
	fi
	echo "$DEVICE"
}

find_boot_partition() {
	# shellcheck disable=SC2013
	for x in $(cat /proc/cmdline); do
		[ "$x" = "${x#pmos_boot_uuid=}" ] && continue
		findfs UUID="${x#pmos_boot_uuid=}"
		return
	done

	# shellcheck disable=SC2013
	for x in $(cat /proc/cmdline); do
		[ "$x" = "${x#pmos_boot=}" ] && continue
		echo "${x#pmos_boot=}"
		return
	done

	# * "pmOS_i_boot" installer boot partition (fits 11 chars for fat32)
	# * "pmOS_inst_boot" old installer boot partition (backwards compat)
	# * "pmOS_boot" boot partition after installation
	findfs LABEL="pmOS_i_boot" \
		|| findfs LABEL="pmOS_inst_boot" \
		|| findfs LABEL="pmOS_boot"
}

get_partition_type() {
	partition="$1"
	blkid "$partition" | sed 's/^.*TYPE="\([a-zA-z0-9_]*\)".*$/\1/'
}

# $1: path
# $2: set to "rw" for read-write
# Mount the boot partition. It gets mounted twice, first at /boot (ro), then at
# /sysroot/boot (rw), after root has been mounted at /sysroot, so we can
# switch_root to /sysroot and have the boot partition properly mounted.
mount_boot_partition() {
	partition=$(find_boot_partition)
	if [ -z "$partition" ]; then
		echo "ERROR: boot partition not found!"
		show_splash "ERROR: Boot partition not found\\nhttps://postmarketos.org/troubleshooting"
		loop_forever
	fi

	if [ "$2" = "rw" ]; then
		mount_opts=""
		echo "Mount boot partition ($partition) to $1 (read-write)"
	else
		mount_opts="-o ro"
		echo "Mount boot partition ($partition) to $1 (read-only)"
	fi

	type="$(get_partition_type "$partition")"
	case "$type" in
		ext*)
			echo "Detected ext filesystem"
			modprobe ext4
			# ext2 might be handled by the ext2 or ext4 kernel module
			# so let mount detect that automatically by omitting -t
			;;
		vfat)
			echo "Detected vfat filesystem"
			modprobe vfat
			mount_opts="-t vfat $mount_opts"
			;;
		*)	echo "WARNING: Detected unsupported '$type' filesystem ($partition)." ;;
	esac

	# shellcheck disable=SC2086
	mount $mount_opts "$partition" "$1"
}

# $1: initramfs-extra path
extract_initramfs_extra() {
	initramfs_extra="$1"
	if [ ! -e "$initramfs_extra" ]; then
		echo "ERROR: initramfs-extra not found!"
		show_splash "ERROR: initramfs-extra not found\\nhttps://postmarketos.org/troubleshooting"
		loop_forever
	fi
	echo "Extract $initramfs_extra"
	# uncompressed:
	# cpio -di < "$initramfs_extra"
	gzip -d -c "$initramfs_extra" | cpio -i
}

wait_root_partition() {
	while [ -z "$(find_root_partition)" ]; do
		show_splash "ERROR: root partition not found\\nhttps://postmarketos.org/troubleshooting"
		echo "Could not find the rootfs."
		echo "Maybe you need to insert the sdcard, if your device has"
		echo "any? Trying again in one second..."
		sleep 1
	done
}

delete_old_install_partition() {
	# The on-device installer leaves a "pmOS_deleteme" (p3) partition after
	# successful installation, located after "pmOS_root" (p2). Delete it,
	# so we can use the space.
	partition="$(find_root_partition | sed 's/2$/3/')"
	if ! blkid "$partition" | grep -q pmOS_deleteme; then
		return
	fi

	device="$(echo "$partition" | sed -E 's/p?3$//')"
	echo "First boot after running on-device installer - deleting old" \
		"install partition: $partition"
	parted -s "$device" rm 3
}

# $1: path to device
has_unallocated_space() {
	# Check if there is unallocated space at the end of the device
	parted -s "$1" print free | tail -n2 | \
		head -n1 | grep -qi "free space"
}

resize_root_partition() {
	partition=$(find_root_partition)

	# Do not resize the installer partition
	if blkid "$partition" | grep -q pmOS_install; then
		echo "Resize root partition: skipped (on-device installer)"
		return
	fi

	# Only resize the partition if it's inside the device-mapper, which means
	# that the partition is stored as a subpartition inside another one.
	# In this case we want to resize it to use all the unused space of the
	# external partition.
	if [ -z "${partition##"/dev/mapper/"*}" ]; then
		# Get physical device
		partition_dev=$(dmsetup deps -o blkdevname "$partition" | \
			awk -F "[()]" '{print "/dev/"$2}')
		if has_unallocated_space "$partition_dev"; then
			echo "Resize root partition ($partition)"
			# unmount subpartition, resize and remount it
			kpartx -d "$partition"
			parted -f -s "$partition_dev" resizepart 2 100%
			kpartx -afs "$partition_dev"
			ROOT_PARTITION_RESIZED=1
		fi
	fi

	# Resize the root partition (non-subpartitions). Usually we do not want
	# this, except for QEMU devices and non-android devices (e.g.
	# PinePhone). For them, it is fine to use the whole storage device and
	# so we pass PMOS_FORCE_PARTITION_RESIZE as kernel parameter.
	if grep -q PMOS_FORCE_PARTITION_RESIZE /proc/cmdline; then
		partition_dev="$(echo "$partition" | sed -E 's/p?2$//')"
		if has_unallocated_space "$partition_dev"; then
			echo "Resize root partition ($partition)"
			parted -f -s "$partition_dev" resizepart 2 100%
			partprobe
			ROOT_PARTITION_RESIZED=1
		fi
	fi

	# Resize the root partition (non-subpartitions) on Chrome OS devices.
	# Match $deviceinfo_cgpt_kpart not being empty instead of cmdline
	# because it does not make sense here as all these devices use the same
	# partitioning methods. This also resizes third partition instead of
	# second, because these devices have an additional kernel partition
	# at the start.
	if [ -n "$deviceinfo_cgpt_kpart" ]; then
		partition_dev="$(echo "$partition" | sed -E 's/p?3$//')"
		if has_unallocated_space "$partition_dev"; then
			echo "Resize root partition ($partition)"
			parted -f -s "$partition_dev" resizepart 3 100%
			partprobe
			ROOT_PARTITION_RESIZED=1
		fi
	fi
}

unlock_root_partition() {
	partition="$(find_root_partition)"
	if cryptsetup isLuks "$partition"; then
		# Make sure the splash doesn't interfere
		killall pbsplash 2>/dev/null
		tried=0
		until cryptsetup status root | grep -qwi active; do
			fde-unlock "$partition" "$tried"
			tried=$((tried + 1))
		done
		ROOT_PARTITION_UNLOCKED=1
		# Show again the loading splashscreen
		show_splash "Loading..."
	fi
}

resize_root_filesystem() {
	if [ "$ROOT_PARTITION_RESIZED" = 1 ]; then
		show_splash "Resizing filesystem during initial boot..."
		partition="$(find_root_partition)"
		touch /etc/mtab # see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=673323
		type="$(get_partition_type "$partition")"
		case "$type" in
			ext4)
				echo "Resize 'ext4' root filesystem ($partition)"
				modprobe ext4
				resize2fs -f "$partition"
				;;
			f2fs)
				echo "Resize 'f2fs' root filesystem ($partition)"
				modprobe f2fs
				resize.f2fs "$partition"
				;;
			btrfs)
				echo "Resize 'btrfs' root filesystem ($partition)"
				modprobe btrfs
				resize_root_filesystem_tmp_btrfs="$(mktemp -d)"
				mount -t btrfs "$partition" "$resize_root_filesystem_tmp_btrfs"
				btrfs filesystem resize max "$resize_root_filesystem_tmp_btrfs"
				umount "$resize_root_filesystem_tmp_btrfs"
				unset resize_root_filesystem_tmp_btrfs
				;;
			*)	echo "WARNING: Can not resize '$type' filesystem ($partition)." ;;
		esac
		show_splash "Loading..."
	fi
}

mount_root_partition() {
	partition="$(find_root_partition)"
	rootfsopts=""

	# shellcheck disable=SC2013
	for x in $(cat /proc/cmdline); do
		[ "$x" = "${x#pmos_rootfsopts=}" ] && continue
		# Prepend a comma because this will be appended to "ro" below
		rootfsopts=",${x#pmos_rootfsopts=}"
	done

	echo "Mount root partition ($partition) to /sysroot (read-only) with options ${rootfsopts#,}"
	type="$(get_partition_type "$partition")"
	echo "Detected $type filesystem"

	if ! { [ "$type" = "ext4" ] || [ "$type" = "f2fs" ] || [ "$type" = "btrfs" ]; } then
		echo "ERROR: Detected unsupported '$type' filesystem ($partition)."
		show_splash "ERROR: unsupported '$type' filesystem ($partition)\\nhttps://postmarketos.org/troubleshooting"
		loop_forever
	fi

	if ! modprobe "$type"; then
		echo "INFO: unable to load module '$type' - maybe it's built in"
	fi
	if ! mount -t "$type" -o ro"$rootfsopts" "$partition" /sysroot; then
		echo "ERROR: unable to mount root partition!"
		show_splash "ERROR: unable to mount root partition\\nhttps://postmarketos.org/troubleshooting"
		loop_forever
	fi

	if ! [ -e /sysroot/usr ]; then
		echo "ERROR: root partition appeared to mount but does not contain a root filesystem!"
		show_splash "ERROR: root partition does not contain a root filesystem\\nhttps://postmarketos.org/troubleshooting"
		loop_forever
	fi
}

# $1: path to the hooks dir
run_hooks() {
	scriptsdir="$1"

	if ! [ -d "$scriptsdir" ]; then
		return
	fi

	for hook in "$scriptsdir"/*.sh; do
		echo "Running initramfs hook: $hook"
		sh "$hook"
	done
}

setup_usb_network_android() {
	# Only run, when we have the android usb driver
	SYS=/sys/class/android_usb/android0
	if ! [ -e "$SYS" ]; then
		echo "  /sys/class/android_usb does not exist, skipping android_usb"
		return
	fi

	echo "  Setting up an USB gadget through android_usb"

	usb_idVendor="$(echo "${deviceinfo_usb_idVendor:-0x18D1}" | sed "s/0x//g")"	# default: Google Inc.
	usb_idProduct="$(echo "${deviceinfo_usb_idProduct:-0xD001}" | sed "s/0x//g")"	# default: Nexus 4 (fastboot)

	# Do the setup
	echo "0" >"$SYS/enable"
	echo "$usb_idVendor" >"$SYS/idVendor"
	echo "$usb_idProduct" >"$SYS/idProduct"
	echo "rndis" >"$SYS/functions"
	echo "1" >"$SYS/enable"
}

setup_usb_network_configfs() {
	# See: https://www.kernel.org/doc/Documentation/usb/gadget_configfs.txt
	CONFIGFS=/config/usb_gadget

	if ! [ -e "$CONFIGFS" ]; then
		echo "  /config/usb_gadget does not exist, skipping configfs usb gadget"
		return
	fi

	# Default values for USB-related deviceinfo variables
	usb_idVendor="${deviceinfo_usb_idVendor:-0x18D1}"   # default: Google Inc.
	usb_idProduct="${deviceinfo_usb_idProduct:-0xD001}" # default: Nexus 4 (fastboot)
	usb_serialnumber="${deviceinfo_usb_serialnumber:-postmarketOS}"
	usb_network_function="${deviceinfo_usb_network_function:-rndis.usb0}"

	echo "  Setting up an USB gadget through configfs"
	# Create an usb gadet configuration
	mkdir $CONFIGFS/g1 || echo "  Couldn't create $CONFIGFS/g1"
	echo "$usb_idVendor"  > "$CONFIGFS/g1/idVendor"
	echo "$usb_idProduct" > "$CONFIGFS/g1/idProduct"

	# Create english (0x409) strings
	mkdir $CONFIGFS/g1/strings/0x409 || echo "  Couldn't create $CONFIGFS/g1/strings/0x409"

	# shellcheck disable=SC2154
	echo "$deviceinfo_manufacturer" > "$CONFIGFS/g1/strings/0x409/manufacturer"
	echo "$usb_serialnumber"        > "$CONFIGFS/g1/strings/0x409/serialnumber"
	# shellcheck disable=SC2154
	echo "$deviceinfo_name"         > "$CONFIGFS/g1/strings/0x409/product"

	# Create network function.
	mkdir $CONFIGFS/g1/functions/"$usb_network_function" \
		|| echo "  Couldn't create $CONFIGFS/g1/functions/$usb_network_function"

	# Create configuration instance for the gadget
	mkdir $CONFIGFS/g1/configs/c.1 \
		|| echo "  Couldn't create $CONFIGFS/g1/configs/c.1"
	mkdir $CONFIGFS/g1/configs/c.1/strings/0x409 \
		|| echo "  Couldn't create $CONFIGFS/g1/configs/c.1/strings/0x409"
	echo "USB network" > $CONFIGFS/g1/configs/c.1/strings/0x409/configuration \
		|| echo "  Couldn't write configration name"

	# Link the network instance to the configuration
	ln -s $CONFIGFS/g1/functions/"$usb_network_function" $CONFIGFS/g1/configs/c.1 \
		|| echo "  Couldn't symlink $usb_network_function"

	# Check if there's an USB Device Controller
	if [ -z "$(ls /sys/class/udc)" ]; then
		echo "  No USB Device Controller available"
		return
	fi

	# Link the gadget instance to an USB Device Controller. This activates the gadget.
	# See also: https://github.com/postmarketOS/pmbootstrap/issues/338
	# shellcheck disable=SC2005
	echo "$(ls /sys/class/udc)" > $CONFIGFS/g1/UDC || echo "  Couldn't write UDC"
}

setup_usb_network() {
	# Only run once
	_marker="/tmp/_setup_usb_network"
	[ -e "$_marker" ] && return
	touch "$_marker"
	echo "Setup usb network"
	# Run all usb network setup functions (add more below!)
	setup_usb_network_android
	setup_usb_network_configfs
}

start_unudhcpd() {
	# Only run once
	[ "$(pidof unudhcpd)" ] && return

	# Skip if disabled
	# shellcheck disable=SC2154
	if [ "$deviceinfo_disable_dhcpd" = "true" ]; then
		echo "NOTE: start of dhcpd is disabled (deviceinfo_disable_dhcpd)"
		return
	fi

	echo "Starting unudhcpd"
	# Get usb interface
	INTERFACE=""
	ifconfig rndis0 "$IP" 2>/dev/null && INTERFACE=rndis0
	if [ -z $INTERFACE ]; then
		ifconfig usb0 "$IP" 2>/dev/null && INTERFACE=usb0
	fi
	if [ -z $INTERFACE ]; then
		ifconfig eth0 "$IP" 2>/dev/null && INTERFACE=eth0
	fi

	if [ -z $INTERFACE ]; then
		echo "  Could not find an interface to run a dhcp server on"
		echo "  Interfaces:"
		ip link
		return
	fi

	echo "  Using interface $INTERFACE"
	echo "  Starting the DHCP daemon"
	(
		unudhcpd -i "$INTERFACE" -s 172.16.42.1 -c 172.16.42.2
	) &
}

# $1: Message to show
show_splash() {
	# Skip for non-framebuffer devices
	# shellcheck disable=SC2154
	if [ "$deviceinfo_no_framebuffer" = "true" ]; then
		echo "NOTE: Skipping framebuffer splashscreen (deviceinfo_no_framebuffer)"
		return
	fi

	# Disable splash
	if grep -q PMOS_NOSPLASH /proc/cmdline; then
		return
	fi

	killall pbsplash 2>/dev/null

	while pgrep pbsplash >/dev/null; do
		sleep 0.01
	done

	# shellcheck disable=SC2154,SC2059
	/usr/bin/pbsplash -s /usr/share/pbsplash/pmos-logo-text.svg \
		-b "Linux $(uname -r) | $deviceinfo_codename" \
		-m "$(printf "$1")" >/dev/null &
}

set_framebuffer_mode() {
	[ -e "/sys/class/graphics/fb0/modes" ] || return
	[ -z "$(cat /sys/class/graphics/fb0/mode)" ] || return

	_mode="$(cat /sys/class/graphics/fb0/modes)"
	echo "Setting framebuffer mode to: $_mode"
	echo "$_mode" > /sys/class/graphics/fb0/mode
}

setup_framebuffer() {
	# Skip for non-framebuffer devices
	# shellcheck disable=SC2154
	if [ "$deviceinfo_no_framebuffer" = "true" ]; then
		echo "NOTE: Skipping framebuffer setup (deviceinfo_no_framebuffer)"
		return
	fi

	# Wait for /dev/fb0
	echo "NOTE: Waiting 10 seconds for the framebuffer /dev/fb0."
	echo "If your device does not have a framebuffer, disable this with:"
	echo "no_framebuffer=true in <https://postmarketos.org/deviceinfo>"
	for _ in $(seq 1 100); do
		[ -e "/dev/fb0" ] && break
		sleep 0.1
	done
	if ! [ -e "/dev/fb0" ]; then
		echo "ERROR: /dev/fb0 did not appear!"
		return
	fi

	set_framebuffer_mode
}

setup_bootchart2() {
	if grep -q PMOS_BOOTCHART2 /proc/cmdline; then
		if [ -f "/sysroot/sbin/bootchartd" ]; then
			# shellcheck disable=SC2034
			init="/sbin/bootchartd"
			echo "remounting /sysroot as rw for /sbin/bootchartd"
			mount -o remount, rw /sysroot

			# /dev/null may not exist at the first boot after
			# the root filesystem has been created.
			[ -c /sysroot/dev/null ] && return
			echo "creating /sysroot/dev/null for /sbin/bootchartd"
			mknod -m 666 "/sysroot/dev/null" c 1 3
		else
			echo "WARNING: bootchart2 is not installed."
		fi
	fi
}

loop_forever() {
	while true; do
		sleep 1
	done
}
