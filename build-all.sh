#!/bin/sh
# Optional args:
# -e		- enable UEFI firmware (from current host)
# -v "8.1"	- build version
EFI=0			# no UEFI by default
MNT=$( mktemp -d )	# image mount point
EFIMNT=			# efi partition mount point
VND=vnd0
VERSION="8.0 7.2"
# NetBSD no readlink in base ?
#MYDIR=$( dirname `readlink $0` )
# get cwd
case "${0}" in
	.*)
		MYDIR=${PWD%%./*} ;;
	*)
		MYDIR=$( dirname $0 ) ;;
esac

cleanup()
{
	umount -f ${MNT} > /dev/null 2>&1 || true
	[ -d "${EFIMNT}" ] && -f ${EFIMNT} > /dev/null 2>&1 || true
	vnconfig -u ${VND}
	[ -d "${MNT}" ] && rmdir ${MNT} || true
	[ -d "${EFIMNT}" ] && rmdir ${EFIMNT} || true
}

while getopts "ev:" opt; do
	case "${opt}" in
		e) EFI=1 ;;
		v) VERSION="${OPTARG}" ;;
	esac
done

trap "cleanup" HUP INT ABRT BUS TERM EXIT

set -eux

for version in $VERSION; do
file="netbsd-${version}.raw"
dd if=/dev/zero of=${file} bs=4096 count=1000000 progress=62000
vnconfig ${VND} ${file}
gpt create ${VND}
[ ${EFI} -eq 1 ] && gpt add -a 2m -l "EFI system" -t efi -s 128m ${VND}
gpt add -a 4k -l swap -s 1G -t swap ${VND}
gpt add -a 4k -s 2G -l root -t ffs ${VND}
gpt show ${VND}

dkctl ${VND} makewedges
dk_dev=$(dkctl ${VND} listwedges|grep ffs|sed 's,:.*,,')
if [ ${EFI} -eq 1 ]; then
	dk_efi_dev=$( dkctl ${VND} listwedges |awk '/type: msdos/{print $1}' | tr -d ":" )
	if [ -z "${dk_efi_dev}" ]; then
		echo "Unable to locate EFI gpt"
		exit 1
	fi

	newfs_msdos /dev/r${dk_efi_dev}
	EFIMNT=$( mktemp -d )
	mount -t msdos /dev/${dk_efi_dev} ${EFIMNT}
	mkdir -p ${EFIMNT}/EFI/boot
	cp /usr/mdec/*.efi ${EFIMNT}/EFI/boot/
	umount ${EFIMNT}
	rmdir ${EFIMNT}
	FFS_INDEX="3"
else
	FFS_INDEX="2"
fi
# newfs dos and ffs
sleep 2
newfs -O 2 -n 500000 -b 4096 /dev/r${dk_dev}
mount /dev/${dk_dev} ${MNT}

for i in base.tgz etc.tgz kern-GENERIC.tgz; do
	curl -L http://ftp.fr.netbsd.org/pub/NetBSD/NetBSD-${version}/amd64/binary/sets/${i} | tar xfz - -C ${MNT}
done

echo 'rc_configured=YES
sshd=YES
dhcpcd=YES
grow_root_fs=YES
' >> $MNT/etc/rc.conf

# Adjust FFS index in rc.d script template
sed -Ees:%%FFS_INDEX%%:"${FFS_INDEX}":g \
	${MYDIR}/scripts/grow_root_fs.tpl > ${MNT}/etc/rc.d/grow_root_fs
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

cat >> $MNT/etc/profile <<EOF
PKG_PATH=http://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/x86_64/${version}/All/
export PKG_PATH
EOF

( cd $MNT/dev ; ./MAKEDEV all )
PKG_PATH=http://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/x86_64/${version}/All/
export PKG_PATH

curl -L -k https://github.com/goneri/cloud-init/archive/netbsd.tar.gz | tar xfz - -C $MNT/tmp

chroot ${MNT} sh -c 'cd /tmp/cloud-init-netbsd; ./tools/build-on-netbsd'
chmod +t ${MNT}/tmp
umount ${MNT}

gpt biosboot -L root ${VND} 
installboot -v -o timeout=0 /dev/r${dk_dev} /usr/mdec/bootxx_ffsv2
done
