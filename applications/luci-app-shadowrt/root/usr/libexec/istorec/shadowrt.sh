#!/bin/sh
# Author jjm2473@gmail.com

ACTION="${1}"
shift 1

find_network_device() {
	local name="$1"
	local section

	uci show network | grep -E "^network\.[^\.]+\.name='$name'$" | sed "s/\.name='$name'$//" | while read section; do
		[ "device" = "$(uci get "$section")" ] && echo "$section"
	done
}

ensure_ap_bridge() {
	local name="$1"
	local section="$(find_network_device "$name" | head -n1)"

	if [ -n "$section" ]; then
		[ "bridge" = "$(uci get "$section.type")" ] || {
			echo "host device $name is not a bridge!" >&2
			return 1
		}
		return 0
	fi

	section="$(uci add network device)" || return 1
	uci set "network.$section.name=$name"
	uci set "network.$section.type=bridge"
	uci commit network || return 1
	/etc/init.d/network reload
}

ensure_ap_interface() {
	local bridge="$1"
	local network="${bridge#br-}"

	[ "$network" != "$bridge" ] || {
		echo "dual mode bridge name must start with br-!" >&2
		return 1
	}
	if uci get "network.$network" >/dev/null 2>&1; then
		[ "interface" = "$(uci get "network.$network")" ] && \
			[ "none" = "$(uci get "network.$network.proto")" ] && \
			[ "$bridge" = "$(uci get "network.$network.device")" ] || {
			echo "host network $network conflicts with bridge $bridge!" >&2
			return 1
		}
		return 0
	fi

	uci set "network.$network=interface"
	uci set "network.$network.proto=none"
	uci set "network.$network.device=$bridge"
	uci commit network || return 1
	/etc/init.d/network reload
}

ensure_ap_network() {
	local name="$1"
	local lan_address="$2"
	local network="shadowrt-ap-$name"

	if ! docker network inspect "$network" -f '{{.Name}}' >/dev/null 2>&1; then
		eval $(ipcalc.sh "$lan_address") || return 1
		docker network create -d bridge --subnet "$NETWORK/$PREFIX" --gateway "$IP" \
			-o "com.docker.network.bridge.name=$name" \
			-o "com.docker.network.bridge.inhibit_ipv4=true" "$network" || return 1
	fi
	ip link set "$name" up
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

	local ap_bridge="br-$id"
	local lan_address=`uci get shadowrt.@instance[0].lan_address 2>/dev/null`

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
		case "$ap_bridge" in
			*[!A-Za-z0-9_.-]*|????????????????*)
				echo "dual mode instance ID creates a bridge name longer than 15 characters!" >&2
			exit 1
				;;
		esac
		ensure_ap_bridge "$ap_bridge" || exit 1
		ensure_ap_interface "$ap_bridge" || exit 1
		ensure_ap_network "$ap_bridge" "$lan_address" || exit 1
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

	local config="{\"id\":\"$id\",\"data\":\"$data\",\"mnt\":\"$mnt\",\"dind\":\"$dind\",\"proto\":\"$proto\",\"address\":\"$address\",\"gateway\":\"$gateway\",\"dns\":\"$dns\",\"lan_address\":\"$lan_address\",\"wan_ipv4_input\":\"$wan_ipv4_input\",\"dhcp_server\":\"$dhcp_server\",\"ports\":\"$ports\"}"

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

	echo "starting shadowrt instance $id..."
	echo "$cmd"
	eval "$cmd" || return 1
	if [ "$proto" = "dual" -o "$proto" = "dual_static" ]; then
		docker network connect "shadowrt-ap-$ap_bridge" "$id" || {
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
