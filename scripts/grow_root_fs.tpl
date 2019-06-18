#!/bin/sh
#
# PROVIDE: grow_root_fs
# BEFORE:  fsck_root

$_rc_subr_loaded . /etc/rc.subr

name="grow_root_fs"
rcvar=$name
start_cmd="grow_root_fs_start"
stop_cmd=":"

grow_root_fs_start()
{
	gpt resizedisk ld0
	gpt resize -i %%FFS_INDEX%% ld0 && reboot
	if resize_ffs -c /dev/r$(sysctl -r kern.root_device); then
		resize_ffs -p -y -v /dev/r$(sysctl -r kern.root_device) && reboot -n
	else
		sed -i "s,grow_root_fs=.*,# grow_root_fs=NO  # Auto-disabled," /etc/rc.conf
	fi
}

load_rc_config $name
run_rc_command "$1"
