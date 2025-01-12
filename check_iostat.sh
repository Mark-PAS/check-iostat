#!/bin/bash
#----------check_iostat.sh-----------
#
# Version 0.0.2 - Jan/2009
# Changes: added device verification
#
# by Thiago Varela - thiago@iplenix.com
#
# Version 0.0.3 - Dec/2011
# Changes:
# - changed values from bytes to mbytes
# - fixed bug to get traffic data without comma but point
# - current values are displayed now, not average values (first run of iostat)
#
# by Philipp Niedziela - pn@pn-it.com
#
# Version 0.0.4 - April/2014
# Changes:
# - Allow Empty warn/crit levels
# - Can check I/O, WAIT Time, or Queue
#
# by Warren Turner
#
# Version 0.0.5 - Jun/2014
# Changes:
# - removed -y flag from call since iostat doesn't know about it any more (June 2014)
# - only needed executions of iostat are done now (save cpu time whenever you can)
# - fixed the obvious problems of missing input values (probably because of the now unimplemented "-y") with -x values
# - made perfomance data optional (I like to have choice in the matter)
#
# by Frederic Krueger / fkrueger-dev-checkiostat@holics.at
#
# Version 0.0.6 - Jul/2014
# Changes:
# - Cleaned up argument checking, removed excess iostat calls, steamlined if statements and renamed variables to fit current use
# - Fixed all inputs to match current iostat output (Ubuntu 12.04)
# - Changed to take last ten seconds as default (more useful for nagios usage). Will go to "since last reboot" (previous behaviour) on -g flag.
# - added extra comments/whitespace etc to make add readability
#
# by Ben Field / ben.field@concreteplatform.com
#
# Version 0.0.7 - Sep/2014
# Changes:
# - Fixed performance data for Wait check
#
# by Christian Westergard / christian.westergard@gmail.com
#
# Version 0.0.8 - Jan/2019
# Changes:
# - Added Warn/Crit thresholds to performance output
#
# by Danny van Zunderd / danny_vz@live.nl
#
# Version 0.0.9 - Jun/2020
# Changes:
# - Updated to use bash 4.4 mechanisms
#
# by Joseph Waggy / joseph.waggy@gmail.com
# Version 0.1.0 Sept 2021
# Changes:
# - correct misaligned fields
# - renaming / parser changes

iostat=$(which iostat 2>/dev/null)
bc=$(which bc 2>/dev/null)

help()
{
echo -e "
Usage:

-d =
--Device to be checked. Example: \"-d sda\"

Run only one of i, q, W:

-i = IO Check Mode
--Checks Total Transfers/sec, Read IO/Sec, Write IO/Sec, Bytes Read/Sec, Bytes Written/Sec
--warning/critical = Total Transfers/sec,Read IO/Sec,Write IO/Sec,Bytes Read/Sec,Bytes Written/Sec

-q = Queue Mode
--Checks Disk Queue Lengths
--warning/critial = Average size of requests, Queue length of requests

-W = Wait Time Mode
--Check the time for I/O requests issued to the device to be served. This includes the time spent by the requests in queue and the time spent servicing them.
--warning/critical = Avg I/O Wait Time (ms), Avg Read Wait Time (ms), Avg Write Wait Time (ms), Avg Service Wait Time (ms), Avg CPU Utilization

-w,-c = pass warning and critical levels respectively. These are not required, but with out them, all queries will return as OK.

-p = Provide performance data for later graphing

-g = Since last reboot for system (more for debugging that nagios use!)

-h = This help
"
}

# Ensuring we have the needed tools:
if [[ ! -f $iostat ]] || [[ ! -f $bc ]]; then
echo -e "ERROR: You must have iostat and bc installed in order to run this plugin\n\tuse: apt-get install systat bc\n"
exit -1
fi

io=0
queue=0
waittime=0
printperfdata=0
STATE="OK"
#samples=2i
samples=2
status=0

MSG=""
PERFDATA=""

#------------Argument Set-------------

while getopts "d:w:c:ipqWhg" OPT; do
case $OPT in
"d")
disk=$OPTARG
;;
"w")
warning=$OPTARG
;;
"c")
critical=$OPTARG
;;
"i")
io=1
;;
"p")
printperfdata=1
;;
"q")
queue=1
;;
"W")
waittime=1
;;
"g")
samples=1
;;
"h")
echo "help:"
help
exit 0
;;
\?)
echo "Invalid option: -$OPTARG" >&2
help
exit -1
;;
esac
done

# Autofill if parameters are empty
if [[ -z "$disk" ]]; then
disk=sda
fi

