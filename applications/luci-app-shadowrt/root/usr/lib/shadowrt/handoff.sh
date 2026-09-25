#!/bin/sh

shadowrt_handoff_names() {
	local id="$1"
	local token normalized hash

	[ -n "$id" ] || {
		echo "shadowrt instance ID is empty!" >&2
		return 1
	}

	case "$id" in
		*[!a-z0-9-]*)
			;;
		[a-z0-9]*)
			[ "${#id}" -le 12 ] && token="$id"
			;;
	esac

	if [ -z "$token" ]; then
		normalized="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
		[ -n "$normalized" ] || {
			echo "shadowrt instance ID must contain a letter or number!" >&2
			return 1
		}
		hash="$(printf '%s' "$id" | md5sum | cut -c1-4)"
		token="$(printf '%s' "$normalized" | cut -c1-7)-$hash"
	fi

	SHADOWRT_TOKEN="$token"
	SHADOWRT_HOST_BRIDGE="br-$token"
	SHADOWRT_HOST_VETH="srh$token"
	SHADOWRT_DOCKER_VETH="srd$token"
	SHADOWRT_DOCKER_BRIDGE="srb$token"
	SHADOWRT_DOCKER_NETWORK="shadowrt-lan-$token"
	export SHADOWRT_TOKEN SHADOWRT_HOST_BRIDGE SHADOWRT_HOST_VETH \
		SHADOWRT_DOCKER_VETH SHADOWRT_DOCKER_BRIDGE SHADOWRT_DOCKER_NETWORK
}

shadowrt_handoff_links() {
	ip link add "$SHADOWRT_DOCKER_BRIDGE" type bridge 2>/dev/null

	if ! ip link show "$SHADOWRT_HOST_VETH" >/dev/null 2>&1; then
		ip link add "$SHADOWRT_HOST_VETH" type veth peer name "$SHADOWRT_DOCKER_VETH" || return 1
	fi
	ip link show "$SHADOWRT_DOCKER_VETH" >/dev/null 2>&1 || {
		echo "shadowrt handoff veth is incomplete!" >&2
		return 1
	}

	ip link set "$SHADOWRT_DOCKER_VETH" master "$SHADOWRT_DOCKER_BRIDGE" || return 1
	ip link set "$SHADOWRT_DOCKER_BRIDGE" up || return 1
	ip link set "$SHADOWRT_HOST_VETH" up || return 1
	ip link set "$SHADOWRT_DOCKER_VETH" up || return 1
}
