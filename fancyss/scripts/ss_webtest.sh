#!/bin/sh

# fancyss script for asuswrt/merlin based router with software center

source /koolshare/scripts/ss_base.sh
LOGTIME1=⌚$(TZ=UTC-8 date -R "+%H:%M:%S")
TMP2=/tmp/fancyss_webtest

run(){
	env -i PATH=${PATH} "$@"
}

# ----------------------------------------------------------------------
# webtest
# 0: ss: ss, ss + simpple obfs, ss + v2ray plugin
# 1: ssr
# 3: v2ray
# 4: xray
# 5: trojan
# 6: naive

# 1. 先分类，ss分4类（ss, ss+simple, ss+v2ray, ss2022），ssr一类，v2ray + xray + trojan一类，naive一类，总共7类
# 2. 按照类别分别进行测试，而不是按照节点顺序测试，这样可以避免v2ray，xray等线程过多导致路由器资源耗尽，每个类的线程数不一样
# 3. 每个类别的测试，不同机型给到不同的线程数量，比如RT-AX56U_V2这种小内存机器，给一个线程即可
# 4. ss测试需要判断加密方式是否为2022AEAD，如果是，则需要判断是否存在sslocal，（不存在则返回不支持）
# 4. ss测试需要判断是否启用了插件，如果是v2ray-plugin插件，则测试线程应该降低，fancyss_lite不测试（返回不支持）
# 5. v2ray的配置文件（一般为vmess）由xray进行测试，因为fancyss_lite不带v2ray二进制
# 6. 二进制启动目标为开socks5端口，然后用curl通过该端口进行落地延迟测试
# 7. ss ssr这类以开多个二进制来增加线程，xray测试则使用一个线程 + 开多个socks5端口的配置文件来进行测试
# 8. 运行测试的时候，需要将各个二进制改名后运行，以免ssconfig.sh的启停将某个测试进程杀掉

webtest_web(){
	# 1. 如果没有结果文件，需要去获取webtest
	if [ ! -f "/tmp/upload/webtest.txt" ];then
		clean_webtest
		start_webtest
		return 0
	fi

	# 2. 如果有结果文件，且lock 存在，说明正在webtest，那么告诉web自己去拿结果吧
	if [ -f "/tmp/webtest.lock" ];then
		http_response "ok1, lock exist, webtest is running..."
		return 0
	fi

	# 3. 如果有结果该文件，且没有lock（webtest完成了的），需要检测下节点数量和webtest数量是否一致，避免新增节点没有webtest
	local webtest_nu=$(cat /tmp/upload/webtest.txt | awk -F ">" '{print $1}' | sort -un | sed '/stop/d' | wc -l)
	local node_nu=$(dbus list ssconf_basic_ | grep _name_ | wc -l)
	if [ "${webtest_nu}" -ne "${node_nu}" ];then
		clean_webtest
		start_webtest
		return 0
	fi

	# 4. 如果有结果该文件，且没有lock（webtest完成了的），且节点数和webtest结果数一致，比较下上次webtest结果生成的时间，如果是15分钟以内，则不需要重新webtest
	TS_LST=$(/bin/date -r /tmp/upload/webtest.txt "+%s")
	TS_NOW=$(/bin/date +%s)
	TS_DUR=$((${TS_NOW} - ${TS_LST}))
	if [ "${TS_DUR}" -lt "1800" ];then
		http_response "ok2, webtest result in 30min, do not refresh!"
	else
		clean_webtest
		start_webtest
	fi
}

start_webtest(){
	# create lock
	touch /tmp/webtest.lock
	
	# 1. prepare
	mkdir -p ${TMP2}
	rm -rf ${TMP2}/*
	mkdir -p ${TMP2}/conf
	mkdir -p ${TMP2}/pids
	mkdir -p ${TMP2}/results
	ln -sf /koolshare/bin/curl-fancyss ${TMP2}/curl-webtest

	# 2. 分类
	sort_nodes

	# 3. 测试
	test_nodes

	# 4. remove lock
	rm -rf /tmp/webtest.lock
}

sort_nodes(){
	# 1.给所有节点分类
	# 00_01 ss 
	# 00_02 ss + obfs
	# 00_03 ss + v2ray					# deprecated since 3.3.6
	# 00_04 ss2022
	# 00_05 ss2022 + obfs
	# 00_06 ss2022 + v2ray				# deprecated since 3.3.6
	# 01 ssr
	# 02 koolgame (deleted in 3.0.4)
	# 03 v2ray
	# 04 xray
	# 05 trojan
	# 06 naive
	# 07 tuic
	# 08 hysteria2

	# sort by type first
	local count=1
	dbus list ssconf_basic_type_|sort -t "_" -nk4|sed 's/^ssconf_basic_type_//'|awk -F"=" '{printf $1 " "; printf "%02d\n", $2}' >${TMP2}/nodes_index.txt
	cat ${TMP2}/nodes_index.txt|awk '{print $2}'|uniq -c|sed 's/^[[:space:]]\+//g' | while read gp
	do
		local _type=$(echo "$gp" | awk '{print $2}')
		local _line=$(echo "$gp" | awk '{print $1}')
		sed -n "1,${_line}p" ${TMP2}/nodes_index.txt | awk '{print $1}' >>${TMP2}/wt_${count}_${_type}.txt
		sed -i "1,${_line}d" ${TMP2}/nodes_index.txt
		let count++
	done

	# then sort shadowsocks
	local wt_flies=$(find ${TMP2}/wt_*.txt|sort -t "/" -nk5)
	for file in ${wt_flies}
	do
		local file_name=${file##*/}
		local node_type=${file_name##*_}
		local node_type=${node_type%%.*}
		local pref_name=${file_name%_*}
		if [ ${node_type} == "00" ];then
			# echo $file
			# echo $file_name
			# echo $node_type
			# echo $pref_name
			cat $file | while read ss_nu
			do
				# echo $ss_nu
				local _obfs=$(dbus get ssconf_basic_ss_obfs_${ss_nu})
				local _method=$(dbus get ssconf_basic_method_${ss_nu})
				local ss_2022=$(echo ${_method} | grep "2022-blake")
				if [ -z "${_obfs}" -o "${_obfs}" == "0" ];then
					local _obfs_enable="0"
				else
					local _obfs_enable="1"
				fi
				if [ -z "${ss_2022}" ];then
					if [ "${_obfs_enable}" == "0" ];then
						echo ${ss_nu} >>${TMP2}/${pref_name}_00_01.txt
					elif [ "${_obfs_enable}" == "1" ];then
						echo ${ss_nu} >>${TMP2}/${pref_name}_00_02.txt
					fi
				else
					if [ "${_obfs_enable}" == "0" ];then
						echo ${ss_nu} >>${TMP2}/${pref_name}_00_04.txt
					elif [ "${_obfs_enable}" == "1" ];then
						echo ${ss_nu} >>${TMP2}/${pref_name}_00_05.txt
					fi
				fi
			done
			rm -rf $file
		fi
	done
}

test_nodes(){
	# define
	LINUX_VER=$(uname -r|awk -F"." '{print $1$2}')

	# 优先测试当前节点及其附近的同类型节点，重排生成节点序号储存文件
	local CURR_NODE=$(dbus get ssconf_basic_node)
	[ -z "${CURR_NODE}" ] && CURR_NODE=1
	MAX_SHOW=$(dbus get ss_basic_row)
	if [ "${MAX_SHOW}" -gt "1" ];then 
		BEGN_NODE=$(awk -v x=${CURR_NODE} -v y=${MAX_SHOW} 'BEGIN { printf "%.0f\n", (x-y/2)}')
	else
		BEGN_NODE=$((${CURR_NODE} - 10))
	fi

	local CURR_FILE=$(find ${TMP2}/ -name "wt_*.txt" | xargs grep -Ew "^${CURR_NODE}" | awk -F ":" '{print $1}')
	if [ -f "${CURR_FILE}" ];then
		local FIRST_BGN=$(cat ${CURR_FILE}|head -n1)
		if [ -f "${CURR_FILE}" -a "${BEGN_NODE}" -gt "${FIRST_BGN}" ];then
			sed -n "/${BEGN_NODE}/,\$p" ${CURR_FILE} > ${TMP2}/re-arrange-1.txt 
			sed -n "1,/^${BEGN_NODE}\$/p" ${CURR_FILE} | sed '$d' > ${TMP2}/re-arrange-2.txt
			cat ${TMP2}/re-arrange-1.txt ${TMP2}/re-arrange-2.txt > ${CURR_FILE}
			rm -rf ${TMP2}/re-arrange-1.txt ${TMP2}/re-arrange-2.txt
		fi
	fi

	# tell web, you can start to get result now...
	true >/tmp/upload/webtest.txt
	http_response "ok4, webtest.txt generating..."

	# 优先测试当前节点所属的节点类型
	find ${TMP2}/wt_*.txt|sort -t"/" -n > ${TMP2}/nodes_file_name.txt
	local CURR_FILE=$(find ${TMP2} -name "wt_*.txt" | xargs grep -Ew "^${CURR_NODE}" | awk -F ":" '{print $1}')
	local CURR_FILE=${CURR_FILE##*/}
	local CURR_FILE=${CURR_FILE%%.*}
	local TOTA_LINE=$(cat ${TMP2}/nodes_file_name.txt | wc -l)
	local CURR_LINE=$(sed -n "/${CURR_FILE}/=" ${TMP2}/nodes_file_name.txt)
	if [ "${CURR_LINE}" -gt "1" ];then
		sed -n "${CURR_LINE},\$p" ${TMP2}/nodes_file_name.txt > ${TMP2}/nodes_file_name-1.txt
		sed -n "1,${CURR_LINE}p" ${TMP2}/nodes_file_name.txt | sed '$d' > ${TMP2}/nodes_file_name-2.txt
		cat ${TMP2}/nodes_file_name-1.txt ${TMP2}/nodes_file_name-2.txt > ${TMP2}/nodes_file_name.txt
		rm -f ${TMP2}/nodes_file_name-1.txt ${TMP2}/nodes_file_name-2.txt	
	fi
	
	#echo CURR_LINE $CURR_LINE
	#echo CURR_FILE $CURR_FILE
	#echo BEGN_NODE $BEGN_NODE
	base_port=$(gen_base_port ${count})
	
	cat ${TMP2}/nodes_file_name.txt | while read test_file
	do
		local file_name=${test_file##*/}
		local node_type=${file_name#wt_*_}
		local node_type=${node_type%%.*}
		local pref_name=${file_name%_*}

		#echo -----------------
		#echo test_file $test_file
		#echo file_name $file_name
		#echo node_type $node_type
		#echo pref_name $pref_name
		#echo -----------------
		# 00_01 ss
		# 00_02 ss + obfs
		# 00_03 ss + v2ray					# deprecated since 3.3.6
		# 00_04 ss2022
		# 00_05 ss2022 + obfs
		# 00_06 ss2022 + v2ray				# deprecated since 3.3.6
		# 01 ssr
		# 02 koolgame (deleted in 3.0.4)
		# 03 v2ray
		# 04 xray
		# 05 trojan
		# 06 naive
		# 07 tuic
		# 08 hysteria2

		case $node_type in
		00_01)
			test_01_ss_fake_multi $file_name $node_type
			;;
		00_02)
			test_01_ss_fake_multi $file_name $node_type
			;;
		00_04)
			test_01_ss_fake_multi $file_name $node_type
			;;
		00_05)
			test_01_ss_fake_multi $file_name $node_type
			;;
		01)
			test_07_sr $file_name $node_type
			;;
		03)
			test_08_vr $file_name $node_type
			;;
		04)
			test_09_xr $file_name $node_type
			;;
		05)
			test_10_tj $file_name $node_type
			;;
		06)
			test_11_nv $file_name $node_type
			;;
		07)
			test_12_tc $file_name $node_type
			;;
		08)
			test_13_h2 $file_name $node_type
			;;
		esac
	done
	
	# finish mark
	find ${TMP2}/results/ -name "*.txt" | sort -t "/" -nk5 | xargs cat > /tmp/upload/webtest.txt
	echo -en "stop>stop\n" >>/tmp/upload/webtest.txt

	# record timestamp
	local TS_LOG=$(date -r /tmp/upload/webtest.txt "+%Y/%m/%d %X")
	dbus set ss_basic_webtest_ts="${TS_LOG}"

	# copy webtest.txt for other useage
	cp -rf /tmp/upload/webtest.txt /tmp/upload/webtest_bakcup.txt

	# we shold remove test tmp file
	
}