#Checks that only one query type is run
if [[ $((io+queue+waittime)) -ne "1" ]]; then
echo "ERROR: select one and only one run mode"
help
exit -1
fi

#set warning and critical to insane value is empty, else set the individual values
if [[ -z "$warning" ]]; then
warning=99999
else
#TPS with IO, Request size with queue
warn_1=$(echo $warning | cut -d, -f1)
#Read/s with IO,Queue Length with queue
warn_2=$(echo $warning | cut -d, -f2)
#Write/s with IO
warn_3=$(echo $warning | cut -d, -f3)
#KB/s read with IO
warn_4=$(echo $warning | cut -d, -f4)
#KB/s written with IO
warn_5=$(echo $warning | cut -d, -f5)
#Crude hack due to integer expression later in the script
warning=1
fi

if [[ -z "$critical" ]]; then
critical=99999
else
#TPS with IO, Request size with queue
crit_1=$(echo $critical | cut -d, -f1)
#Read/s with IO,Queue Length with queue
crit_2=$(echo $critical | cut -d, -f2)
#Write/s with IO
crit_3=$(echo $critical | cut -d, -f3)
#KB/s read with IO
crit_4=$(echo $critical | cut -d, -f4)
#KB/s written with IO
crit_5=$(echo $critical | cut -d, -f5)
#Crude hack due to integer expression later in the script
critical=1
fi

#------------Argument Set End-------------

#------------Parameter Check-------------

#Checks for sane Disk name:
if [[ ! -b "/dev/$disk" ]]; then
echo "ERROR: Device incorrectly specified"
help
exit -1
fi

#Checks for sane warning/critical levels
if [[ $warning -ne "99999" || $critical -ne "99999" ]]; then
if [[ "$warn_1" -gt "$crit_1" || "$warn_2" -gt "$crit_2" ]]; then
echo "ERROR: critical levels must be higher than warning levels"
help
exit -1
elif [[ $io -eq "1" || $waittime -eq "1" ]]; then
if [[ "$warn_3" -gt "$crit_3" || "$warn_4" -gt "$crit_4" || "$warn_5" -gt "$crit_5" ]]; then
echo "ERROR: critical levels must be higher than warning levels"
help
exit -1
fi
fi
fi

#------------Parameter Check End-------------

# iostat parameters:
# -m: megabytes
# -k: kilobytes
# first run of iostat shows statistics since last reboot, second one shows current vaules of hdd
# -d is the duration for second run, -x the rest

TMPX=$($iostat $disk -x -k -d 10 $samples | grep $disk | tail -1)

#------------IO Test-------------

if [[ "$io" == "1" ]]; then

TMPD=$($iostat $disk -k -d 10 $samples | grep $disk | tail -1)
#Requests per second:
tps=$(echo "$TMPD" | awk '{print $2}')
read_sec=$(echo "$TMPX" | awk '{print $2}')
written_sec=$(echo "$TMPX" | awk '{print $3}')

#Kb per second:
kbytes_read_sec=$(echo "$TMPX" | awk '{print $4}')
kbytes_written_sec=$(echo "$TMPX" | awk '{print $5}')

# "Converting" values to float (string replace , with .)
tps=${tps/,/.}
read_sec=${read_sec/,/.}
written_sec=${written_sec/,/.}
kbytes_read_sec=${kbytes_read_sec/,/.}
kbytes_written_sec=${kbytes_written_sec/,/.}

# Comparing the result and setting the correct level:
if [[ "$warning" -ne "99999" ]]; then
if [[ "$(echo "$tps >= $warn_1" | bc)" == "1" || "$(echo "$read_sec >= $warn_2" | bc)" == "1" || "$(echo "$written_sec >= $warn_3" | bc)" == "1" || "$(echo "$kbytes_read_sec >= $warn_4" | bc -q)" == "1" || "$(echo "$kbytes_written_sec >= $warn_5" | bc)" == "1" ]]; then
STATE="WARNING"
status=1
fi
fi
if [[ "$critical" -ne "99999" ]]; then
if [[ "$(echo "$tps >= $crit_1" | bc)" == "1" || "$(echo "$read_sec >= $crit_2" | bc -q)" == "1" || "$(echo "$written_sec >= $crit_3" | bc)" == "1" || "$(echo "$kbytes_read_sec >= $crit_4" | bc -q)" == "1" || "$(echo "$kbytes_written_sec >= $crit_5" | bc)" == "1" ]]; then
STATE="CRITICAL"
status=2
fi
fi
# Printing the results:
MSG="$STATE - I/O stats: Transfers/Sec=$tps Read Requests/Sec=$read_sec Write Requests/Sec=$written_sec KBytes Read/Sec=$kbytes_read_sec KBytes_Written/Sec=$kbytes_written_sec"
PERFDATA=" | total_io_sec=$tps;$warn_1;$crit_1; read_io_sec=$read_sec;$warn_2;$crit_2; write_io_sec=$written_sec;$warn_3;$crit_3; kbytes_read_sec=$kbytes_read_sec;$warn_4;$crit_4; kbytes_written_sec=$kbytes_written_sec;$warn_5;$crit_5;"
fi

