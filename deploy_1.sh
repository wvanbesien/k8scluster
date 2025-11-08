#!/bin/bash
# Usage:
#   source ./load_and_update.sh /path/to/haproxy.cfg
#   (defaults to ./haproxy.cfg)

YAML_FILE="env.yaml"
CONFIG_FILE="${1:-haproxy.cfg}"

apiserver_vip=""
apiserver_dest_port=""
ipv6_enabled=""

host_names=()
host_ips=()
host_ports=()
host_states=()
host_priorities=()

in_hosts=0
current_name=""
current_ip=""
current_port=""
current_state=""
current_priority=""
current_index=0

# --- parse env.yaml -----------------------------------------------------
while IFS= read -r line; do
  trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  case "$trimmed" in
    cluster:)
      in_hosts=0
      continue
      ;;
    hosts:)
      in_hosts=1
      continue
      ;;
  esac

  # cluster level
  if [[ $in_hosts -eq 0 && "$trimmed" == *:* ]]; then
    key=${trimmed%%:*}
    val=${trimmed#*:}
    key=$(echo "$key" | xargs)
    val=$(echo "$val" | xargs)
    case "$key" in
      apiserver_vip) apiserver_vip="$val" ;;
      apiserver_dest_port) apiserver_dest_port="$val" ;;
      ipv6_enabled) ipv6_enabled="$val" ;;
    esac
    continue
  fi

  # hosts level
  if [[ $in_hosts -eq 1 ]]; then
    # start of a new host: "- name: k8s1"
    if [[ "$trimmed" == "- "* ]]; then
      # store previous host if we had one
      if [[ -n "$current_name" ]]; then
        host_names+=("$current_name")
        host_ips+=("$current_ip")
        host_ports+=("$current_port")
        host_states+=("$current_state")
        host_priorities+=("$current_priority")
      fi

      current_name=""
      current_ip=""
      current_port=""
      current_state=""
      current_priority=""
      current_index=$(( ${#host_names[@]} + 1 ))

      rest=${trimmed#- }
      if [[ "$rest" == *:* ]]; then
        k=${rest%%:*}
        v=${rest#*:}
        k=$(echo "$k" | xargs)
        v=$(echo "$v" | xargs)
        if [[ "$k" == "name" ]]; then
          current_name="$v"
        fi
      fi
      continue
    fi

    # regular key: value inside a host
    if [[ "$trimmed" == *:* ]]; then
      k=${trimmed%%:*}
      v=${trimmed#*:}
      k=$(echo "$k" | xargs)
      v=$(echo "$v" | xargs)

      case "$k" in
        name) current_name="$v" ;;
        ip) current_ip="$v" ;;
        src_port) current_port="$v" ;;
        state) current_state="$v" ;;
        priority) current_priority="$v" ;;
      esac
    fi
  fi

done < "$YAML_FILE"

# push last host
if [[ -n "$current_name" ]]; then
  host_names+=("$current_name")
  host_ips+=("$current_ip")
  host_ports+=("$current_port")
  host_states+=("$current_state")
  host_priorities+=("$current_priority")
fi

# --- export cluster vars -----------------------------------------------
export APISERVER_VIP="$apiserver_vip"
export APISERVER_DEST_PORT="$apiserver_dest_port"
export IPV6_ENABLED="$ipv6_enabled"

# --- update haproxy file -----------------------------------------------
if [[ -f "$CONFIG_FILE" ]]; then
  # replace placeholder
  sed -i "s/\${APISERVER_DEST_PORT}/$APISERVER_DEST_PORT/g" "$CONFIG_FILE"

  # Also remove any other leftover placeholder variants (safety)
  sed -i '/server[[:space:]].*\${HOST1_ADDRESS}/d' "$CONFIG_FILE"
  sed -i '/server[[:space:]].*\${APISERVER_SRC_PORT}/d' "$CONFIG_FILE"

  # append servers
  {
    echo ""
    echo "# Auto-generated Kubernetes API backends"
    for i in "${!host_names[@]}"; do
      name=${host_names[$i]}
      ip=${host_ips[$i]}
      port=${host_ports[$i]}
      echo "    server $name $ip:$port check verify none"
    done
  } >> "$CONFIG_FILE"
else
  echo "WARN: Config file '$CONFIG_FILE' not found, skipping haproxy update." >&2
fi

# --- export per-host vars ----------------------------------------------
for i in "${!host_names[@]}"; do
  idx=$((i+1))
  export "HOST${idx}_NAME=${host_names[$i]}"
  export "HOST${idx}_IP=${host_ips[$i]}"
  export "HOST${idx}_PORT=${host_ports[$i]}"
  export "HOST${idx}_STATE=${host_states[$i]}"
  export "HOST${idx}_PRIORITY=${host_priorities[$i]}"
done

export HOST_COUNT="${#host_names[@]}"

# --- debug --------------------------------------------------------------
echo "APISERVER_VIP=$APISERVER_VIP"
echo "APISERVER_DEST_PORT=$APISERVER_DEST_PORT"
echo "IPV6_ENABLED=$IPV6_ENABLED"
echo "HOST_COUNT=$HOST_COUNT"
for i in "${!host_names[@]}"; do
  idx=$((i+1))
  echo "HOST${idx}_NAME=${host_names[$i]} HOST${idx}_IP=${host_ips[$i]} HOST${idx}_PORT=${host_ports[$i]} HOST${idx}_STATE=${host_states[$i]} HOST${idx}_PRIORITY=${host_priorities[$i]}"
done

