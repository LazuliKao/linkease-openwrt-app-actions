#!/bin/sh
# Author jjm2473@gmail.com

ACTION="${1}"
shift 1

. /usr/lib/shadowrt/handoff.sh

find_network_device() {
	local name="$1"
	local section

	uci show network | grep -E "^network\.[^\.]+\.name='$name'$" | sed "s/\.name='$name'$//" | while read section; do
		[ "device" = "$(uci get "$section")" ] && echo "$section"
	done
}

ensure_host_network() {
	local id="$1"
	local section="$(find_network_device "$SHADOWRT_HOST_BRIDGE" | head -n1)"
	local changed=0

	if [ -n "$section" ]; then
		[ "bridge" = "$(uci get "$section.type")" ] || {
			echo "host device $SHADOWRT_HOST_BRIDGE is not a bridge!" >&2
			return 1
		}
	else
		section="$(uci add network device)" || return 1
		uci set "network.$section.name=$SHADOWRT_HOST_BRIDGE"
		uci set "network.$section.type=bridge"
		changed=1
	fi

	if uci get "network.$id" >/dev/null 2>&1; then
		[ "interface" = "$(uci get "network.$id")" ] && \
			[ "none" = "$(uci get "network.$id.proto")" ] && \
			[ "$SHADOWRT_HOST_BRIDGE" = "$(uci get "network.$id.device")" ] || {
			echo "host network $id conflicts with bridge $SHADOWRT_HOST_BRIDGE!" >&2
			return 1
		}
	else
		uci set "network.$id=interface"
		uci set "network.$id.proto=none"
		uci set "network.$id.device=$SHADOWRT_HOST_BRIDGE"
		changed=1
	fi

	uci get "$section.ports" | grep -wq "$SHADOWRT_HOST_VETH" || {
		uci add_list "$section.ports=$SHADOWRT_HOST_VETH"
		changed=1
	}
	[ -d "/sys/class/net/$SHADOWRT_HOST_BRIDGE" ] || changed=1
	if [ "$changed" != 0 ]; then
		uci commit network || return 1
		/etc/init.d/network reload || return 1
	fi
	/sbin/ifup "$id" || return 1
}

ensure_handoff_network() {
	/etc/init.d/shadowrt-handoff start || return 1
	docker network inspect "$SHADOWRT_DOCKER_NETWORK" -f '{{.Name}}' >/dev/null 2>&1
}

migrate_legacy_network() {
	local legacy="shadowrt-ap-$SHADOWRT_HOST_BRIDGE"
	local bridge containers

	[ "$legacy" = "$SHADOWRT_DOCKER_NETWORK" ] && return 0
	docker network inspect "$legacy" -f '{{.Name}}' >/dev/null 2>&1 || return 0
	bridge="$(docker network inspect "$legacy" -f '{{index .Options "com.docker.network.bridge.name"}}')"
	[ "$bridge" = "$SHADOWRT_HOST_BRIDGE" ] || return 0
	containers="$(docker network inspect "$legacy" -f '{{range $id, $container := .Containers}}{{$container.Name}} {{end}}')"
	[ -z "$containers" ] || {
		echo "legacy network $legacy is still used by: $containers" >&2
		return 1
	}
	docker network rm "$legacy"
}

