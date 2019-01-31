#!/usr/bin/env bash

# Which addresses we should ping
# More target will better
targets=(
	8.8.8.8 # google-dns1
	8.8.4.4 # google-dns2
	77.88.8.8 # yandex-dns1
	77.88.8.1 # yandex-dns2
)

# ICMP options
icmp_count=5
icmp_size=1472
icmp_wait=0.5
icmp_interval=0.2

# How often we should switch routes?
# Default is - one switch per 10 minutes 
swap_period_min=10

# This files store a last switch time 
tmpfile='/tmp/statuses.isp'

# This is multipliers
# They are determine which link parameters will more urgent
# By default LOSS more urgent then RTT
# Please, no increase it more, than 1 
RTT_K=0.3
LOSS_K=0.5

# Thresholds for link parameters
# If one of this will great than threshold - test will marked as failed
# If summ of all failed test will be great than FAIL_PERCENT_THRESHOLD
# This ISP will be marked to lowest score
RTT_THRESHOLD=500
LOSS_THRESHOLD=10
FAIL_PERCENT_THRESHOLD=70

# If you will plan use a zabbix_sender utility
# You need to change this:
ZABBIX_SENDER='/usr/bin/zabbix_sender'
ZABBIX_SERVER='zabbix.example.com'
ZABBIX_HOST_NAME='hostname.example.com'
ZABBIX_KEY='current_isp'
# For TLS support - change to 1
ZABBIX_TLS=1
ZABBIX_TLS_IDENT="hostname"
ZABBIX_TLS_PSK_FILE="/etc/zabbix/agent.psk"

declare -A TABLE
declare -A DEVICE
declare -A IP
declare -A METRIC
declare -A SCORE
declare -A RESULT

# Please, do not change it
DEBUG=0
DRY_RUN=0
USE_ZABBIX=0

zabbix_send() {
	if [ $DEBUG == 1 ] ; then logging "Tries send new ISP to zabbix"; fi

	if [ $ZABBIX_TLS == 0 ] ; then 
		ZABBIX_OPTIONS="-z $ZABBIX_SERVER -I $1 -s $ZABBIX_HOST_NAME -k $ZABBIX_KEY -o $2"
	else
		ZABBIX_OPTIONS="-z $ZABBIX_SERVER -I $1 -s $ZABBIX_HOST_NAME -k $ZABBIX_KEY --tls-connect psk --tls-psk-identity $ZABBIX_TLS_IDENT --tls-psk-file $ZABBIX_TLS_PSK_FILE -o $2"
	fi

	if [ ! -f $ZABBIX_SENDER ] ; then
		if [ $DEBUG == 1 ] ; then logging "Cannot found zabbix-sender"; fi
		return 2
	else
		message=$($ZABBIX_SENDER $ZABBIX_OPTIONS 2>&1 >/dev/null)

		if [ $? == 0 ] ; then
			if [ $DEBUG == 1 ] ; then logging "Sent to zabbix $ZABBIX_SERVER was successfully!"; fi
		else
			if [ $DEBUG == 1 ] ; then logging "Sent to zabbix $ZABBIX_SERVER was failed. Error message: $message"; fi
		fi
	fi
}

mesg_usage() {
	echo ""
	echo "This script cheking your routing tables"
	echo "Get default routes and metrics from all routing tables"
	echo "Determine better route to Internet"
	echo "And change default to it"
	echo ""
	echo "Usage: $0 [-i] [-d] [-r] [-h] [-z]"
	echo "-i - Install script in cron"
	echo "-d - Run in debug mode"
	echo "-r - Run in dry-run mode (no route change - log only)"
	echo "-z - Use zabbix_sender to send results"
	echo "-h - This help"
	echo ""
	echo "By default this script running in silent mode"
	echo ""
}

install() {
	cp $0 /usr/local/bin/ispswitch.sh
	echo "Copy to /usr/local/bin/ispswitch.sh"
	echo "*/2 * * * *     root /usr/local/bin/ispswitch.sh -r" > /etc/cron.d/switch_isp
	systemctl restart crond
	echo "Installed into cron to /etc/cron.d/switch_isp"
	echo "Warning - it installed in silent and dry-run mode"
	echo "For enable logs and zabbix-sender - edit /etc/cron.d/switch_isp"
	echo ""
}

