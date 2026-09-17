#!/system/bin/sh
# emmc_verify.sh [size_mb=256] [loops=1]
# Write a pseudo-random file to /data, fsync, drop page cache, read it back and compare md5.
# Detects storage/memory-bus corruption during OC/UV soaks. Exit 0 = all loops matched.
SZ=${1:-256}; N=${2:-1}
F=/data/local/maic_oc/io_test.bin
mkdir -p /data/local/maic_oc
i=0; rc=0
while [ $i -lt $N ]; do
	# toolbox dd on this ROM rejects conv=fsync ("conv option disabled") and bs=1M; write with
	# a plain dd and fsync via sync instead.
	dd if=/dev/urandom of=$F bs=1048576 count=$SZ 2>/dev/null
	sync
	a=$(md5sum $F | cut -d' ' -f1)
	sync; echo 3 > /proc/sys/vm/drop_caches
	b=$(md5sum $F | cut -d' ' -f1)
	if [ "$a" = "$b" ] && [ -n "$a" ]; then echo "io loop $i OK $a"; else echo "io loop $i MISMATCH write=$a read=$b"; rc=2; break; fi
	i=$((i+1))
done
rm -f $F
exit $rc