do_install() {
	local id="`uci get shadowrt.@instance[0].id 2>/dev/null`"
	local data="`uci get shadowrt.@instance[0].data 2>/dev/null`"
	local mnt="`uci get shadowrt.@instance[0].mnt 2>/dev/null`"
	local dind="`uci get shadowrt.@instance[0].dind 2>/dev/null`"
	local proto=`uci get shadowrt.@instance[0].proto 2>/dev/null`
	local address=`uci get shadowrt.@instance[0].address 2>/dev/null`
	local gateway=`uci get shadowrt.@instance[0].gateway 2>/dev/null`
	local dns="`uci get shadowrt.@instance[0].dns 2>/dev/null`"
	local dhcp_server=`uci get shadowrt.@instance[0].dhcp_server 2>/dev/null`
	local wan_ipv4_input=`uci get shadowrt.@instance[0].wan_ipv4_input 2>/dev/null`
	local ports="`uci get shadowrt.@instance[0].ports 2>/dev/null`"

	local lan_address=`uci get shadowrt.@instance[0].lan_address 2>/dev/null`
	local lan_ipv6_mode=`uci get shadowrt.@instance[0].lan_ipv6_mode 2>/dev/null`
	local wan6_mode=`uci get shadowrt.@instance[0].wan6_mode 2>/dev/null`
	local nat6=`uci get shadowrt.@instance[0].nat6 2>/dev/null`
	[ -n "$lan_ipv6_mode" ] || lan_ipv6_mode=server
	[ -n "$wan6_mode" ] || wan6_mode=dhcpv6

	if [ -z "$data" ]; then
		echo "data path is empty!" >&2
		exit 1
	fi

	[ -s /rom/etc/openwrt_release ] || {
		echo "/rom is not a openwrt rootfs!" >&2
		exit 1
	}

	if [ "$proto" = "static" -o "$proto" = "dual_static" ]; then
		if [ -z "$address" ]; then
			echo "static WAN requires address!" >&2
			exit 1
		fi
	fi

	if [ "$proto" = "dual" -o "$proto" = "dual_static" ]; then
		if [ -z "$lan_address" ]; then
			echo "dual mode requires LAN address!" >&2
			exit 1
		fi
		case "$lan_ipv6_mode" in disabled|server|relay) ;; *) echo "invalid LAN IPv6 mode!" >&2; exit 1 ;; esac
		case "$wan6_mode" in disabled|dhcpv6|relay) ;; *) echo "invalid WAN6 mode!" >&2; exit 1 ;; esac
		[ "$lan_ipv6_mode" != relay -o "$wan6_mode" = relay ] || { echo "LAN IPv6 relay requires WAN6 relay master!" >&2; exit 1; }
		shadowrt_handoff_names "$id" || exit 1
		ensure_host_network "$id" || exit 1
		ensure_handoff_network || {
			echo "create shadowrt LAN handoff failed!" >&2
			exit 1
		}
	fi

	/etc/init.d/docker-lan start || {
		echo "create docker-lan bridge failed!" >&2
		exit 1
	}

	local alpine_image="alpine:3.22.2"
	if ! docker image inspect -f '{}' "$alpine_image" >/dev/null 2>&1; then
		echo "pulling alpine image $alpine_image ..."
		docker pull "$alpine_image" || exit 1
	fi

	if [ -d "$data/$id" ]; then
		echo "WARNING: $data/$id already exists, may use old data." >&2
	fi

	local config="{\"id\":\"$id\",\"data\":\"$data\",\"mnt\":\"$mnt\",\"dind\":\"$dind\",\"proto\":\"$proto\",\"address\":\"$address\",\"gateway\":\"$gateway\",\"dns\":\"$dns\",\"lan_address\":\"$lan_address\",\"lan_ipv6_mode\":\"$lan_ipv6_mode\",\"wan6_mode\":\"$wan6_mode\",\"nat6\":\"$nat6\",\"wan_ipv4_input\":\"$wan_ipv4_input\",\"dhcp_server\":\"$dhcp_server\",\"ports\":\"$ports\"}"

	local cmd="docker run --restart=unless-stopped -d \
		--stop-signal SIGINT \
		--stop-timeout 30 \
		--security-opt seccomp=unconfined \
		--security-opt apparmor=unconfined \
		--cap-add=SYS_ADMIN \
		--cap-add=SYS_CHROOT \
		--cap-add=LEASE \
		--cap-add=SETGID \
		--cap-add=SETUID \
		--cap-add=NET_ADMIN \
		--cap-add=NET_RAW \
		--cap-add=NET_BIND_SERVICE \
		--network docker-lan \
		-v /usr/share/shadowrt/container:/shadowrt:ro \
		--entrypoint /shadowrt/entrypoint.sh \
		-v /dev/net:/dev/net \
		--device /dev/fuse:/dev/fuse \
		-v /rom:/rom:ro \
		--label creator=shadowrt \
		--name '$id' \
		--hostname '$id' \
		--label 'com.shadowrt.config=$config' \
		-v '$data/$id/overlay:/overlay:rw' "
	if [ "$proto" = "dual" -o "$proto" = "dual_static" ]; then
		cmd="$cmd --label com.shadowrt.network-topology=veth-handoff"
	fi

	if [ "$dind" = "1" -o "$dind" = "on" ]; then
		cmd="$cmd -e DIND=on"
	else
		cmd="$cmd --cap-drop=MKNOD"
	fi

	[ -n "$proto" ] && cmd="$cmd -e IP_PROTO=$proto"
	if [ "$proto" = "static" ]; then
		[ -n "$address" ] && cmd="$cmd -e IP_ADDRESS=$address"
		[ -n "$gateway" ] && cmd="$cmd -e IP_GATEWAY=$gateway"
		[ -n "$dns" ] && cmd="$cmd -e 'IP_DNS=$dns'"
	fi
	if [ "$proto" = "dual" -o "$proto" = "dual_static" ]; then
		cmd="$cmd -e 'LAN_ADDRESS=$lan_address'"
		cmd="$cmd -e LAN_IPV6_MODE=$lan_ipv6_mode -e WAN6_MODE=$wan6_mode"
		[ "$nat6" = "1" -o "$nat6" = "on" ] && cmd="$cmd -e NAT6=on"
	fi
	if [ "$proto" = "dual_static" ]; then
		cmd="$cmd -e 'WAN_ADDRESS=$address'"
		[ -n "$gateway" ] && cmd="$cmd -e WAN_GATEWAY=$gateway"
		[ -n "$dns" ] && cmd="$cmd -e 'WAN_DNS=$dns'"
	fi
	[ "$proto" = "dual" -a \( "$wan_ipv4_input" = "1" -o "$wan_ipv4_input" = "on" \) ] && cmd="$cmd -e WAN_IPV4_INPUT=on"
	[ "$dhcp_server" = "1" -o "$dhcp_server" = "on" ] && cmd="$cmd -e DHCP_SERVER=on"
	if [ -n "$ports" ]; then
		for p in $ports; do
			cmd="$cmd -p $p:$p"
		done
	fi
	if [ "$proto" != "dual" -a -n "$dns" ]; then
		for d in $dns; do
			cmd="$cmd --dns $d"
		done
	fi

	local tz="`uci get system.@system[0].zonename | sed 's/ /_/g'`"
	[ -z "$tz" ] || cmd="$cmd -e TZ=$tz"

	if [ "$mnt" = "1" -o "$mnt" = "on" ]; then
		cmd="$cmd -v /mnt:/mnt"
		mountpoint -q /mnt && cmd="$cmd:rshared"
	fi
	cmd="$cmd $alpine_image"

	echo "stopping existing container..."
	docker stop "$id" >/dev/null 2>&1
	docker rm -f "$id"
	if [ "$proto" = "dual" -o "$proto" = "dual_static" ]; then
		migrate_legacy_network || return 1
	fi

	echo "starting shadowrt instance $id..."
	echo "$cmd"
	eval "$cmd" || return 1
	if [ "$proto" = "dual" -o "$proto" = "dual_static" ]; then
		docker network connect "$SHADOWRT_DOCKER_NETWORK" "$id" || {
			echo "attach LAN bridge failed!" >&2
			docker rm -f "$id" >/dev/null 2>&1
			return 1
		}
	fi

}

