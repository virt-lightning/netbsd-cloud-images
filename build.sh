#!/bin/sh
version=$1
if [ -z $version ]; then
    echo "Usage $0 version"
    exit 1
fi
set -eux

PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/pkg/sbin:/usr/pkg/bin
MNT=$HOME/new
VND=vnd0
export PATH
file="final.raw"
mkdir -p ${MNT}
dd if=/dev/zero of=${file} bs=4096 count=1000000 progress=62000
vnconfig ${VND} ${file}
gpt create ${VND}
gpt add -a 4k -l swap -s 1G -t swap ${VND}
gpt add -a 4k -s 2G -l root -t ffs ${VND}
gpt show ${VND}

dkctl ${VND} makewedges
dk_dev=$(dkctl ${VND} listwedges|grep ffs|sed 's,:.*,,')
# newfs dos and ffs
sleep 2
newfs -O 2 -n 500000 -b 4096 /dev/r${dk_dev}
mount /dev/${dk_dev} ${MNT}

for i in base.tgz etc.tgz kern-GENERIC.tgz; do
    curl -L http://ftp.fr.netbsd.org/pub/NetBSD/NetBSD-${version}/amd64/binary/sets/${i} | tar xfz - -C ${MNT}
done
sed -i'' "s/^rc_configured=.*/rc_configured=YES/" $MNT/etc/rc.conf
echo 'sshd=YES
grow_root_fs=YES
' >> $MNT/etc/rc.conf

echo '#!/bin/sh
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
gpt resize -i 2 ld0 && reboot
if resize_ffs -c /dev/r$(sysctl -r kern.root_device); then
    resize_ffs -p -y -v /dev/r$(sysctl -r kern.root_device) && reboot -n
else
    sed -i "s,grow_root_fs=.*,# grow_root_fs=NO  # Auto-disabled," /etc/rc.conf
fi
}

load_rc_config $name
run_rc_command "$1"
' > $MNT/etc/rc.d/grow_root_fs
chmod +x $MNT/etc/rc.d/grow_root_fs


echo '
NAME=root	/		ffs	rw	1 1
NAME=swap	none		swap	sw	0 0
kernfs		/kern		kernfs	rw
ptyfs		/dev/pts	ptyfs	rw
procfs /proc procfs rw
/dev/cd0a               /cdrom  cd9660  ro,noauto
tmpfs           /var/shm        tmpfs   rw,-m1777,-sram%25
' > $MNT/etc/fstab
cp $MNT/usr/mdec/boot $MNT/boot
cp /boot.cfg $MNT/boot.cfg
cp /etc/resolv.conf $MNT/etc/resolv.conf

chroot $HOME/new sh -c "echo 'export PKG_PATH=ftp://ftp.netbsd.org/pub/pkgsrc/packages/NetBSD/amd64/${version}/All/' >> /etc/profile"

( cd $MNT/dev ; ./MAKEDEV all )

curl -L -k https://github.com/goneri/cloud-init/archive/netbsd.tar.gz | tar xfz - -C $MNT/tmp

chroot $HOME/new sh -c '. /etc/profile; cd /tmp/cloud-init-netbsd; ./tools/build-on-netbsd'
chroot $HOME/new sh -c '. /etc/profile; pkg_add pkgin'
chroot $HOME/new sh -c '. /etc/profile; pkgin update'
#chroot $HOME/new sh -c 'usermod -C yes root'
chmod +t ${MNT}/tmp
mkdir ${MNT}/kern
mkdir ${MNT}/proc
umount ${MNT}

gpt biosboot -L root ${VND} 
installboot -v -o timeout=0 /dev/r${dk_dev} /usr/mdec/bootxx_ffsv2
vnconfig -u vnd0