test_01_ss_new(){
	# test ss nodes by ss-libev
	local file=$1

	# multi thread
	[ -e /tmp/fd1 ] || mknod /tmp/fd1 p
	exec 3<>/tmp/fd1
	rm -rf /tmp/fd1

	awk 'BEGIN { for (i=1; i<=8; i++) printf("%d\n", i) }' | while read seq
	do
		echo
	done >&3

	# alisa binary
	ln -sf /koolshare/bin/ss-local ${TMP2}/wt-ss-local
	killall wt-ss-local >/dev/null 2>&1

	# get extra option for shadowsocks-libev
	local ARG_1 ARG_2
	if [ "$(dbus get ss_basic_tfo)" == "1" -a "${LINUX_VER}" != "26" ]; then
		local ARG_1="--fast-open"
		echo 3 >/proc/sys/net/ipv4/tcp_fastopen
	fi
	if [ "$(dbus get ss_basic_tnd)" == "1" ]; then
		local ARG_2="--no-delay"
	fi

	# start to test
	cat ${TMP2}/${file} | while read nu; do
		read -u3
		{
			# 0. write testing info
			echo -en "${nu}>testing...\n" >>${TMP2}/results/${nu}.txt
			cat ${TMP2}/results/*.txt > /tmp/upload/webtest.txt
			
			# 1. resolve server
			local _server_ip=$(_get_server_ip $(dbus get ssconf_basic_server_${nu}))
			if [ -z "${_server_ip}" ];then
				echo -en "${nu}:\t解析失败！\n"
				continue
			fi
			
			# 2. start ss-local
			local socks5_port=$(get_rand_port)
			run_bg ${TMP2}/wt-ss-local -s ${_server_ip} -p $(dbus get ssconf_basic_port_${nu}) -b 0.0.0.0 -l ${socks5_port} -k $(dbus get ssconf_basic_password_${nu} | base64_decode) -m $(dbus get ssconf_basic_method_${nu}) ${ARG_1} ${ARG_2}
			sleep 1
			wait_program wt-ss-local
			
			# 3. start curl test
			curl_test ${nu} ${socks5_port}

			# 4. write tested info
			cat ${TMP2}/results/*.txt > /tmp/upload/webtest.txt
			
			# 5. stop ss-local
			local _pid=$(ps -w | grep "wt-ss-local" | grep -w "${_server_ip}" | grep -w "$(dbus get ssconf_basic_port_${nu})" | grep -w "${socks5_port}" | awk '{print $1}' | head -n1)
			if [ -n "${_pid}" ];then
				kill -9 ${_pid} >/dev/null 2>&1
			fi
			
			echo >&3
		} &
	done
	wait
	
	exec 3<&-
	exec 3>&-
	
	rm -rf ${TMP2}/pids/*
	rm -rf ${TMP2}/wt-ss-local
}

test_01_ss_old(){
	# test ss nodes by ss-libev
	local file=$1
	local mark=$2

	# alisa binary
	ln -sf /koolshare/bin/ss-local ${TMP2}/wt-ss-local
	killall wt-ss-local >/dev/null 2>&1

	# get extra option for shadowsocks-libev
	local ARG_1 ARG_2
	if [ "$(dbus get ss_basic_tfo)" == "1" -a "${LINUX_VER}" != "26" ]; then
		local ARG_1="--fast-open"
		echo 3 >/proc/sys/net/ipv4/tcp_fastopen
	fi
	if [ "$(dbus get ss_basic_tnd)" == "1" ]; then
		local ARG_2="--no-delay"
	fi

	# start to test
	cat ${TMP2}/${file} | xargs -n 8 | while read nus; do
		for nu in $nus; do
			{
				# 0. testing info
				echo -en "${nu}>testing...\n" >>/tmp/upload/webtest.txt
				
				# 1. resolve server
				local _server_ip=$(_get_server_ip $(dbus get ssconf_basic_server_${nu}))
				if [ -z "${_server_ip}" ];then
					echo -en "${nu}:\t解析失败！\n"
					continue
				fi
				
				# 2. start ss-local
				local socks5_port=$(get_rand_port)
				run_bg ${TMP2}/wt-ss-local -s ${_server_ip} -p $(dbus get ssconf_basic_port_${nu}) -b 0.0.0.0 -l ${socks5_port} -k $(dbus get ssconf_basic_password_${nu} | base64_decode) -m $(dbus get ssconf_basic_method_${nu}) ${ARG_1} ${ARG_2}

				sleep 1
				wait_program wt-ss-local

				# 3. start curl test
				curl_test ${nu} ${socks5_port}
				
				# 4. stop ss-local
				local _pid=$(ps -w | grep "wt-ss-local" | grep -w "${_server_ip}" | grep -w "$(dbus get ssconf_basic_port_${nu})" | grep -w "${socks5_port}" | awk '{print $1}' | head -n1)
				if [ -n "${_pid}" ];then
					kill -9 ${_pid} >/dev/null 2>&1
				fi
			} &
		done
		wait
		
		# merge all curl test result
		find ${TMP2}/results/ -name "*.txt" | sort -t "/" -nk5 | xargs cat > /tmp/upload/webtest.txt
	done
	
	rm -rf ${TMP2}/pids/*
	rm -rf ${TMP2}/wt-ss-local
}

test_01_ss_fake_multi(){
	# test ss nodes by xray fake multi thread
	local file=$1
	local mark=$2
	local count=$(cat ${TMP2}/$file | wc -l)
	
	# show info to web as soon as possible
	cat ${TMP2}/${file} | xargs -n 8 | head -n1 | while read nus; do
		for nu in $nus; do
			echo -en "${nu}>testing...\n" >>/tmp/upload/webtest.txt
		done
	done
	
	# prepare
	killall wt-ss >/dev/null 2>&1
	killall wt-obfs >/dev/null 2>&1
	ln -sf /koolshare/bin/xray ${TMP2}/wt-ss
	ln -sf /koolshare/bin/obfs-local ${TMP2}/wt-obfs
	mkdir -p ${TMP2}/conf_${mark}
	mkdir -p ${TMP2}/json_${mark}
	mkdir -p ${TMP2}/bash_${mark}
	mkdir -p ${TMP2}/logs_${mark}
	rm -rf ${TMP2}/conf_${mark}/*
	rm -rf ${TMP2}/json_${mark}/*
	rm -rf ${TMP2}/bash_${mark}/*
	rm -rf ${TMP2}/logs_${mark}/*

	# gen all xray conf at once
	cat ${TMP2}/${file} | xargs -n 16 | while read nus; do
		for nu in $nus; do
			{
				creat_xray_ss_json ${nu} ${mark}
			} &
		done
		wait
	done

	# merge all xray json
	find ${TMP2}/conf_${mark} -name "*_inbounds.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{ inbounds: [ inputs.inbounds[0] ] }' >${TMP2}/json_${mark}/00_inbounds.json
	find ${TMP2}/conf_${mark} -name "*_outbounds.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{ outbounds: [ inputs.outbounds[0] ] }' >${TMP2}/json_${mark}/01_outbounds.json
	find ${TMP2}/conf_${mark} -name "*_routing.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{routing: { rules: [ inputs.routing.rules[0] ] }}' >${TMP2}/json_${mark}/02_routing.json

	# now we can start xray to host multiple outbounds
	run ${TMP2}/wt-ss run -confdir ${TMP2}/json_${mark}/ >${TMP2}/logs_${mark}/log.txt 2>&1 &

	# make sure xray is runing, otherwise output error
	# sleep 3
	wait_program2 wt-ss ${TMP2}/logs_${mark}/log.txt started

	if [ -f "${TMP2}/socsk5_ports.txt" ];then
		eval $(cat ${TMP2}/socsk5_ports.txt)
	fi

	# test in multiple process
	cat ${TMP2}/${file} | xargs -n 8 | while read nus; do
		for nu in $nus; do
			{
				# 0. testing info
				echo -en "${nu}>testing...\n" >>/tmp/upload/webtest.txt

				# 1. start obfs-local
				if [ -x "${TMP2}/bash_${mark}/start_${nu}.sh" ];then
					sh ${TMP2}/bash_${mark}/start_${nu}.sh
				fi
				
				# 2. start curl test
				local socks5_port=$(eval echo \$socks5_port_${nu})
				curl_test ${nu} ${socks5_port}
				
				# 3. stop obfs-local
				if [ -x "${TMP2}/bash_${mark}/stop_${nu}.sh" ];then
					sh ${TMP2}/bash_${mark}/stop_${nu}.sh
				fi
			} &
		done
		wait
		# merge all curl test result
		find ${TMP2}/results/ -name "*.txt" | sort -t "/" -nk5 | xargs cat > /tmp/upload/webtest.txt
	done

	# finished kill xray
	killall wt-ss >/dev/null 2>&1

	# finished
	rm -rf ${TMP2}/wt-ss
	rm -rf ${TMP2}/wt-obfs
}


test_01_ss_real_multi(){
	# test ss nodes by xray real multi thread
	local file=$1
	local mark=$2
	local count=$(cat ${TMP2}/$file | wc -l)
	
	# show info to web as soon as possible
	cat ${TMP2}/${file} | xargs -n 8 | head -n1 | while read nus; do
		for nu in $nus; do
			echo -en "${nu}>testing...\n" >>/tmp/upload/webtest.txt
		done
	done
	
	# prepare
	killall wt-ss >/dev/null 2>&1
	killall wt-obfs >/dev/null 2>&1
	ln -sf /koolshare/bin/xray ${TMP2}/wt-ss
	ln -sf /koolshare/bin/obfs-local ${TMP2}/wt-obfs
	mkdir -p ${TMP2}/conf_${mark}
	mkdir -p ${TMP2}/json_${mark}
	mkdir -p ${TMP2}/bash_${mark}
	mkdir -p ${TMP2}/logs_${mark}
	rm -rf ${TMP2}/conf_${mark}/*
	rm -rf ${TMP2}/json_${mark}/*
	rm -rf ${TMP2}/bash_${mark}/*
	rm -rf ${TMP2}/logs_${mark}/*

	# gen all xray conf at once
	cat ${TMP2}/${file} | xargs -n 16 | while read nus; do
		for nu in $nus; do
			{
				creat_xray_ss_json ${nu} ${mark}
			} &
		done
		wait
	done

	# merge all xray json
	find ${TMP2}/conf_${mark} -name "*_inbounds.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{ inbounds: [ inputs.inbounds[0] ] }' >${TMP2}/json_${mark}/00_inbounds.json
	find ${TMP2}/conf_${mark} -name "*_outbounds.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{ outbounds: [ inputs.outbounds[0] ] }' >${TMP2}/json_${mark}/01_outbounds.json
	find ${TMP2}/conf_${mark} -name "*_routing.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{routing: { rules: [ inputs.routing.rules[0] ] }}' >${TMP2}/json_${mark}/02_routing.json

	# now we can start xray to host multiple outbounds
	run ${TMP2}/wt-ss run -confdir ${TMP2}/json_${mark}/ >${TMP2}/logs_${mark}/log.txt 2>&1 &

	# make sure xray is runing, otherwise output error
	# sleep 3
	wait_program2 wt-ss ${TMP2}/logs_${mark}/log.txt started

	if [ -f "${TMP2}/socsk5_ports.txt" ];then
		eval $(cat ${TMP2}/socsk5_ports.txt)
	fi

	# multi thread
	[ -e /tmp/fd1 ] || mknod /tmp/fd1 p
	exec 3<>/tmp/fd1
	rm -rf /tmp/fd1

	awk 'BEGIN { for (i=1; i<=8; i++) printf("%d\n", i) }' | while read seq
	do
		echo
	done >&3

	# test in multiple process
	cat ${TMP2}/${file} | while read nu; do
		read -u3
		{
			# 0. testing info
			echo -en "${nu}>testing...\n" >>/tmp/upload/webtest.txt
			cat ${TMP2}/results/*.txt > /tmp/upload/webtest.txt
			
			# 1. start obfs-local
			if [ -x "${TMP2}/bash_${mark}/start_${nu}.sh" ];then
				sh ${TMP2}/bash_${mark}/start_${nu}.sh
			fi
			
			# 2. start curl test
			local socks5_port=$(eval echo \$socks5_port_${nu})
			curl_test ${nu} ${socks5_port}

			# 4. write tested info
			cat ${TMP2}/results/*.txt > /tmp/upload/webtest.txt
			
			# 5. stop obfs-local
			if [ -x "${TMP2}/bash_${mark}/stop_${nu}.sh" ];then
				sh ${TMP2}/bash_${mark}/stop_${nu}.sh
			fi
			
			echo >&3
		} &
	done

	exec 3<&-
	exec 3>&-

	# finished kill xray
	killall wt-ss >/dev/null 2>&1
	killall wt-obfs >/dev/null 2>&1

	# finished
	rm -rf ${TMP2}/wt-ss
	rm -rf ${TMP2}/wt-obfs
}

test_03_ss(){
	# not used since 3.3.6
	local file=$1

	cat ${TMP2}/${file} | xargs -n 8 | while read nus; do
		for nu in $nus; do
			{
				echo -en "${nu}>testing\n" >>/tmp/upload/webtest.txt
				echo -en "${nu}>ns\n" >>${TMP2}/results/${nu}.txt
			} &
		done
		wait

		# merge all curl test result
		find ${TMP2}/results/ -name "*.txt" | sort -t "/" -nk5 | xargs cat > /tmp/upload/webtest.txt
	done
}

test_07_sr(){
	local file=$1
	local mark=$2
	
	# alisa binary
	killall wt-rss-local >/dev/null 2>&1
	ln -sf /koolshare/bin/rss-local ${TMP2}/wt-rss-local
	mkdir -p ${TMP2}/conf_${mark}
	rm -rf ${TMP2}/conf_${mark}/*

	cat ${TMP2}/${file} | xargs -n 8 | while read nus; do
		for nu in $nus; do
			{
				# 0. testing info
				echo -en "${nu}>testing...\n" >>/tmp/upload/webtest.txt
				
				# 1. resolve server
				local _server_ip=$(_get_server_ip $(dbus get ssconf_basic_server_${nu}))
				if [ -z "${_server_ip}" ];then
					# use domain
					_server_ip=$(dbus get ssconf_basic_server_${nu})
				fi

				# 2. gen json conf
				local socks5_port=$(get_rand_port)
				cat >${TMP2}/conf_${mark}/${nu}.json <<-EOF
					{
					    "server":"${_server_ip}",
					    "server_port":$(dbus get ssconf_basic_port_${nu}),
					    "local_address":"0.0.0.0",
					    "local_port":${socks5_port},
					    "password":"$(dbus get ssconf_basic_password_${nu} | base64_decode)",
					    "timeout":600,
					    "protocol":"$(dbus get ssconf_basic_rss_protocol_${nu})",
					    "protocol_param":"$(dbus get ssconf_basic_rss_protocol_param_${nu})",
					    "obfs":"$(dbus get ssconf_basic_rss_obfs_${nu})",
					    "obfs_param":"$(dbus get ssconf_basic_rss_obfs_param_${nu})",
					    "method":"$(dbus get ssconf_basic_method_${nu})"
					}
				EOF

				# 3. start rss-local
				run ${TMP2}/wt-rss-local -c ${TMP2}/conf_${mark}/${nu}.json -f ${TMP2}/pids/${nu}.pid >/dev/null 2>&1
				sleep 1

				# 4. start curl test
				curl_test ${nu} ${socks5_port}

				# 5. stop rss-local
				if [ -f "${TMP2}/pids/${nu}.pid" ];then
					kill -9 $(cat ${TMP2}/pids/${nu}.pid) >/dev/null 2>&1
				fi
			} &
		done
		wait

		# merge all curl test result
		find ${TMP2}/results/ -name "*.txt" | sort -t "/" -nk5 | xargs cat > /tmp/upload/webtest.txt
	done

	rm -rf ${TMP2}/wt-ss-local
}

test_08_vr(){
	local file=$1

	# alisa binary
	killall wt-v2ray >/dev/null 2>&1
	if [ -x "/koolshare/bin/v2ray" ];then
		ln -sf /koolshare/bin/v2ray ${TMP2}/wt-v2ray
	else
		ln -sf /koolshare/bin/xray ${TMP2}/wt-v2ray
	fi

	# gen all v2ray conf
	cat ${TMP2}/${file} | xargs -n 16 | while read nus; do
		for nu in $nus; do
			{
				creat_v2ray_json ${nu}
			} &
		done
		wait
	done

	# merge json
	mkdir -p ${TMP2}/json
	rm -rf ${TMP2}/json/*
	find ${TMP2}/conf -name "*_inbounds.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{ inbounds: [ inputs.inbounds[0] ] }' >${TMP2}/json/00_inbounds.json
	find ${TMP2}/conf -name "*_outbounds.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{ outbounds: [ inputs.outbounds[0] ] }' >${TMP2}/json/01_outbounds.json
	find ${TMP2}/conf -name "*_routing.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{routing: { rules: [ inputs.routing.rules[0] ] }}' >${TMP2}/json/02_routing.json
	rm -rf ${TMP2}/conf/*

	# now we can start v2ray or v2ray/xray to host multiple outbounds
	run ${TMP2}/wt-v2ray run -confdir ${TMP2}/json/ >/dev/null 2>&1 &
	
	# make sure xray/v2ray is runing, otherwise output error
	sleep 3
	wait_program wt-v2ray

	if [ -f "${TMP2}/socsk5_ports.txt" ];then
		eval $(cat ${TMP2}/socsk5_ports.txt)
	fi
	
	# test in multiple process
	cat ${TMP2}/${file} | xargs -n 8 | while read nus; do
		for nu in $nus; do
			{
				# 0. testing info
				echo -en "${nu}>testing...\n" >>/tmp/upload/webtest.txt

				# 2. start curl test
				local socks5_port=$(eval echo \$socks5_port_${nu})
				curl_test ${nu} ${socks5_port}
			} &
		done
		wait

		# merge all curl test result
		find ${TMP2}/results/ -name "*.txt" | sort -t "/" -nk5 | xargs cat > /tmp/upload/webtest.txt
	done
	
	# finished kill v2ray
	killall wt-v2ray >/dev/null 2>&1

	# finished
	rm -rf ${TMP2}/conf/*
	rm -rf ${TMP2}/json/*
	rm -rf ${TMP2}/wt-v2ray
}

test_09_xr(){
	local file=$1

	# alisa binary
	killall wt-xray >/dev/null 2>&1
	ln -sf /koolshare/bin/xray ${TMP2}/wt-xray
	mkdir -p ${TMP2}/conf/
	rm -rf ${TMP2}/conf/*

	# gen all xray conf
	cat ${TMP2}/${file} | xargs -n 16 | while read nus; do
		for nu in $nus; do
			{
				creat_xray_json ${nu}
			} &
		done
		wait
	done

	# merge all xray json
	mkdir -p ${TMP2}/json
	rm -rf ${TMP2}/json/*
	find ${TMP2}/conf -name "*_inbounds.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{ inbounds: [ inputs.inbounds[0] ] }' >${TMP2}/json/00_inbounds.json
	find ${TMP2}/conf -name "*_outbounds.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{ outbounds: [ inputs.outbounds[0] ] }' >${TMP2}/json/01_outbounds.json
	find ${TMP2}/conf -name "*_routing.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{routing: { rules: [ inputs.routing.rules[0] ] }}' >${TMP2}/json/02_routing.json
	rm -rf ${TMP2}/conf/*

	# now we can start xray or xray to host multiple outbounds
	run ${TMP2}/wt-xray run -confdir ${TMP2}/json/ >/dev/null 2>&1 &

	# make sure xray is runing, otherwise output error
	sleep 3
	wait_program wt-xray

	if [ -f "${TMP2}/socsk5_ports.txt" ];then
		eval $(cat ${TMP2}/socsk5_ports.txt)
	fi

	# test in multiple process
	cat ${TMP2}/${file} | xargs -n 8 | while read nus; do
		for nu in $nus; do
			{
				# 0. testing info
				echo -en "${nu}>testing...\n" >>/tmp/upload/webtest.txt
				
				# 2. start curl test
				local socks5_port=$(eval echo \$socks5_port_${nu})
				curl_test ${nu} ${socks5_port}
			} &
		done
		wait

		# merge all curl test result
		find ${TMP2}/results/ -name "*.txt" | sort -t "/" -nk5 | xargs cat > /tmp/upload/webtest.txt
	done

	# finished kill xray
	killall wt-xray >/dev/null 2>&1

	# finished
	rm -rf ${TMP2}/conf/*
	rm -rf ${TMP2}/json/*
	rm -rf ${TMP2}/wt-xray
}

test_10_tj(){
	local file=$1

	# alisa binary
	killall wt-trojan >/dev/null 2>&1
	ln -sf /koolshare/bin/xray ${TMP2}/wt-trojan

	# gen all trojan conf
	cat ${TMP2}/${file} | xargs -n 16 | while read nus; do
		for nu in $nus; do
			{
				creat_trojan_json ${nu}
			} &
		done
		wait
	done

	# merge all trojan json
	mkdir -p ${TMP2}/json
	rm -rf ${TMP2}/json/*
	find ${TMP2}/conf -name "*_inbounds.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{ inbounds: [ inputs.inbounds[0] ] }' >${TMP2}/json/00_inbounds.json
	find ${TMP2}/conf -name "*_outbounds.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{ outbounds: [ inputs.outbounds[0] ] }' >${TMP2}/json/01_outbounds.json
	find ${TMP2}/conf -name "*_routing.json" | sort -t "/" -nk5 | xargs cat | run jq -n '{routing: { rules: [ inputs.routing.rules[0] ] }}' >${TMP2}/json/02_routing.json
	rm -rf ${TMP2}/conf/*

	# now we can start wt-trojan to host multiple outbounds
	run ${TMP2}/wt-trojan run -confdir ${TMP2}/json/ >/dev/null 2>&1 &

	# make sure wt-trojan is runing, otherwise output error
	sleep 3
	wait_program wt-trojan

	if [ -f "${TMP2}/socsk5_ports.txt" ];then
		eval $(cat ${TMP2}/socsk5_ports.txt)
	fi

	# test in multiple process
	cat ${TMP2}/${file} | xargs -n 8 | while read nus; do
		for nu in $nus; do
			{
				# 0. testing info
				echo -en "${nu}>testing...\n" >>/tmp/upload/webtest.txt

				# 2. start curl test
				local socks5_port=$(eval echo \$socks5_port_${nu})
				curl_test ${nu} ${socks5_port}
			} &
		done
		wait

		# merge all curl test result
		find ${TMP2}/results/ -name "*.txt" | sort -t "/" -nk5 | xargs cat > /tmp/upload/webtest.txt
	done

	# finished kill wt-trojan
	killall wt-trojan >/dev/null 2>&1

	# finished
	rm -rf ${TMP2}/conf/*
	rm -rf ${TMP2}/json/*
	rm -rf ${TMP2}/wt-trojan
}

test_11_nv(){
	local file=$1

	# alisa binary
	ln -sf /koolshare/bin/naive ${TMP2}/wt-naive
	killall wt-naive >/dev/null 2>&1

	cat ${TMP2}/${file} | xargs -n 2 | while read nus; do
		for nu in $nus; do
			{
				# 1. resolve server
				local _server_ip=$(_get_server_ip $(dbus get ssconf_basic_naive_server_${nu}))

				# 2. start naiveproxy
				local socks5_port=$(get_rand_port)
				if [ -z "${_server_ip}" ];then
					run ${TMP2}/wt-naive --listen=socks://127.0.0.1:${socks5_port} --proxy=$(dbus get ssconf_basic_naive_prot_${nu})://$(dbus get ssconf_basic_naive_user_${nu}):$(dbus get ssconf_basic_naive_pass_${nu} | base64_decode)@$(dbus get ssconf_basic_naive_server_${nu}):$(dbus get ssconf_basic_naive_port_${nu}) >/dev/null 2>&1 &
				else
					run ${TMP2}/wt-naive --listen=socks://127.0.0.1:${socks5_port} --proxy=$(dbus get ssconf_basic_naive_prot_${nu})://$(dbus get ssconf_basic_naive_user_${nu}):$(dbus get ssconf_basic_naive_pass_${nu} | base64_decode)@$(dbus get ssconf_basic_naive_server_${nu}):$(dbus get ssconf_basic_naive_port_${nu}) --host-resolver-rules="MAP $(dbus get ssconf_basic_naive_server_${nu}) ${_server_ip}" >/dev/null 2>&1 &
				fi

				sleep 2

				# 4. start curl test
				curl_test ${nu} ${socks5_port}

				# 5. stop naive
				local _pid=$(ps | grep wt-naive | grep ${socks5_port} | awk '{print $1}')
				if [ -n "${_pid}" ];then
					kill -9 ${_pid} >/dev/null 2>&1
				fi
			} &
		done
		wait

		# merge all curl test result
		find ${TMP2}/results/ -name "*.txt" | sort -t "/" -nk5 | xargs cat > /tmp/upload/webtest.txt
	done
	
	killall wt-naive >/dev/null 2>&1
	rm -rf ${TMP2}/wt-naive
}

test_12_tc(){
	local file=$1

	# alisa binary
	ln -sf /koolshare/bin/tuic-client ${TMP2}/wt-tuic
	killall wt-tuic >/dev/null 2>&1

	cat ${TMP2}/${file} | xargs -n 2 | while read nus; do
		for nu in $nus; do
			{
				# 1. gen json
				local socks5_port=$(get_rand_port)
				local new_addr="127.0.0.1:${socks5_port}"
				dbus get ssconf_basic_tuic_json_${nu} | base64_decode | run jq --arg addr "$new_addr" '.local.server = $addr' >${TMP2}/conf/tuic-${socks5_port}.json

				# 2. start tuic
				run ${TMP2}/wt-tuic -c ${TMP2}/conf/tuic-${socks5_port}.json >/dev/null 2>&1 &

				sleep 2

				# 4. start curl test
				curl_test ${nu} ${socks5_port}

				# 5. stop tuic
				local _pid=$(ps | grep "wt-tuic" | grep -v grep | grep ${socks5_port} | awk '{print $1}')
				if [ -n "${_pid}" ];then
					kill -9 ${_pid} >/dev/null 2>&1
				fi
			} &
		done
		wait

		# merge all curl test result
		find ${TMP2}/results/ -name "*.txt" | sort -t "/" -nk5 | xargs cat > /tmp/upload/webtest.txt
	done
	
	killall wt-tuic >/dev/null 2>&1
	rm -rf ${TMP2}/wt-tuic
}

test_13_h2(){
	local file=$1
	local mark=$2
	
	# alisa binary
	killall wt-hy2 >/dev/null 2>&1
	mkdir -p ${TMP2}/conf_${mark}
	rm -rf ${TMP2}/wt-hy2
	rm -rf ${TMP2}/conf_${mark}/*
	ln -sf /koolshare/bin/hysteria2 ${TMP2}/wt-hy2

	# gen hy2 yaml
	cat ${TMP2}/${file} | xargs -n 16 | while read nus; do
		for nu in $nus; do
			{
				creat_hy2_yaml ${nu} ${mark}
			} &
		done
		wait
	done

	if [ -f "${TMP2}/socsk5_ports.txt" ];then
		eval $(cat ${TMP2}/socsk5_ports.txt)
	fi

	cat ${TMP2}/${file} | xargs -n 1 | while read nus; do
		for nu in $nus; do
			{
				# 0. testing info
				echo -en "${nu}>testing...\n" >>/tmp/upload/webtest.txt

				# 1. start hy2       
				if [ "${LINUX_VER}" == "419" -o "${LINUX_VER}" == "54" ];then
					run ${TMP2}/wt-hy2 -c ${TMP2}/conf_${mark}/${nu}.yaml >/dev/null 2>&1 &
				else
					env -i PATH=${PATH} QUIC_GO_DISABLE_ECN=true ${TMP2}/wt-hy2 -c ${TMP2}/conf_${mark}/${nu}.yaml >/dev/null 2>&1 &
				fi
				sleep 2

				# 2. start curl test
				local socks5_port=$(eval echo \$socks5_port_${nu})
				curl_test ${nu} ${socks5_port}

				# 3. stop hy2
				killall wt-hy2
			} &
		done
		wait
		
		# merge all curl test result
		find ${TMP2}/results/ -name "*.txt" | sort -t "/" -nk5 | xargs cat > /tmp/upload/webtest.txt
	done

	rm -rf ${TMP2}/wt-hy2
	#rm -rf ${TMP2}/conf/*
}

creat_v2ray_json() {
	local nu=$1
	local v2ray_use_json=$(dbus get ssconf_basic_v2ray_use_json_${nu})
	# regular format
	if [ "${v2ray_use_json}" != "1" ]; then
		local v2ray_server=$(dbus get ssconf_basic_server_${nu})
		local _server_ip=$(_get_server_ip ${v2ray_server})
		if [ -z "${_server_ip}" ];then
			_server_ip=${v2ray_server}
		fi
	
		local tcp="null"
		local kcp="null"
		local ws="null"
		local h2="null"
		local qc="null"
		local gr="null"
		local tls="null"
		
		local v2ray_network_host=$(dbus get ssconf_basic_v2ray_network_host_${nu} | sed 's/,/", "/g')
		local v2ray_network_path=$(dbus get ssconf_basic_v2ray_network_path_${nu})
		local v2ray_network_security="none"
		local v2ray_network_security=$(dbus get ssconf_basic_v2ray_network_security_${nu})
		if [ "${v2ray_network_security}" == "tls" ];then
			local v2ray_network_security_ai=$(dbus get ssconf_basic_v2ray_network_security_ai_${nu})
			local v2ray_network_security_alpn_h2=$(dbus get ssconf_basic_v2ray_network_security_alpn_h2_${nu})
			local v2ray_network_security_alpn_http=$(dbus get ssconf_basic_v2ray_network_security_alpn_http_${nu})

			if [ "${v2ray_network_security_alpn_h2}" == "1" -a "${v2ray_network_security_alpn_http}" == "1" ];then
				local apln="[\"h2\",\"http/1.1\"]"
			elif [ "${v2ray_network_security_alpn_h2}" != "1" -a "${v2ray_network_security_alpn_http}" == "1" ];then
				local apln="[\"http/1.1\"]"
			elif [ "${v2ray_network_security_alpn_h2}" == "1" -a "${v2ray_network_security_alpn_http}" != "1" ];then
				local apln="[\"h2\"]"
			elif [ "${v2ray_network_security_alpn_h2}" != "1" -a "${v2ray_network_security_alpn_http}" != "1" ];then
				local apln="null"
			fi

			# sni is sni
			local v2ray_network_security_sni=$(dbus get ssconf_basic_v2ray_network_security_sni_${nu})
			
			# sni is server
			if [ -z "${v2ray_network_security_sni}" ];then
				__valid_ip "${v2ray_server}"
				if [ "$?" != "0" ]; then
					# likely to be domain
					local v2ray_network_security_sni="$(dbus get ssconf_basic_server_${nu})"
				fi
			fi

			# sni is host
			if [ -z "${v2ray_network_security_sni}" -a -n "{v2ray_network_host}" ];then
				local v2ray_network_security_sni=$(echo "${v2ray_network_host}" | sed 's/", "/\n/g' | head -n1)
			fi

			# gather
			local tls="{
				\"allowInsecure\": $(get_function_switch ${v2ray_network_security_ai})
				,\"alpn\": ${apln}
				,\"serverName\": $(get_value_null ${v2ray_network_security_sni})
				}"		
		fi
		local v2ray_headtype_tcp=$(dbus get ssconf_basic_v2ray_headtype_tcp_${nu})
		local v2ray_headtype_kcp=$(dbus get ssconf_basic_v2ray_headtype_kcp_${nu})
		local v2ray_kcp_seed=$(dbus get ssconf_basic_v2ray_kcp_seed_${nu})
		local v2ray_headtype_quic=$(dbus get ssconf_basic_v2ray_headtype_quic_${nu})
		local v2ray_grpc_mode=$(dbus get ssconf_basic_v2ray_grpc_mode_${nu})
		
		local v2ray_network=$(dbus get ssconf_basic_v2ray_network_${nu})
		[ -z "${v2ray_network}" ] && v2ray_network="tcp"
		case "${v2ray_network}" in
		tcp)
			if [ "${v2ray_headtype_tcp}" == "http" ]; then
				local tcp="{
					\"header\": {
					\"type\": \"http\"
					,\"request\": {
					\"version\": \"1.1\"
					,\"method\": \"GET\"
					,\"path\": $(get_path_empty ${v2ray_network_path})
					,\"headers\": {
					\"Host\": $(get_host_empty ${v2ray_network_host}),
					\"User-Agent\": [
					\"Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/55.0.2883.75 Safari/537.36\"
					,\"Mozilla/5.0 (iPhone; CPU iPhone OS 10_0_2 like Mac OS X) AppleWebKit/601.1 (KHTML, like Gecko) CriOS/53.0.2785.109 Mobile/14A456 Safari/601.1.46\"
					]
					,\"Accept-Encoding\": [\"gzip, deflate\"]
					,\"Connection\": [\"keep-alive\"]
					,\"Pragma\": \"no-cache\"
					}
					}
					}
					}"
			fi
			;;
		kcp)
			local kcp="{
				\"mtu\": 1350
				,\"tti\": 50
				,\"uplinkCapacity\": 12
				,\"downlinkCapacity\": 100
				,\"congestion\": false
				,\"readBufferSize\": 2
				,\"writeBufferSize\": 2
				,\"header\": {
				\"type\": \"${v2ray_headtype_kcp}\"
				}
				,\"seed\": $(get_value_null ${v2ray_kcp_seed})
				}"
			;;
		ws)
			if [ -z "${v2ray_network_path}" -a -z "${v2ray_network_host}" ]; then
				local ws="{}"
			elif [ -z "${v2ray_network_path}" -a -n "${v2ray_network_host}" ]; then
				local ws="{
					\"headers\": $(get_ws_header ${v2ray_network_host})
					}"
			elif [ -n "${v2ray_network_path}" -a -z "${v2ray_network_host}" ]; then
				local ws="{
					\"path\": $(get_value_null ${v2ray_network_path})
					}"
			elif [ -n "${v2ray_network_path}" -a -n "${v2ray_network_host}" ]; then
				local ws="{
					\"path\": $(get_value_null ${v2ray_network_path}),
					\"headers\": $(get_ws_header ${v2ray_network_host})
					}"
			fi
			;;
		h2)
			local h2="{
				\"path\": $(get_value_empty ${v2ray_network_path})
				,\"host\": $(get_host ${v2ray_network_host})
				}"
			;;
		quic)
			local qc="{
				\"security\": $(get_value_empty ${v2ray_network_host}),
				\"key\": $(get_value_empty ${v2ray_network_path}),
				\"header\": {
				\"type\": \"${v2ray_headtype_quic}\"
				}
				}"
			;;
		grpc)
			local gr="{
				\"serviceName\": $(get_value_empty ${v2ray_network_path}),
				\"multiMode\": $(get_grpc_multimode ${v2ray_grpc_mode})
				}"
			;;
		esac

		local v2ray_port=$(dbus get ssconf_basic_port_${nu})
		local v2ray_uuid=$(dbus get ssconf_basic_v2ray_uuid_${nu})
		local v2ray_alterid=$(dbus get ssconf_basic_v2ray_alterid_${nu})
		local v2ray_security=$(dbus get ssconf_basic_v2ray_security_${nu})
		[ -z "${xray_alterid}" ] && xray_alterid="0"
		[ -z "${v2ray_security}" ] && v2ray_security="auto"
	
		# outbounds area
		cat >>${TMP2}/conf/${nu}_outbounds.json <<-EOF
			{
			"outbounds": [
				{
					"tag": "proxy${nu}",
					"protocol": "vmess",
					"settings": {
						"vnext": [
							{
								"address": "${_server_ip}",
								"port": ${v2ray_port},
								"users": [
									{
										"id": "${v2ray_uuid}"
										,"alterId": ${v2ray_alterid}
										,"security": "${v2ray_security}"
									}
								]
							}
						]
					},
					"streamSettings": {
						"network": "${v2ray_network}"
						,"security": "${v2ray_network_security}"
						,"tlsSettings": $tls
						,"tcpSettings": $tcp
						,"kcpSettings": $kcp
						,"wsSettings": $ws
						,"httpSettings": $h2
						,"quicSettings": $qc
						,"grpcSettings": $gr
					},
					"mux": {"enabled": false}
				}
			]
			}
		EOF

		# delete all null value
		# jq 'del(..|nulls)' ${TMP2}/conf/${nu}_outbounds.json | run sponge ${TMP2}/conf/${nu}_outbounds.json
		sed -i '/null/d' ${TMP2}/conf/${nu}_outbounds.json 2>/dev/null
	else
		dbus get ssconf_basic_v2ray_json_${nu} | base64_decode >${TMP2}/v2ray_user.json
		local OB=$(cat ${TMP2}/v2ray_user.json | run jq .outbound)
		local OBS=$(cat ${TMP2}/v2ray_user.json | run jq .outbounds)

		# 兼容旧格式：outbound
		if [ "$OB" != "null" ]; then
			OUTBOUNDS=$(cat ${TMP2}/v2ray_user.json | run jq .outbound)
		fi
		
		# 新格式：outbound[]
		if [ "$OBS" != "null" ]; then
			OUTBOUNDS=$(cat ${TMP2}/v2ray_user.json | run jq .outbounds[0])
		fi
		echo "{}" | run jq --argjson args "$OUTBOUNDS" '. + {outbounds: [$args]}' >${TMP2}/conf/${nu}_outbounds.json
	fi

	# inbounds
	local socks5_port=$(get_rand_port)
	echo "export socks5_port_${nu}=${socks5_port}" >> ${TMP2}/socsk5_ports.txt
	cat >>${TMP2}/conf/${nu}_inbounds.json <<-EOF
		{
		  "inbounds": [
		    {
		      "port": ${socks5_port},
		      "protocol": "socks",
		      "settings": {
		        "auth": "noauth",
		        "udp": true
		      },
		      "tag": "socks${nu}"
		    }
		  ]
		}
	EOF

	# routing
	cat >>${TMP2}/conf/${nu}_routing.json <<-EOF
		{
		  "routing": {
		    "rules": [
		      {
		        "type": "field",
		        "inboundTag": ["socks${nu}"],
		        "outboundTag": "proxy${nu}"
		      }
		    ]
		  }
		}
	EOF
}

creat_xray_ss_json() {
	local nu=$1
	local mark=$2

	# gen xray outbound
	local ss_server=$(dbus get ssconf_basic_server_${nu})
	local _server_ip=$(_get_server_ip ${ss_server})
	if [ -z "${_server_ip}" ];then
		_server_ip=${ss_server}
	fi
	local ss_port=$(dbus get ssconf_basic_port_${nu})
	local ss_pass=$(dbus get ssconf_basic_password_${nu} | base64_decode)
	local ss_meth=$(dbus get ssconf_basic_method_${nu})
	
	if [ "${ss_basic_tfo}" == "1" -a "${LINUX_VER}" != "26" ]; then
		local OBFS_ARG="--fast-open"
		echo 3 >/proc/sys/net/ipv4/tcp_fastopen
	else
		local OBFS_ARG=""
	fi

	# obfs
	if [ "$(dbus get ssconf_basic_ss_obfs_${nu})" == "http" -o "$(dbus get ssconf_basic_ss_obfs_${nu})" == "tls" ]; then
		local obfs_port=$(get_rand_port)
		local _server_ip_tmp="127.0.0.1"
		local _server_port_tmp="${obfs_port}"
		if [ -n "$(dbus get ssconf_basic_ss_obfs_host_${nu})" ]; then
			cat >>"${TMP2}/bash_${mark}/start_${nu}.sh" <<-EOF
				#!/bin/sh
				${TMP2}/wt-obfs -s ${_server_ip} -p ${ss_port} -l ${_server_port_tmp} --obfs $(dbus get ssconf_basic_ss_obfs_${nu}) --obfs-host $(dbus get ssconf_basic_ss_obfs_host_${nu}) ${OBFS_ARG} >/dev/null 2>&1 &
			EOF
		else
			cat >>"${TMP2}/bash_${mark}/start_${nu}.sh" <<-EOF
				#!/bin/sh
				${TMP2}/wt-obfs -s ${_server_ip} -p ${ss_port} -l ${_server_port_tmp} --obfs $(dbus get ssconf_basic_ss_obfs_${nu}) ${OBFS_ARG} >/dev/null 2>&1 &
			EOF
		fi
		cat >${TMP2}/bash_${mark}/stop_${nu}.sh <<-EOF
			#!/bin/sh
			_pid=\$(ps -w | grep "wt-obfs" | grep -w "${_server_ip}" | grep -w "${ss_port}" | grep -w "${_server_port_tmp}" | awk '{print \$1}' | head -n1)
			if [ -n "\${_pid}" ];then
			    kill -9 \${_pid}
			fi
		EOF
		
		chmod +x ${TMP2}/bash_${mark}/start_${nu}.sh
		chmod +x ${TMP2}/bash_${mark}/stop_${nu}.sh
	else
		local _server_ip_tmp="${_server_ip}"
		local _server_port_tmp="${ss_port}"
	fi
	
	cat >>${TMP2}/conf_${mark}/${nu}_outbounds.json <<-EOF
		{
		"outbounds": [
			{
				"tag": "proxy${nu}",
				"protocol": "shadowsocks",
				"settings": {
					"servers": [
						{
							"address": "${_server_ip_tmp}",
							"port": ${_server_port_tmp},
							"password": "${ss_pass}",
							"method": "${ss_meth}",
							"uot": false
						}
					]
				},
				"sockopt": {
					"tcpFastOpen": $(get_function_switch ${ss_basic_tfo}),
					"tcpcongestion": "bbr"
				}
			}
		]
		}
	EOF
	
	sed -i '/null/d' ${TMP2}/conf_${mark}/${nu}_outbounds.json 2>/dev/null
	if [ "${LINUX_VER}" == "26" ]; then
		sed -i '/tcpFastOpen/d' ${TMP2}/conf_${mark}/${nu}_outbounds.json 2>/dev/null
	fi

	# inbounds
	local socks5_port=$(get_rand_port)
	echo "export socks5_port_${nu}=${socks5_port}" >> ${TMP2}/socsk5_ports.txt
	cat >>${TMP2}/conf_${mark}/${nu}_inbounds.json <<-EOF
		{
		  "inbounds": [
		    {
		      "port": ${socks5_port},
		      "protocol": "socks",
		      "settings": {
		        "auth": "noauth",
		        "udp": true
		      },
		      "tag": "socks${nu}"
		    }
		  ]
		}
	EOF

	# routing
	cat >>${TMP2}/conf_${mark}/${nu}_routing.json <<-EOF
		{
		  "routing": {
		    "rules": [
		      {
		        "type": "field",
		        "inboundTag": ["socks${nu}"],
		        "outboundTag": "proxy${nu}"
		      }
		    ]
		  }
		}
	EOF
}

creat_xray_json() {
	local nu=$1
	local xray_use_json=$(dbus get ssconf_basic_xray_use_json_${nu})

	if [ "${xray_use_json}" != "1" ]; then
		local xray_server=$(dbus get ssconf_basic_server_${nu})
		local _server_ip=$(_get_server_ip ${xray_server})
		if [ -z "${_server_ip}" ];then
			_server_ip=${xray_server}
		fi

		local tcp="null"
		local kcp="null"
		local ws="null"
		local h2="null"
		local qc="null"
		local gr="null"
		local tls="null"
		local xtls="null"
		local reali="null"

		local xray_network_host=$(dbus get ssconf_basic_xray_network_host_${nu} | sed 's/,/", "/g')
		local xray_network_path=$(dbus get ssconf_basic_xray_network_path_${nu})
		# sni is sni
		local xray_network_security_sni=$(dbus get ssconf_basic_xray_network_security_sni_${nu})
		# sni is server
		if [ -z "${xray_network_security_sni}" ];then
			__valid_ip "${xray_server}"
			if [ "$?" != "0" ]; then
				# likely to be domain
				local xray_network_security_sni="$(dbus get ssconf_basic_server_${nu})"
			fi
		fi
		# sni is host
		if [ -z "${xray_network_security_sni}" -a -n "{xray_network_host}" ];then
			local xray_network_security_sni=$(echo "${xray_network_host}" | sed 's/", "/\n/g' | head -n1)
		fi
		local xray_flow=$(dbus get ssconf_basic_xray_flow_${nu})
		local xray_fingerprint=$(dbus get ssconf_basic_xray_fingerprint_${nu})
		[ -z "${xray_fingerprint}" ] && xray_fingerprint="chrome"
		local xray_network_security="none"
		local xray_network_security=$(dbus get ssconf_basic_xray_network_security_${nu})

		if [ "${xray_network_security}" == "tls" -o "${xray_network_security}" == "xtls" ];then
			local xray_network_security_ai=$(dbus get ssconf_basic_xray_network_security_ai_${nu})
			local xray_network_security_alpn_h2=$(dbus get ssconf_basic_xray_network_security_alpn_h2_${nu})
			local xray_network_security_alpn_ht=$(dbus get ssconf_basic_xray_network_security_alpn_http_${nu})
			if [ "${xray_network_security_alpn_h2}" == "1" -a "${xray_network_security_alpn_ht}" == "1" ];then
				local apln="[\"h2\",\"http/1.1\"]"
			elif [ "${xray_network_security_alpn_h2}" != "1" -a "${xray_network_security_alpn_ht}" == "1" ];then
				local apln="[\"http/1.1\"]"
			elif [ "${xray_network_security_alpn_h2}" == "1" -a "${xray_network_security_alpn_ht}" != "1" ];then
				local apln="[\"h2\"]"
			elif [ "${xray_network_security_alpn_h2}" != "1" -a "${xray_network_security_alpn_ht}" != "1" ];then
				local apln="null"
			fi

			# gather
			local _tmp="{
					\"allowInsecure\": $(get_function_switch ${xray_network_security_ai})
					,\"alpn\": ${apln}
					,\"serverName\": $(get_value_null ${xray_network_security_sni})
					,\"fingerprint\": $(get_value_empty ${xray_fingerprint})
					}"

			# tls or xtls
			if [ "${xray_network_security}" == "tls" ];then
				local tls="${_tmp}"
			elif [ "${xray_network_security}" == "xtls" ];then
				local xtls="${_tmp}"
			fi
		fi

		if [ "${xray_network_security}" == "reality" ];then
			local xray_show=$(dbus get ssconf_basic_xray_show_${nu})
			local xray_fingerprint=$(dbus get ssconf_basic_xray_fingerprint_${nu})
			[ -z "${xray_fingerprint}" ] && xray_fingerprint="chrome"
			local xray_publickey=$(dbus get ssconf_basic_xray_publickey_${nu})
			local xray_shortid=$(dbus get ssconf_basic_xray_shortid_${nu})
			local xray_spiderx=$(dbus get ssconf_basic_xray_spiderx_${nu})
			local reali="{
					\"show\": $(get_function_switch ${xray_show})
					,\"fingerprint\": $(get_value_empty ${xray_fingerprint})
					,\"serverName\": $(get_value_null ${xray_network_security_sni})
					,\"publicKey\": $(get_value_null ${xray_publickey})
					,\"shortId\": $(get_value_empty ${xray_shortid})
					,\"spiderX\": $(get_value_empty $xray_spiderx)
					}"
		fi

		if [ "${xray_network_security}" == "none" ];then
			local xray_flow=""
		fi

		local xray_headtype_tcp=$(dbus get ssconf_basic_xray_headtype_tcp_${nu})
		local xray_headtype_kcp=$(dbus get ssconf_basic_xray_headtype_kcp_${nu})
		local xray_kcp_seed=$(dbus get ssconf_basic_xray_kcp_seed_${nu})
		local xray_headtype_quic=$(dbus get ssconf_basic_xray_headtype_quic_${nu})
		local xray_grpc_mode=$(dbus get ssconf_basic_xray_grpc_mode_${nu})
		
		local xray_network=$(dbus get ssconf_basic_xray_network_${nu})
		[ -z "${xray_network}" ] && xray_network="tcp"
		case "${xray_network}" in
		tcp)
			if [ "${xray_headtype_tcp}" == "http" ]; then
				local tcp="{
					\"header\": {
					\"type\": \"http\"
					,\"request\": {
					\"version\": \"1.1\"
					,\"method\": \"GET\"
					,\"path\": $(get_path_empty ${xray_network_path})
					,\"headers\": {
					\"Host\": $(get_host_empty ${xray_network_host}),
					\"User-Agent\": [
					\"Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/55.0.2883.75 Safari/537.36\"
					,\"Mozilla/5.0 (iPhone; CPU iPhone OS 10_0_2 like Mac OS X) AppleWebKit/601.1 (KHTML, like Gecko) CriOS/53.0.2785.109 Mobile/14A456 Safari/601.1.46\"
					]
					,\"Accept-Encoding\": [\"gzip, deflate\"]
					,\"Connection\": [\"keep-alive\"]
					,\"Pragma\": \"no-cache\"
					}
					}
					}
					}"
			fi
			;;
		kcp)
			local kcp="{
				\"mtu\": 1350
				,\"tti\": 50
				,\"uplinkCapacity\": 12
				,\"downlinkCapacity\": 100
				,\"congestion\": false
				,\"readBufferSize\": 2
				,\"writeBufferSize\": 2
				,\"header\": {
				\"type\": \"${xray_headtype_kcp}\"
				}
				,\"seed\": $(get_value_null ${xray_kcp_seed})
				}"
			;;
		ws)
			if [ -z "${xray_network_path}" -a -z "${xray_network_host}" ]; then
				local ws="{}"
			elif [ -z "${xray_network_path}" -a -n "${xray_network_host}" ]; then
				local ws="{
					\"headers\": $(get_ws_header ${xray_network_host})
					}"
			elif [ -n "${xray_network_path}" -a -z "${xray_network_host}" ]; then
				local ws="{
					\"path\": $(get_value_null ${xray_network_path})
					}"
			elif [ -n "${xray_network_path}" -a -n "${xray_network_host}" ]; then
				local ws="{
					\"path\": $(get_value_null ${xray_network_path}),
					\"headers\": $(get_ws_header ${xray_network_host})
					}"
			fi
			;;
		h2)
			local h2="{
				\"path\": $(get_value_empty ${xray_network_path})
				,\"host\": $(get_host ${xray_network_host})
				}"
			;;
		quic)
			local qc="{
				\"security\": $(get_value_empty ${xray_network_host}),
				\"key\": $(get_value_empty ${xray_network_path}),
				\"header\": {
				\"type\": \"${xray_headtype_quic}\"
				}
				}"
			;;
		grpc)
			local gr="{
				\"serviceName\": $(get_value_empty ${xray_network_path}),
				\"multiMode\": $(get_grpc_multimode ${xray_grpc_mode})
				}"
			;;
		esac

		local xray_port=$(dbus get ssconf_basic_port_${nu})
		local xray_uuid=$(dbus get ssconf_basic_xray_uuid_${nu})
		local xray_prot=$(dbus get ssconf_basic_xray_prot_${nu})
		local xray_alterid=$(dbus get ssconf_basic_xray_alterid_${nu})
		local xray_encryption=$(dbus get ssconf_basic_xray_encryption_${nu})
		[ -z "${xray_prot}" ] && xray_prot="vless"
		[ -z "${xray_alterid}" ] && xray_alterid="0"

		# outbounds area
		cat >>${TMP2}/conf/${nu}_outbounds.json <<-EOF
			{
			"outbounds": [
				{
					"tag": "proxy${nu}",
					"protocol": "${xray_prot}",
					"settings": {
						"vnext": [
							{
								"address": "${_server_ip}",
								"port": ${xray_port},
								"users": [
									{
										"id": "${xray_uuid}"
										,"alterId": ${xray_alterid}
										,"security": "auto"
										,"encryption": "${xray_encryption}"
										,"flow": $(get_value_null ${xray_flow})
									}
								]
							}
						]
					},
					"streamSettings": {
						"network": "${xray_network}"
						,"security": "${xray_network_security}"
						,"tlsSettings": $tls
						,"xtlsSettings": $xtls
						,"realitySettings": $reali
						,"tcpSettings": $tcp
						,"kcpSettings": $kcp
						,"wsSettings": $ws
						,"httpSettings": $h2
						,"quicSettings": $qc
						,"grpcSettings": $gr
						,"sockopt": {"tcpFastOpen": $(get_function_switch ${ss_basic_tfo})}
					},
					"mux": {"enabled": false}
				}
			]
			}
		EOF

		# delete all null value
		# jq 'del(..|nulls)' ${TMP2}/conf/${nu}_outbounds.json | run sponge ${TMP2}/conf/${nu}_outbounds.json
		sed -i '/null/d' ${TMP2}/conf/${nu}_outbounds.json 2>/dev/null
		if [ "${xray_prot}" == "vless" ];then
			sed -i '/alterId/d' ${TMP2}/conf/${nu}_outbounds.json 2>/dev/null
		fi
		if [ "${LINUX_VER}" == "26" ]; then
			sed -i '/tcpFastOpen/d' ${TMP2}/conf/${nu}_outbounds.json 2>/dev/null
		fi
	else
		dbus get ssconf_basic_xray_json_${nu} | base64_decode >${TMP2}/xray_user.json
		local OB=$(cat ${TMP2}/xray_user.json | run jq .outbound)
		local OBS=$(cat ${TMP2}/xray_user.json | run jq .outbounds)

		# 兼容旧格式：outbound
		if [ "$OB" != "null" ]; then
			OUTBOUNDS=$(cat ${TMP2}/xray_user.json | run jq .outbound)
		fi
		
		# 新格式：outbound[]
		if [ "$OBS" != "null" ]; then
			OUTBOUNDS=$(cat ${TMP2}/xray_user.json | run jq .outbounds[0])
		fi
		echo "{}" | run jq --argjson args "$OUTBOUNDS" '. + {outbounds: [$args]}' >${TMP2}/conf/${nu}_outbounds.json
	fi

	# inbounds
	local socks5_port=$(get_rand_port)
	echo "export socks5_port_${nu}=${socks5_port}" >> ${TMP2}/socsk5_ports.txt
	cat >>${TMP2}/conf/${nu}_inbounds.json <<-EOF
		{
		  "inbounds": [
		    {
		      "port": ${socks5_port},
		      "protocol": "socks",
		      "settings": {
		        "auth": "noauth",
		        "udp": true
		      },
		      "tag": "socks${nu}"
		    }
		  ]
		}
	EOF

	# routing
	cat >>${TMP2}/conf/${nu}_routing.json <<-EOF
		{
		  "routing": {
		    "rules": [
		      {
		        "type": "field",
		        "inboundTag": ["socks${nu}"],
		        "outboundTag": "proxy${nu}"
		      }
		    ]
		  }
		}
	EOF
}

creat_trojan_json(){
	local nu=$1
	local trojan_server=$(dbus get ssconf_basic_server_${nu})
	local trojan_port=$(dbus get ssconf_basic_port_${nu})
	local trojan_uuid=$(dbus get ssconf_basic_trojan_uuid_${nu})
	local trojan_sni=$(dbus get ssconf_basic_trojan_sni_${nu})
	local trojan_ai=$(dbus get ssconf_basic_trojan_ai_${nu})
	local trojan_ai_global=$(dbus get ss_basic_tjai${nu})
	if [ "${trojan_ai_global}" == "1" ];then
		local trojan_ai="1"
	fi
	local trojan_tfo=$(dbus get ssconf_basic_trojan_tfo_${nu})
	local _server_ip=$(_get_server_ip ${trojan_server})
	if [ -z "${_server_ip}" ];then
		_server_ip=${trojan_server}
	fi

	
	# outbounds area
	cat >>${TMP2}/conf/${nu}_outbounds.json <<-EOF
		{
		"outbounds": [
			{
				"tag": "proxy${nu}",
				"protocol": "trojan",
				"settings": {
					"servers": [{
					"address": "${_server_ip}",
					"port": ${trojan_port},
					"password": "${trojan_uuid}"
					}]
				},
				"streamSettings": {
					"network": "tcp",
					"security": "tls",
					"tlsSettings": {
						"serverName": $(get_value_null ${trojan_sni}),
						"allowInsecure": $(get_function_switch ${trojan_ai})
    				}
    				,"sockopt": {"tcpFastOpen": $(get_function_switch ${trojan_tfo})}
    			}
  			}
  		]
  		}
	EOF
	if [ "${LINUX_VER}" == "26" ]; then
		sed -i '/tcpFastOpen/d' ${TMP2}/conf/${nu}_outbounds.json
	fi
	# inbounds
	local socks5_port=$(get_rand_port)
	echo "export socks5_port_${nu}=${socks5_port}" >> ${TMP2}/socsk5_ports.txt
	cat >>${TMP2}/conf/${nu}_inbounds.json <<-EOF
		{
		  "inbounds": [
		    {
		      "port": ${socks5_port},
		      "protocol": "socks",
		      "settings": {
		        "auth": "noauth",
		        "udp": true
		      },
		      "tag": "socks${nu}"
		    }
		  ]
		}
	EOF
	# routing
	cat >>${TMP2}/conf/${nu}_routing.json <<-EOF
		{
		  "routing": {
		    "rules": [
		      {
		        "type": "field",
		        "inboundTag": ["socks${nu}"],
		        "outboundTag": "proxy${nu}"
		      }
		    ]
		  }
		}
	EOF
}

creat_hy2_yaml(){
	local nu=$1
	local mark=$2
	if [ -z "$(dbus get ssconf_basic_hy2_sni_${nu})" ];then
		__valid_ip_silent "$(dbus get ssconf_basic_hy2_server_${nu})"
		if [ "$?" != "0" ];then
			# not ip, should be a domain
			local hy2_sni=$(dbus get ssconf_basic_hy2_server_${nu})
		else
			local hy2_sni=""
		fi
	else
		local hy2_sni="$(dbus get ssconf_basic_hy2_sni_${nu})"
	fi

	local _server_ip=$(_get_server_ip $(dbus get ssconf_basic_hy2_server_${nu}))
	if [ -z "${_server_ip}" ];then
		# use domain
		_server_ip=$(dbus get ssconf_basic_hy2_server_${nu})
		#echo -en "${nu}:\t解析失败！\n"
		#continue
	fi

	cat >> ${TMP2}/conf_${mark}/${nu}.yaml <<-EOF
		server: ${_server_ip}:$(dbus get ssconf_basic_hy2_port_${nu})
		
		auth: $(dbus get ssconf_basic_hy2_pass_${nu})

		tls:
		  sni: ${hy2_sni}
		  insecure: $(get_function_switch $(dbus get ssconf_basic_hy2_ai_${nu}))
		
		fastOpen: $(get_function_switch $(dbus get ssconf_basic_hy2_tfo_${nu}))
		
	EOF
	
	if [ -n "$(dbus get ssconf_basic_hy2_up_${nu})" -o -n "$(dbus get ssconf_basic_hy2_dl_${nu})" ];then
		cat >> ${TMP2}/conf_${mark}/${nu}.yaml <<-EOF
			bandwidth: 
			  up: $(dbus get ssconf_basic_hy2_up_${nu}) mbps
			  down: $(dbus get ssconf_basic_hy2_dl_${nu}) mbps
			
		EOF
	fi

	if [ "$(dbus get ssconf_basic_hy2_obfs_${nu})" == "1" -a -n "$(dbus get ssconf_basic_hy2_obfs_pass_${nu})" ];then
		cat >> ${TMP2}/conf_${mark}/${nu}.yaml <<-EOF
			obfs:
			  type: salamander
			  salamander:
			    password: "$(dbus get ssconf_basic_hy2_obfs_pass_${nu})"
			
		EOF
	fi

	local socks5_port=$(get_rand_port)
	echo "export socks5_port_${nu}=${socks5_port}" >> ${TMP2}/socsk5_ports.txt
	cat >> ${TMP2}/conf_${mark}/${nu}.yaml <<-EOF
		transport:
		  udp:
		    hopInterval: 30s
		
		socks5:
		  listen: 127.0.0.1:${socks5_port}
	EOF
}

curl_test(){
	local nu=$1
	local port=$2

	# curl-fancyss -o /dev/null -s -I -x socks5h://127.0.0.1:23456 --connect-timeout 5 -m 10 -w "%{time_total}|%{response_code}\n" http://www.google.com.tw
	
	# test multiple time and get the best one
	# echo ${TMP2}/curl-webtest -o /dev/null -s -I -x socks5h://127.0.0.1:${port} --connect-timeout 5 -m 10 -w "%{time_total}|%{response_code}\n" ${ss_basic_wt_furl} >> ${TMP2}/curl_test_log.txt
	local ret=$(run ${TMP2}/curl-webtest -o /dev/null -s -I -x socks5h://127.0.0.1:${port} --connect-timeout 5 -m 10 -w "%{time_total}|%{response_code}\n" ${ss_basic_wt_furl} 2>/dev/null)
	usleep 250000
	local ret=${ret}@$(run ${TMP2}/curl-webtest -o /dev/null -s -I -x socks5h://127.0.0.1:${port} --connect-timeout 5 -m 10 -w "%{time_total}|%{response_code}\n" ${ss_basic_wt_furl} 2>/dev/null)
	usleep 250000
	local ret=${ret}@$(run ${TMP2}/curl-webtest -o /dev/null -s -I -x socks5h://127.0.0.1:${port} --connect-timeout 5 -m 10 -w "%{time_total}|%{response_code}\n" ${ss_basic_wt_furl} 2>/dev/null)
	local ret=$(echo ${ret} | sed 's/@/\n/g' | sort -n | head -n1)
	local _match=$(echo "${ret}"|grep -E "\|")
	if [ -z ${_match} ];then
		echo -en "${nu}>failed\n" >>${TMP2}/results/${nu}.txt
	else
		local ret_time=$(echo $ret | awk -F "|" '{printf "%.0f\n", $1 * 1000}')
		local ret_code=$(echo $ret | awk -F "|" '{print $2}')

		# 5. show result
		if [ "${ret_code}" == "200" -o "${ret_code}" == "204" ];then
			echo -en "${nu}>${ret_time}\n" >>${TMP2}/results/${nu}.txt
		else
			echo -en "${nu}>failed\n" >>${TMP2}/results/${nu}.txt
		fi
	fi
}

_get_server_ip() {
	local SERVER_IP
	local domain1=$(echo "$1" | grep -E "^https://|^http://|/")
	local domain2=$(echo "$1" | grep -E "\.")
	if [ -n "${domain1}" -o -z "${domain2}" ]; then
		echo "$1 不是域名也不是ip" >>${TMP2}/webtest_log.txt
		echo ""
		return 2
	fi

	SERVER_IP=$(__valid_ip $1)
	if [ -n "${SERVER_IP}" ]; then
		echo "$1 已经是ip，跳过解析！" >>${TMP2}/webtest_log.txt
		echo $SERVER_IP
		return 0
	fi

	local count=0
	local current=${ss_basic_lastru}
	if [ -z "${current}" ];then
		local current=$(shuf -i 1-18 -n 1)
	fi
	if [ ${current} -lt 1 -o ${current} -gt 18 ];then
		current=1
	fi
	# 只解析一轮
	until [ ${count} -eq 18 ]; do
		#echo "$1 选取DNS服务器$(__get_server_resolver ${current})，用于域名解析" >>${TMP2}/webtest_log.txt
		
		SERVER_IP=$(run dnsclient -p 53 -t 2 -i 1 @$(__get_server_resolver ${current}) $1 2>/dev/null|grep -E "^IP"|head -n1|awk '{print $2}')
		SERVER_IP=$(__valid_ip ${SERVER_IP})
		if [ -n "${SERVER_IP}" -a "${SERVER_IP}" != "127.0.0.1" ]; then
			dbus set ss_basic_lastru=${current}
			break
		fi
		
		let current++
		if [ ${current} -gt 8 -a ${current} -lt 11 ];then
			current=11
		fi
		if [ ${current} -lt 1 -o ${current} -gt 18 ];then
			current=1
		fi
		
		let count++
	done

	# resolve failed
	if [ -z "${SERVER_IP}" ]; then
		#echo "$1 域名解析失败！" >>${TMP2}/webtest_log.txt
		echo ""
		return 1
	fi

	# resolve failed
	if [ "${SERVER_IP}" == "127.0.0.1" ]; then
		#echo "$1 解析结果为127.0.0.1，域名解析失败！" >>${TMP2}/webtest_log.txt
		echo ""
		return 1
	fi
	
	# success resolved
	#echo "$1 域名解析成功，解析结果：${SERVER_IP}" >>${TMP2}/webtest_log.txt
	echo $SERVER_IP
	return 0
}

__get_server_resolver() {
	local idx=$1
	local res
	# tcp/udp servers
	# ------------------ 国内 -------------------
	# 阿里dns
	[ "${idx}" == "1" ] && res="223.5.5.5"
	# DNSPod dns
	[ "${idx}" == "2" ] && res="119.29.29.29"
	# 114 dns
	[ "${idx}" == "3" ] && res="114.114.114.114"
	# oneDNS 拦截版
	[ "${idx}" == "4" ] && res="52.80.66.66"
	# 360安全DNS 电信/铁通/移动
	[ "${idx}" == "5" ] && res="218.30.118.6"
	# 360安全DNS 联通
	[ "${idx}" == "6" ] && res="123.125.81.6"
	# 清华大学TUNA DNS
	[ "${idx}" == "7" ] && res="101.6.6.6"
	# 百度DNS
	[ "${idx}" == "8" ] && res="180.76.76.76"
	# ------------------ 国外 -------------------
	# Google DNS
	[ "${idx}" == "11" ] && res="8.8.8.8"
	# Cloudflare DNS
	[ "${idx}" == "12" ] && res="1.1.1.1"
	# Quad9 Secured 
	[ "${idx}" == "13" ] && res="9.9.9.11"
	# OpenDNS
	[ "${idx}" == "14" ] && res="208.67.222.222"
	# DNS.SB
	[ "${idx}" == "15" ] && res="185.222.222.222"
	# AdGuard Default servers
	[ "${idx}" == "16" ] && res="94.140.14.14"
	# Quad 101 (TaiWan Province)
	[ "${idx}" == "17" ] && res="101.101.101.101"
	# CleanBrowsing
	[ "${idx}" == "18" ] && res="185.228.168.9"
	echo ${res}
}

wait_program(){
	local BINNAME=$1
	local PID1
	local i=40
	until [ -n "${PID1}" ]; do
		usleep 250000
		i=$(($i - 1))
		PID1=$(pidof ${BINNAME})
		if [ "$i" -lt 1 ]; then
			return 1
		fi
	done
	usleep 500000
}

wait_program2(){
	local BINNAME=$1
	local LOGFILE=$2
	local CONTENT=$3
	local MATCH
	local PID1
	# wait for 4s
	local i=16
	# until [ -n "${PID1}" ]; do
	# 	usleep 250000
	# 	i=$(($i - 1))
	# 	PID1=$(pidof ${BINNAME})
	# 	if [ "$i" -lt 1 ]; then
	# 		return 1
	# 	fi
	# done
	
	until [ -n "${MATCH}" ]; do
		usleep 250000
		i=$(($i - 1))
		local MATCH=$(cat $LOGFILE 2>/dev/null | grep -w $CONTENT)
		if [ "$i" -lt 1 ]; then
			return 1
		fi
	done
	usleep 500000
	return 0
}

get_path_empty() {
	if [ -n "$1" ]; then
		echo [\"$1\"]
	else
		echo [\"/\"]
	fi
}


get_host_empty() {
	if [ -n "$1" ]; then
		echo [\"$1\"]
	else
		echo [\"\"]
	fi
}

get_function_switch() {
	case "$1" in
	1)
		echo "true"
		;;
	0 | *)
		echo "false"
		;;
	esac
}

get_grpc_multimode(){
	case "$1" in
	multi)
		echo true
		;;
	gun|*)
		echo false
		;;
	esac
}

get_ws_header() {
	if [ -n "$1" ]; then
		echo {\"Host\": \"$1\"}
	else
		echo null
	fi
}

get_host() {
	if [ -n "$1" ]; then
		echo [\"$1\"]
	else
		echo null
	fi
}


get_value_null(){
	if [ -n "$1" ]; then
		echo \"$1\"
	else
		echo null
	fi
}

get_value_empty(){
	if [ -n "$1" ]; then
		echo \"$1\"
	else
		echo \"\"
	fi
}

clean_webtest(){
	# 当用户手动点击web test按钮的时候，不论是否有正在进行的任务，不论是否在在时限内，强制开始webtest
	# 1. killall program
	killall wt-ss >/dev/null 2>&1
	killall wt-ss-local >/dev/null 2>&1
	killall wt-obfs >/dev/null 2>&1
	killall wt-rss-local >/dev/null 2>&1
	killall wt-v2ray >/dev/null 2>&1
	killall wt-xray >/dev/null 2>&1
	killall wt-trojan >/dev/null 2>&1
	killall wt-naive >/dev/null 2>&1
	killall wt-tuic >/dev/null 2>&1
	killall wt-hy2 >/dev/null 2>&1
	killall curl-fancyss >/dev/null 2>&1
	killall curl-webtest >/dev/null 2>&1

	# 2. kill all other ss_webtest.sh
	local current_pid=$$
	local ss_webtest_pids=$(ps|grep -E "ss_webtest\.sh"|awk '{print $1}'|grep -v ${current_pid})
	if [ -n "${ss_webtest_pids}" ];then
		for ss_webtest_pid in ${ss_webtest_pids}
		do
			kill -9 ${ss_webtest_pid} >/dev/null 2>&1
		done
	fi

	# 3. remove lock file if exist
	rm -rf /tmp/webtest.lock >/dev/null 2>&1

	# 4. remove webtest result file
	rm -rf /tmp/upload/webtest.txt
	rm -rf ${TMP2}/*
}

set_latency_job() {
	if [ "${ss_basic_lt_cru_opts}" == "0" ]; then
		echo_date "定时测试节点延迟未开启!"
		sed -i '/sslatencyjob/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	elif [ "${ss_basic_lt_cru_opts}" == "1" ]; then
		echo_date "设置每隔${ss_basic_lt_cru_time}分钟对所有节点进行web延迟检测..."
		sed -i '/sslatencyjob/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
		cru a sslatencyjob "*/${ss_basic_lt_cru_time} * * * * /koolshare/scripts/ss_webtest.sh 2"
	fi
}
# ----------------------------------------------------------------------

case $1 in
2)
	# start webtest by cron
	clean_webtest
	start_webtest
	;;