do_ls() {
	local name state ip wan_ip

	echo "["
	docker ps -a -f 'label=creator=shadowrt' --format '{{.Names}} {{.State}}' | sort -n | while read name state; do
		ip=
		wan_ip=
		if [ "$state" = "running" ]; then
			ip=`docker exec "$name" ip addr show dev br-lan | grep -m1 'inet ' | head -1 | sed -nE 's#.*inet ([0-9\.]+)/([0-9]*) .*#\1#p'`
			wan_ip=`docker exec "$name" ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address'`
			if [ -z "$ip" ]; then
				docker exec "$name" test -e /etc/openwrt_release -a ! -e /rom/note || state="starting"
			fi
		fi
		echo '{"name":"'"$name"'","status":"'"$state"'","ip":"'"$ip"'","wan_ip":"'"$wan_ip"'"},'
		#docker container inspect -f '{"name":"'"$name"'","status":"'"$state"'","config":{{index .Config.Labels "com.shadowrt.config"}},"ip":"'"$ip"'"},' "$name"
	done | head -c -2
	echo ""
	echo "]"
}

do_clone() {
	local config_json="`docker container inspect -f '{{index .Config.Labels "com.shadowrt.config"}}' "$1"`"
	[ -z "$config_json" ] && {
		echo "container $1 not found!" >&2
		return 1
	}
	{
		echo "delete shadowrt.@instance[0]"
		echo "add shadowrt instance"
		echo "$config_json" | jsonfilter -e 'id=$.id' \
			-e 'data=$.data' \
			-e 'mnt=$.mnt' \
			-e 'dind=$.dind' \
			-e 'proto=$.proto' \
			-e 'address=$.address' \
			-e 'gateway=$.gateway' \
			-e 'dns=$.dns' \
			-e 'lan_address=$.lan_address' \
			-e 'lan_ipv6_mode=$.lan_ipv6_mode' \
			-e 'wan6_mode=$.wan6_mode' \
			-e 'nat6=$.nat6' \
			-e 'wan_ipv4_input=$.wan_ipv4_input' \
			-e 'dhcp_server=$.dhcp_server' \
			-e 'ports=$.ports' | sed -e 's/; /\n/g' | sed -e 's/^export /set shadowrt.@instance[0]./g'
		echo "commit shadowrt"
	} | uci batch

	return 0
}

