#!/bin/sh
set -eux

MNT=new
FILE=new.img
VND=vnd0

mkdir new
dd if=/dev/zero of=${FILE} bs=4096 count=1015200 progress=62000
vnconfig ${VND} ${FILE}
gpt create ${VND}
gpt add -a 4k -l swap -s 1G -t swap ${VND}
gpt add -a 4k -s 2G -l root -t ffs ${VND}
gpt show ${VND}

dkctl ${VND} makewedges
# newfs dos and ffs
sleep 2
newfs -O 2 -n 500000 -b 4096 /dev/rdk1
mount /dev/dk1 ${MNT}

for i in base.tgz etc.tgz kern-GENERIC.tgz; do
    curl -L http://ftp.fr.netbsd.org/pub/NetBSD/NetBSD-8.0/amd64/binary/sets/${i} | tar xfz - -C new
done
echo 'rc_configured=YES
sshd="YES"
resize_disklabel=YES
resize_disklabel_disk=ld0
resize_disklabel_part=a
resize_root=YES
resize_root_flags="-p"
resize_root_postcmd="/sbin/reboot -n"
' >> new/etc/rc.conf

echo '
NAME=root	/		ffs	rw	1 1
NAME=swap	none		swap	sw	0 0
kernfs		/kern		kernfs	rw
ptyfs		/dev/pts	ptyfs	rw
procfs /proc procfs rw
/dev/cd0a               /cdrom  cd9660  ro,noauto
tmpfs           /var/shm        tmpfs   rw,-m1777,-sram%25
' > new/etc/fstab
cp new/usr/mdec/boot new/boot
cp /boot.cfg new/boot.cfg
cp /etc/resolv.conf new/etc/resolv.conf


( cd new/dev ; ./MAKEDEV all )
PKG_PATH=http://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/amd64/8.0/All/
export PKG_PATH

curl -L https://github.com/goneri/cloud-init/archive/netbsd.tar.gz | tar xfz - -C new/tmp

chroot new sh -c 'cd /tmp/cloud-init-netbsd; ./tools/build-on-netbsd'

umount ${MNT}

gpt biosboot -L root ${VND} 
installboot -v -o timeout=1 /dev/rdk1 /usr/mdec/bootxx_ffsv2
vnconfig -u vnd0