3)
	set_latency_job
	;;
esac


case $2 in
web_webtest)
	# 当用户进入插件，插件列表渲染好后开始调用本脚本进行webtest
	webtest_web
	;;
manual_webtest)
	clean_webtest
	http_response $1
	;;
close_latency_test)
	http_response $1
	clean_webtest
	dbus remove ss_basic_webtest_ts
	;;
0)
	http_response $1
	set_latency_job
	;;
1)
	# webtest foreign url changed
	http_response $1
	if [ "${ss_failover_enable}" == "1" ];then
		echo "${LOGTIME1} fancyss：切换国外web延迟检测地址为：${ss_basic_wt_furl}" >>/tmp/upload/ssf_status.txt
	fi
	set_latency_job
	;;
2)
	# webtest china url changed
	http_response $1
	if [ "${ss_failover_enable}" == "1" ];then
		echo "${LOGTIME1} fancyss：切换国内web延迟检测地址为：${ss_basic_wt_curl}" >>/tmp/upload/ssc_status.txt
	fi
	set_latency_job
	;;
3)
	# webtest foreign + china url changed
	http_response $1
	if [ "${ss_failover_enable}" == "1" ];then
		echo "${LOGTIME1} fancyss：切换国外web延迟检测地址为：${ss_basic_wt_furl}" >>/tmp/upload/ssf_status.txt
		echo "${LOGTIME1} fancyss：切换国内web延迟检测地址为：${ss_basic_wt_curl}" >>/tmp/upload/ssc_status.txt
	fi
	set_latency_job
	;;
esac