do_reset_network() {
	local name="$1"
	local running=false
	local shell

	docker exec "$name" test -e /etc/openwrt_release -a ! -e /rom/note >/dev/null 2>&1 && running=true
	if $running; then
		shell="exec docker exec -i -w / '$name' /bin/sh"
	else
		docker stop "$name" >/dev/null 2>&1
		local data="`docker container inspect -f '{{index .Config.Labels "com.shadowrt.config"}}' "$name" | jsonfilter -e '$.data'`"
		local dir="$data/$name/overlay/upper"
		[ -d "$dir" ] || return 0
		shell="cd '$dir' && exec /bin/sh"
	fi
	{
		cat <<-EOF
			for f in etc/config/network etc/board.json; do
				rm -f "\$f"
			done
		EOF
		if $running; then
			cat <<-EOF
				/bin/board_detect
				/bin/config_generate
				/bin/sh -c ". /rom/etc/uci-defaults/zzz-dockerenv"
				/bin/sh -c '. /rom/etc/uci-defaults/12_network-generate-ula'
				/bin/sh -c '. /rom/etc/uci-defaults/14_network-generate-duid'
				/etc/init.d/network restart
				sleep 2
			EOF
		else
			echo 'rm -f etc/uci-defaults/zzz-dockerenv etc/uci-defaults/12_network-generate-ula etc/uci-defaults/14_network-generate-duid'
		fi
	} | sh -c "$shell"
}

check_all_ready() {
	local names="$1"
	local name
	local ret=0
	for name in $names; do
		if ! docker exec "$name" test -e /etc/openwrt_release -a ! -e /rom/note; then
			ret=1
			break
		fi
	done
	return $ret
}

usage() {
	echo "usage: $0 sub-command"
	echo "where sub-command is one of:"
	echo "      install                    Install/Replace a instance"
	echo "      ls                         List all instances"
	echo "      rm/start/stop/restart {ID} Remove/Start/Stop/Restart the instance"
	echo "      clone {ID}                 Clone an existing instance to uci"
	echo "      rmd {ID}                   Remove an existing instance and its data"
	echo "      reset_network {ID}         Reset network configuration inside the instance"
	echo "      status                     Dummy status for taskd"

}

case "${ACTION}" in
	"install")
		do_install
	;;
	"rm" | "rmd")
		if [ -n "$1" ]; then
			docker stop "$1" >/dev/null 2>&1
			if [ "$ACTION" = "rmd" ]; then
				data="`docker container inspect -f '{{index .Config.Labels "com.shadowrt.config"}}' "$1" | jsonfilter -e '$.data'`"
				[ -n "$data" ] && rm -rf "$data/$1"
			fi
			docker rm -f "$1"
		fi
	;;
	"reset_network")
		if [ -n "$1" ]; then
			do_reset_network "$1"
		fi
	;;
	"start" | "stop" | "restart")
		if [ -n "$1" ]; then
			docker "${ACTION}" $1
			if [ "$ACTION" = "start" -o "$ACTION" = "restart" ]; then
				sleep 2
				for i in $(seq 1 5); do
					check_all_ready "$1" && break
					sleep 1
				done
			fi
		fi
	;;
	"clone")
		if [ -n "$1" ]; then
			do_clone "$1" || exit 1
		fi
	;;
	"status")
		# hack, return empty string, so lib-taskd thinks container is not installed
		exit 0
	;;
	"ls")
		do_ls
	;;
	*)
		usage
		exit 1
	;;
esac
