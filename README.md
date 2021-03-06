# XEN To KVM 
一般来说XEN的镜像是单独扣出来的各个分区镜像（至少一个/），而KVM的镜像是整块硬盘的镜像（包括/，swap...）

## 完整硬盘镜像
我们以简单的单个/分区的XEN镜像转换为完整的硬盘镜像为例子
* 第一扇区（secotr，512B）的MBR。放置主引导代码和主分区信息
* 第一柱面（cylinder）除去MBR所占用的空间（一般大小为512B*62），这段空间一般是引导程序放置的地方（比如GRUB）
* 第一个主分区根分区（/），这个完全是XEN镜像的克隆版本
* 第二个主分区swap分区（swap），非必须
很显然除了第3个根分区是完全克隆XEN镜像，其他的三个都需要我们创造出来

### 创建硬盘镜像
注：xxx_size_s表示扇区数，每个扇区大小512B

#### 第一柱面空间
```bash
#create 1st cylinder space
count=$cylinder_size_s
err=$(dd if=/dev/zero of=$kvm_img count=$count 2>&1) || echo $err >&2
```

#### 根分区空间（XEN镜像克隆）
```bash
#dd xen_img to kvm img
seek=$cylinder_size_s
err=$(dd if=$xen_img of=$kvm_img seek=$seek 2>&1) || echo $err >&2
```

#### swap分区空间
```bash
#create swap space
let "seek=$cylinder_size_s+xen_img_size_s"
count=$swap_size_s
err=$(dd if=/dev/zero of=$kvm_img seek=$seek count=$count 2>&1) || echo $err >&2
```

#### 设置硬盘分区格式
```bash
#mklabel msdos
parted $kvm_img mklabel msdos
```

#### 创建根分区表信息
```bash
#/  (root)
root_start=$cylinder_size_s
let "root_end=root_start+root_size_s-1"
parted $kvm_img unit s mkpart primary $root_start $root_end
parted $kvm_img set 1 boot on
```

#### 创建swap分区表信息，并格式化
```bash
#/swap
let "swap_start=root_end+1"
let "swap_end=swap_start+swap_size_s-1"
parted $kvm_img unit s mkpartfs primary linux-swap $swap_start $swap_end
```

#### 设置UUID
因为现在我们是挂载在/dev/sdx上的，第一分区就是/dev/sdx1。但是正式的系统启动时候使用的不是这个，可能是sda/sda1 ,或者vda/vda1什么的。这里我们设置UUID，一会GRUB配置的时候就可以把这个UUID传给启动的内核，代替root=/dev/sda1什 么的。还有/etc/fstab里面挂载配置也用UUID。这样当硬盘的设备属性变更时，系统依然能准确的找到所需要的分区。
```bash
#set uuid
root_uuid=`uuidgen`
swap_uuid=`uuidgen`
kpartx -a $kvm_img
root=/dev/mapper/`kpartx -l $kvm_img | head -1 | awk '{print $1}'`
swap=/dev/mapper/`kpartx -l $kvm_img | tail -1 | awk '{print $1}'`
tune2fs $root -U $root_uuid > /dev/null
err=$(mkswap -U $swap_uuid $swap 2>&1) || echo $err >&2
kpartx -d $kvm_img > /dev/null
```

### 安装GRUB

#### 设置设备
在一个disk img上面安装grub并不容易，因为grub安装程序默认只支持在/dev/sd*，/dev/hd*，/dev/fd*。这些设备上面安装。所以首先要进行一些欺骗的操作。
挂载成loop设备也可以安装上grub2，但一直不能启动，原因未知
```bash
#loop
loop=`losetup -f`
losetup $loop $kvm_img
loop_primary_number=`ls -l $loop | cut -d, -f1 | awk '{print $5}'`
loop_secondary_number=`ls -l $loop | cut -d, -f2 | awk '{print $1}'`
#echo $loop     $loop_primary_number:$loop_secondary_number
```

```bash
#loop_p1
kpartx -a $loop
loop_p1=`kpartx -l $loop | head -1 | awk '{print "/dev/mapper/"$1}'`
loop_p1_primary_number=`ls -l $loop_p1 | cut -d, -f1 | awk '{print $5}'`
loop_p1_secondary_number=`ls -l $loop_p1 | cut -d, -f2 | awk '{print $1}'`
#echo $loop_p1  $loop_p1_primary_number:$loop_p1_secondary_number
```
```bash
#trick grub-install
disk=/dev/sdx
disk_p1=/dev/sdx1
mknod $disk b $loop_primary_number $loop_secondary_number
mknod $disk_p1 b $loop_p1_primary_number $loop_p1_secondary_number
```

#### grub-install
```bash
#grub-install
mount $disk_p1 $mount_dir
grub-install --root-directory=$mount_dir $disk > /dev/null
umount $mount_dir
```

### 配置镜像

#### grub配置文件
```bash
cp -f grub $mount_dir/etc/default/
```

#### ttyS0，串口配置文件
```bash
cp -f ttyS0.conf $mount_dir/etc/init/
```

#### 软件源
```bash
cp -f sources.list $mount_dir/etc/apt/
/etc/fstab
sed -i '/^\/\|^UUID/d' $mount_dir/etc/fstab
echo "UUID=$root_uuid / `df -T $loop1 | tail -1 | awk '{print $2}'` defaults,errors=remount-ro 0 0" >> $mount_dir/etc/fstab
echo "UUID=$swap_uuid swap swap defaults 0 0" >> $mount_dir/etc/fstab
#cat $mount_dir/etc/fstab
```

#### 挂载/dev，chroot配置需要
```bash
mount -obind /dev $mount_dir/dev
```

#### 编辑device.map
这个文件决定了grub设备命名和操作系统设备命令的关系。这个文件在系统启动时候并没有任何作用。而是grub-mkconfig的时候会替换配 置文件中的root的表示。如果没有这个device.map映射表，很可能生成配置文件是root /dev/loop0。这样系统启动时候，grub根本早不到这个这个root设备，肯定也就找不到内核文件了。
```bash
#grub device.map
echo "(hd0) $loop1" > $mount_dir/boot/grub/device.map
```

#### 创建uuid file
grub-mkconfig的时候，会扫描/dev/disk/by-uuid/下面的文件，如果找不到启动设备的uuid软链接文件，就不会使用UUID～～（这个文件一般在系统启动的时候自动生成，现在我们chroot，肯定就没有了）
```bash
#uuid
root_uuid_file=/dev/disk/by-uuid/$root_uuid
ln -s $loop1 $root_uuid_file
```

#### 安装grub-pc
下面代码里面的export DEBIAN_FRONTEND=noninteractive;阻止软件交互配置的，我的全自动bash脚本肯定不能人工交互操作的
```bash
#chroot apt-get install grub-pc
chroot $mount_dir apt-get update > /dev/null
err=$(chroot $mount_dir su - root -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y grub-pc" 2>&1) || echo $err >&2
```

#### 生成grub配置文件
```bash
#grub-mkconfig
err=$(chroot $mount_dir grub-mkconfig -o /boot/grub/grub.cfg 2>&1) || echo $err >&2
```