#------------IO Test End-------------

#------------Queue Test-------------
if [[ "$queue" == "1" ]]; then
qsize=$(echo "$TMPX" | awk '{print $8}')
qlength=$(echo "$TMPX" | awk '{print $12}')
qread_size=$(echo "$TMPX" | awk '{print $13}')
qwrite_size=$(echo "$TMPX" | awk '{print $14}')

# "Converting" values to float (string replace , with .)
qlength=${qlength/,/.}
qread_size=${qread_size/,/.}
qwrite_size=${qwrite_size/,/.}

# Comparing the result and setting the correct level:
if [[ "$warning" -ne "99999" ]]; then
if [[ "$(echo "$qlength >= $warn_1" | bc)" == "1" || "$(echo "$qread_size >= $warn_2" | bc)" == "1" || "$(echo "$qwrite_size >= $warn_3" | bc)" == "1" ]]; then
STATE="WARNING"
status=1
fi
fi
if [[ "$critical" -ne "99999" ]]; then
if [[ "$(echo "$qlength >= $crit_1" | bc)" == "1" || "$(echo "$qread_size >= $crit_2" | bc)" == "1" || "$(echo "$qwrite_size >= $crit_3" | bc)" == "1" ]]; then
STATE="CRITICAL"
status=2
fi
fi

# Printing the results:
MSG="$STATE - Disk Queue Stats: Average Queue Length=$qlength, Average Read Size=$qread_size kilobytes, Average Write Size=$qwrite_size kilobytes"
PERFDATA=" | qlength=$qlength;$warn_1;$crit_1; qread_size=$qread_size;$warn_2;$crit_2; qwrite_size=$qwrite_size;$warn_3;$crit_3;"
fi

#------------Queue Test End-------------

#------------Wait Time Test-------------

#Parse values. Warning - svc time will soon be deprecated and these will need to be changed. Future parser could look at first line (labels) to suggest correct column to return
if [[ "$waittime" == "1" ]]; then
avgrwait=$(echo "$TMPX" | awk '{print $10}')
avgwwait=$(echo "$TMPX" | awk '{print $11}')
avgsvctime=$(echo "$TMPX" | awk '{print $15}')
avgcpuutil=$(echo "$TMPX" | awk '{print $16}')

# "Converting" values to float (string replace , with .)
avgrwait=${avgrwait/,/.}
avgwwait=${avgwwait/,/.}
avgsvctime=${avgsvctime/,/.}
avgcpuutil=${avgcpuutil/,/.}

# Comparing the result and setting the correct level:
if [[ "$warning" -ne "99999" ]]; then
if [[ "$(echo "$avgrwait >= $warn_1" | bc -q)" == "1" || "$(echo "$avgwwait >= $warn_2" | bc)" == "1" || "$(echo "$avgsvctime >= $warn_3" | bc -q)" == "1" || "$(echo "$avgcpuutil >= $warn_4" | bc)" == "1" ]]; then
STATE="WARNING"
status=1
fi
fi
if [[ "$critical" -ne "99999" ]]; then
if [[ "$(echo "$avgrwait >= $crit_1" | bc -q)" == "1" || "$(echo "$avgwwait >= $crit_2" | bc)" == "1" || "$(echo "$avgsvctime >= $crit_3" | bc -q)" == "1" || "$(echo "$avgcpuutil >= $crit_4" | bc)" == "1" ]]; then
STATE="CRITICAL"
status=2
fi
fi

# Printing the results:
MSG="$STATE - Avg Read Wait Time (ms)=$avgrwait Avg Write Wait Time (ms)=$avgwwait Avg Service Wait Time (ms)=$avgsvctime Avg CPU Utilization=$avgcpuutil"
PERFDATA=" | avg_r_waittime_ms=$avgrwait;$warn_1;$crit_1; avg_w_waittime_ms=$avgwwait;$warn_2;$crit_2; avg_service_waittime_ms=$avgsvctime;$warn_3;$crit_3; avg_cpu_utilization=$avgcpuutil;$warn_4;$crit_4;"
fi

#------------Wait Time End-------------

# now output the official result
echo -n "$MSG"
if [[ "x$printperfdata" == "x1" ]]; then
echo -n "$PERFDATA"
fi
echo ""
exit $status
