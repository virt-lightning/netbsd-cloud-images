#!/bin/sh
version=$1
repo=$2
ref=$3
debug=$4
if [ -z $version ]; then
    echo "Usage $0 version"
    exit 1
fi
if [ -z "${repo}" ]; then
    repo="canonical/cloud-init"
fi
if [ -z "${ref}" ]; then
    ref="master"
fi
if [ -z "${debug}" ]; then
    debug=""
fi


PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/pkg/sbin:/usr/pkg/bin
MNT=$HOME/new
VND=vnd0

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

# Optional args:
# -e       - enable UEFI firmware (from current host)
# -v "8.1" - build version
EFI=0          # no UEFI by default
MNT=$( mktemp -d ) # image mount point
EFIMNT=            # efi partition mount point
export PATH
file="final.raw"
mkdir -p ${MNT}
dd if=/dev/zero of=${file} bs=4096 count=400000 progress=62000
vnconfig ${VND} ${file}
gpt create ${VND}
[ ${EFI} -eq 1 ] && gpt add -a 2m -l "EFI system" -t efi -s 128m ${VND}
gpt add -a 4k -l swap -s 512m -t swap ${VND}
gpt add -a 4k -s 1000m -l root -t ffs ${VND}
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

if echo $version|egrep "^[78]"; then
    base_packages="base.tgz etc.tgz kern-GENERIC.tgz"
else
    base_packages="base.tar.xz etc.tar.xz kern-GENERIC.tar.xz"
fi
for i in ${base_packages}; do
    curl -L http://ftp.fr.netbsd.org/pub/NetBSD/NetBSD-${version}/amd64/binary/sets/${i} | tar xfz - -C ${MNT}
done
sed -i'' "s/^rc_configured=.*/rc_configured=YES/" $MNT/etc/rc.conf
echo 'sshd=YES
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

#Enable serial console
echo 'menu=Boot with serial console:consdev com0;boot
menu=Boot without serial console;boot
default=1
timeout=0' > $MNT/boot.cfg
sed -i 's,^tty00.*,tty00\t"/usr/libexec/getty std.9600"   vt100 on secure,' $MNT/etc/ttys

cp /etc/resolv.conf $MNT/etc/resolv.conf

# TODO: use $version again once 9.0 is ready
echo "PKG_PATH=ftp://ftp.NetBSD.org/pub/pkgsrc/packages/NetBSD/amd64/$version/All/" >> $MNT/etc/pkg_install.conf

( cd $MNT/dev ; ./MAKEDEV all )

curl -L -k https://github.com/${repo}/archive/${ref}.tar.gz | tar xfz - -C $MNT/tmp


chroot $MNT sh -c '. /etc/profile; cd /tmp/cloud-init-*; ./tools/build-on-netbsd'
chroot $MNT sh -c '. /etc/profile; pkg_add pkgin'

echo 'http://ftp.netbsd.org/pub/pkgsrc/packages/NetBSD/$arch/$osrelease/All' > $MNT/usr/pkg/etc/pkgin/repositories.conf
#chroot $MNT sh -c '. /etc/profile; pkgin update'

# Disable root account
test -z "$debug" && chroot $MNT sh -c 'usermod -C yes root'
chmod +t ${MNT}/tmp
mkdir ${MNT}/kern
mkdir ${MNT}/proc

gpt biosboot -L root ${VND} 
installboot -v -o timeout=0 /dev/r${dk_dev} /usr/mdec/bootxx_ffsv2