logging() {
	data=$(date "+%F %T")
	echo $data $1
}

while getopts "idrhz" opt; do
	case $opt in
		i) install; exit 0 ;;
		d) DEBUG=1 ;;
		r) DRY_RUN=1 ;;
		h) mesg_usage; exit 0 ;;
		z) USE_ZABBIX=1 ;;
	esac
done

if  [ $DRY_RUN == 1 ] ; then logging "==== DRY RUN! IT WILL NOT MAKE ANY CHANGES!! ===" ; fi

# gathering info
DEFAULT=$(/sbin/ip route list 0/0 | cut -d ' ' -f 3)
for i in $(/sbin/ip route list 0/0 table all | tr -s ' ' '#') ; do
	gw=$(echo $i|cut -d '#' -f 3)
	dev=$(echo $i|cut -d '#' -f 5)
	tab=$(echo $i|cut -d '#' -f 7)
	metric=$(echo $i|cut -d '#' -f 9)
	tab=${tab:-default}
	if ! [[ "$tab" == "default" && "$TABLE[${gw}]" != "" ]] ; then
		TABLE[${gw}]=$tab
		DEVICE[${gw}]=$dev
		IP[${gw}]=$(/sbin/ip address show ${dev} | grep -m 1 -o "inet [0-9.]*"|tr -d 'inet ')
		METRIC[${gw}]=${metric:-0}
		SCORE[${gw}]=$((100 * ${#targets[*]} - METRIC[${gw}]))
		if [ $DEBUG == 1 ] ; then logging "Table $tab found GW: $gw IP:${IP[${gw}]} metric: ${METRIC[${gw}]} "; fi
	fi
done

# Check - are we have only one ISP ?
if [ ${#TABLE[*]} -le 1 ]; then
	logging "You have only one ISP - what should I do?"
	exit 1
fi

# It's time to ICMP tests
for gw_ in "${!TABLE[@]}"; do 
	gw=$(echo $gw_)
	dev=${DEVICE[${gw_}]}
	tab=${TABLE[${gw_}]}
	ip=${IP[${gw_}]}
	tests_count=0
	tests_fail=0

	if [ $DEBUG == 1 ] ; then logging "---> Testing ISP $tab" ; fi

	# Do a ping!
	for target in ${targets[*]} ; do
		if  ( ping -c 1 -W 1 -I $ip -q $target > /dev/null 2>&1 ) ; then
			tests_count=$(($tests_count+1))
			result=$(ping -q -c ${icmp_count} -i ${icmp_interval} -s ${icmp_size} -w ${icmp_wait} -I ${ip} $target)
			loss=$(echo $result| grep -o '[0-9]*%' | tr -d '%')
			rtt=$(echo $result| grep -m 1 -o "[0-9.]*/[0-9.]*/[0-9.]*"|sed 's/\// /g'|cut -d ' ' -f 2|sed "s/\..*$//")

			if [ $DEBUG == 1 ] ; then logging "Check $target RTT: $rtt LOSS: $loss" ; fi

			if [ ${rtt} -lt 1 ] ; then rtt=0; fi
			# if rtt or loss > threshold - than - test was failed
			if [ ${rtt} -ge $RTT_THRESHOLD ] ; then tests_fail=$(($tests_fail+1)) ; continue ; fi
			if [ ${loss} -ge $LOSS_THRESHOLD ] ; then tests_fail=$(($tests_fail+1)) ; continue ; fi
			# get percent values
			rtt_p=$(echo -e "scale=1\n$RTT_K * (${rtt} / $RTT_THRESHOLD * 100)" | bc)
			loss_p=$(echo -e "scale=1\n$LOSS_K * (${loss} / $LOSS_THRESHOLD * 100)" | bc)

			# Count a score
			SCORE[${gw_}]=$(echo -e "scale=1\n${SCORE[${gw_}]}-$rtt_p-$loss_p" | bc)
			if [ $DEBUG == 1 ] ; then logging "Current score for $target is ${SCORE[${gw_}]}" ; fi
		else
			tests_fail=$(($tests_fail+1))
			if [ $DEBUG == 1 ] ; then logging "Check $target was failed" ; fi
		fi
		
	done

	# Count a percent of fails
	fail_percent=$(echo -e "scale=1\n$tests_fail / ${#targets[*]} * 100" | bc | cut -d '.' -f1)
	if [ $fail_percent -ge $FAIL_PERCENT_THRESHOLD ] ; then
		SCORE[${gw_}]=-99999
	else
		SCORE[${gw_}]=$(echo -e "scale=1\n${SCORE[${gw_}]}-$fail_percent" | bc | cut -d '.' -f1)
	fi

	# Write a resutl
	RESULT[${tab}]="FAILS: $tests_fail SCORE: ${SCORE[${gw_}]}"
	if [ $DEBUG == 1 ] ; then logging "<---- Summary: $tab ${RESULT[${tab}]}" ; fi
done

# analyze
switch_to=""
switch_message=""
def_tab=${TABLE[${DEFAULT}]}
def_score=${SCORE[${DEFAULT}]}
current_score=$def_score

if [ $DEBUG == 1 ] ; then logging "Default is $def_tab with SCORE $def_score" ; fi
for gw in "${!TABLE[@]}"; do
	dev=${DEVICE[${gw}]}
	tab=${TABLE[${gw}]}
	ip=${IP[${gw}]}
	if [ "$tab" != "$def_tab" ] ; then
		if [ $DEBUG == 1 ] ; then logging "==> Compare with $tab" ; fi
		score=${SCORE[${gw}]}
		if [ $DEBUG == 1 ] ; then logging "Test ISP $tab with SCORE $score" ; fi
		if [ $score -gt $current_score ] ; then
			switch_to=$gw
			switch_message="<== ISP $tab better. Reason = SCORE $score > previous ISP $current_score"
			current_score=$score
			if [ $DEBUG == 1 ] ; then logging "$switch_message" ; fi
		else
			if [ $DEBUG == 1 ] ; then logging "<== ISP $tab is not better than $def_tab. Reason = SCORE $score < previous ISP $current_score" ; fi
		fi
	fi
done

# Switch ISP!
isChanged=0
if [ "$switch_to" != "" ] ; then

	if [ $DEBUG == 1 ] ; then logging "Better ISP is ${switch_to}" ; fi

	# Determine switch time
	now=$(date +%s)
	if [ -f $tmpfile ] ; then
		last_swap=$(grep "LAST_SWAP" $tmpfile | cut -d ' ' -f 2 | tr -d ' ')
		next_swap=$(( $last_swap + $(( $swap_period_min * 60)) ))
	else
		next_swap=0
	fi

	if [ $now -gt $next_swap ] ; then
		if  [ $DRY_RUN == 0 ] ; then
			message=$(/sbin/ip route change default via $switch_to 2>&1 >/dev/null)
			if [ $? -ne 0 ] ; then
				if [ $DEBUG == 1 ] ; then  logging "Cannot change default gateway. Error: $message" ; fi
				exit 1
			fi
			if [ $DEBUG == 1 ] ; then logging "Swithed to $tab gateway $switch_to" ; fi
		else
			if [ $DEBUG == 1 ] ; then logging "Dry run: /sbin/ip route change default via $switch_to" ; fi
			logging "Dry run: Swithed to ${TABLE[${switch_to}]} gateway $switch_to"
		fi
		LAST_SWAP=$(date +%s)
		isChanged=1
		if [ $USE_ZABBIX == 1 ]; then zabbix_send ${IP[${switch_to}]} $switch_to ; fi
	else
		if [ $DEBUG == 1 ] ; then logging "Switch to $switch_to delayed to $(($next_swap - $now)) sec.!" ; fi
	fi
else
	if [ $DEBUG == 1 ] ; then logging "Better ISP still $def_tab - no need change anything" ; fi
	LAST_SWAP=0
fi

# Fill temp file
if [ $isChanged == 1 ]; then
	>$tmpfile
	# fill results
	for tab in "${!RESULT[@]}"; do 
		echo "$tab ${RESULT[${tab}]}" >> $tmpfile
	done
	echo "LAST_UPDATE $(date +%s)" >> $tmpfile
	if [ "$switch_to" != "" ] ; then echo "LAST_SWAP $LAST_SWAP" >> $tmpfile ; fi
fi

