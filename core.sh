set -ue

xen_img=$1
kvm_img=$2
#echo $xen_img $kvm_img

xen_img_size_s=`parted "$xen_img" unit s print | grep Number -A1 | tail -n1 | awk '{print $4}' | sed 's/.$//'`
#echo Xen img size is "$xen_img_size_s"s.

#mount dir
mount_dir=/tmp/KVM
mkdir $mount_dir



################################
#                              #
#       create kvm.img         #
#                              #
################################
echo 'Create kvm img ...'

#kvm img partition size
cylinder_size_s=63
root_size_s=$xen_img_size_s
let "swap_size_s=2*1024*1024*2"

#create 1st cylinder space
count=$cylinder_size_s
err=$(dd if=/dev/zero of=$kvm_img count=$count 2>&1) || echo $err >&2

#dd xen_img to kvm img
seek=$cylinder_size_s
err=$(dd if=$xen_img of=$kvm_img seek=$seek 2>&1) || echo $err >&2

#create swap space
let "seek=$cylinder_size_s+xen_img_size_s"
count=$swap_size_s
err=$(dd if=/dev/zero of=$kvm_img seek=$seek count=$count 2>&1) || echo $err >&2

#mklabel msdos
parted $kvm_img mklabel msdos

#/  (root)
root_start=$cylinder_size_s
let "root_end=root_start+root_size_s-1"
parted $kvm_img unit s mkpart primary $root_start $root_end
parted $kvm_img set 1 boot on

#/swap
let "swap_start=root_end+1"
let "swap_end=swap_start+swap_size_s-1"
parted $kvm_img unit s mkpartfs primary linux-swap $swap_start $swap_end

#set uuid
root_uuid=`uuidgen`
swap_uuid=`uuidgen`
kpartx -a $kvm_img
root=/dev/mapper/`kpartx -l $kvm_img | head -1 | awk '{print $1}'`
swap=/dev/mapper/`kpartx -l $kvm_img | tail -1 | awk '{print $1}'`
tune2fs $root -U $root_uuid > /dev/null
err=$(mkswap -U $swap_uuid $swap 2>&1) || echo $err >&2
kpartx -d $kvm_img > /dev/null



################################
#                              #
#       install grub           #
#                              #
################################
echo 'Install grub on disk ...'

#loop
loop=`losetup -f`
losetup $loop $kvm_img
loop_primary_number=`ls -l $loop | cut -d, -f1 | awk '{print $5}'`
loop_secondary_number=`ls -l $loop | cut -d, -f2 | awk '{print $1}'`
#echo $loop    $loop_primary_number:$loop_secondary_number

#loop_p1
kpartx -a $loop
loop_p1=`kpartx -l $loop | head -1 | awk '{print "/dev/mapper/"$1}'`
loop_p1_primary_number=`ls -l $loop_p1 | cut -d, -f1 | awk '{print $5}'`
loop_p1_secondary_number=`ls -l $loop_p1 | cut -d, -f2 | awk '{print $1}'`
#echo $loop_p1    $loop_p1_primary_number:$loop_p1_secondary_number

#trick grub-install
disk=/dev/sdx
disk_p1=/dev/sdx1
mknod $disk b $loop_primary_number $loop_secondary_number
mknod $disk_p1 b $loop_p1_primary_number $loop_p1_secondary_number

#grub-install
mount $disk_p1 $mount_dir
grub-install --root-directory=$mount_dir $disk > /dev/null
umount $mount_dir

#clean
rm $disk $disk_p1
kpartx -d $loop
losetup -d $loop



################################
#                              #
#       config kvm img         #
#                              #
################################
echo 'Config kvm img ...'

#loop0
loop0=`losetup -f`
losetup $loop0 $kvm_img
kpartx -a $loop0
loop0_p1=`kpartx -l $loop0 | head -1 | awk '{print "/dev/mapper/"$1}'`

#loop1
loop1=`losetup -f`
losetup $loop1 $loop0_p1

#mount
mount $loop1 $mount_dir
mount -obind /dev $mount_dir/dev

#copy files
cp -f grub $mount_dir/etc/default/
cp -f ttyS0.conf $mount_dir/etc/init/
cp -f sources.list $mount_dir/etc/apt/
#cp -f fstab $mount_dir/etc/
sed -i '/^\/\|^UUID/d' $mount_dir/etc/fstab
echo "UUID=$root_uuid / `df -T $loop1 | tail -1 | awk '{print $2}'` defaults,errors=remount-ro 0 0" >> $mount_dir/etc/fstab
echo "UUID=$swap_uuid swap swap defaults 0 0" >> $mount_dir/etc/fstab
#cat $mount_dir/etc/fstab

#chroot apt-get install grub-pc
chroot $mount_dir apt-get update > /dev/null
err=$(chroot $mount_dir su - root -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y grub-pc" 2>&1) || echo $err >&2

#grub device.map
echo "(hd0) $loop1" > $mount_dir/boot/grub/device.map

#uuid
root_uuid_file=/dev/disk/by-uuid/$root_uuid
ln -s $loop1 $root_uuid_file

#grub-mkconfig
err=$(chroot $mount_dir grub-mkconfig -o /boot/grub/grub.cfg 2>&1) || echo $err >&2
#chroot $mount_dir cat /boot/grub/grub.cfg

#umount
umount $mount_dir/dev
umount $mount_dir

#clean
rm $root_uuid_file
losetup -d $loop1
kpartx -d $loop0
losetup -d $loop0

rmdir $mount_dir

#test
#rm -f $kvm_img

