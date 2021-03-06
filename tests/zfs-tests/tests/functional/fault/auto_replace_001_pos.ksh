#!/bin/ksh -p
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#
#
# Copyright (c) 2017 by Intel Corporation. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/fault/fault.cfg

#
# DESCRIPTION:
# Testing Fault Management Agent ZED Logic - Automated Auto-Replace Test.
#
# STRATEGY:
# 1. Update /etc/zfs/vdev_id.conf with scsidebug alias rule for a persistent
#    path. This creates keys ID_VDEV and ID_VDEV_PATH and sets
#    phys_path="scsidebug".
# 2. Create a pool & set autoreplace=on (auto-replace is opt-in)
# 2. Export a pool
# 3. Offline disk by removing scsi_debug module
# 4. Import pool with missing disk
# 5. Online disk by loading scsi_debug module again and re-registering vdev_id
#    rule.
# 6. ZED polls for an event change for new disk to be automatically
#    added back to the pool
#
# Creates a raidz1 zpool using persistent disk path names
# (ie not /dev/sdc)
#
# Auto-replace is opt in, and matches by phys_path.
#

verify_runnable "both"

if ! is_physical_device $DISKS; then
	log_unsupported "Unsupported disks for this test."
fi

function setup
{
	$LSMOD | $EGREP scsi_debug > /dev/null
	if (($? == 1)); then
		load_scsi_debug $SDSIZE $SDHOSTS $SDTGTS $SDLUNS
	fi
	# Register vdev_id alias rule for scsi_debug device to create a
	# persistent path
	SD=$($LSSCSI | $NAWK '/scsi_debug/ {print $6; exit}' \
	    | $NAWK -F / '{print $3}')
	SDDEVICE_ID=$(get_persistent_disk_name $SD)
	log_must eval "$ECHO "alias scsidebug /dev/disk/by-id/$SDDEVICE_ID" \
	    >> $VDEVID_CONF"
	block_device_wait

	SDDEVICE=$($UDEVADM info -q all -n $DEV_DSKDIR/$SD | $EGREP ID_VDEV \
	    | $NAWK '{print $2; exit}' | $NAWK -F = '{print $2; exit}')
	[[ -z $SDDEVICE ]] && log_fail "vdev rule was not registered properly"
}

function cleanup
{
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
}

log_assert "Testing automated auto-replace FMA test"

log_onexit cleanup

# Clear disk labels
for i in {0..2}
do
	log_must $ZPOOL labelclear -f /dev/disk/by-id/"${devs_id[i]}"
done

setup
if is_loop_device $DISK1; then
	log_must $ZPOOL create -f $TESTPOOL raidz1 $SDDEVICE $DISK1 $DISK2 \
	    $DISK3
elif ( is_real_device $DISK1 || is_mpath_device $DISK1 ); then
	log_must $ZPOOL create -f $TESTPOOL raidz1 $SDDEVICE ${devs_id[0]} \
	    ${devs_id[1]} ${devs_id[2]}
else
	log_fail "Disks are not supported for this test"
fi

# Auto-replace is opt-in so need to set property
log_must $ZPOOL set autoreplace=on $TESTPOOL

# Add some data to the pool
log_must $MKFILE $FSIZE /$TESTPOOL/data

log_must $ZPOOL export -F $TESTPOOL

# Offline disk
on_off_disk $SD "offline"
block_device_wait
log_must $MODUNLOAD scsi_debug

# Reimport pool with drive missing
log_must $ZPOOL import $TESTPOOL
check_state $TESTPOOL "" "degraded"
if (($? != 0)); then
	log_fail "$TESTPOOL is not degraded"
fi

# Clear zpool events
$ZPOOL events -c $TESTPOOL

# Create another scsi_debug device
setup

log_note "Delay for ZED auto-replace"
typeset -i timeout=0
while true; do
	if ((timeout == $MAXTIMEOUT)); then
		log_fail "Timeout occured"
	fi
	((timeout++))
	$SLEEP 1
	$ZPOOL events $TESTPOOL | $EGREP sysevent.fs.zfs.resilver_finish \
	    > /dev/null
	if (($? == 0)); then
		log_note "Auto-replace should be complete"
		$SLEEP 1
		break
	fi
done

# Validate auto-replace was successful
check_state $TESTPOOL "" "online"
if (($? != 0)); then
	log_fail "$TESTPOOL is not back online"
fi
$SLEEP 2

log_must $ZPOOL destroy $TESTPOOL

log_pass "Auto-replace test successful"
