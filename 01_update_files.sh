#!/bin/bash
# deploy_1.sh (extended)
# - parses env.yaml
# - updates haproxy.cfg (as before)
# - updates check_apiserver.sh
# - updates haproxy.yaml
# - asks user to pick a host and updates keepalived.conf accordingly

YAML_FILE="env.yaml"
HAPROXY_CFG="${1:-haproxy.cfg}"
CHECK_APISERVER_FILE="check_apiserver.sh"
HAPROXY_YAML_FILE="haproxy.yaml"
KEEPALIVED_FILE="keepalived.conf"

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

# ----------------------------
# 1. Parse env.yaml
# ----------------------------
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

  # cluster-level
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

  # hosts-level
  if [[ $in_hosts -eq 1 ]]; then
    # start of new host: "- name: k8s1"
    if [[ "$trimmed" == "- "* ]]; then
      # store previous host
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

    # key: value inside host
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

# push the last host
if [[ -n "$current_name" ]]; then
  host_names+=("$current_name")
  host_ips+=("$current_ip")
  host_ports+=("$current_port")
  host_states+=("$current_state")
  host_priorities+=("$current_priority")
fi

# export for compatibility
export APISERVER_VIP="$apiserver_vip"
export APISERVER_DEST_PORT="$apiserver_dest_port"
export IPV6_ENABLED="$ipv6_enabled"
export HOST_COUNT="${#host_names[@]}"

# ----------------------------
# 2. Update haproxy.cfg (existing behaviour)
# ----------------------------
if [[ -f "$HAPROXY_CFG" ]]; then
  # replace dest port placeholder
  sed -i "s/\${APISERVER_DEST_PORT}/$APISERVER_DEST_PORT/g" "$HAPROXY_CFG"

  # remove old placeholder server lines
  sed -i '/server[[:space:]].*\${HOST1_ID}/d' "$HAPROXY_CFG"
  sed -i '/server[[:space:]].*\${HOST1_ADDRESS}/d' "$HAPROXY_CFG"
  sed -i '/server[[:space:]].*\${APISERVER_SRC_PORT}/d' "$HAPROXY_CFG"

  {
    echo ""
    echo "# Auto-generated Kubernetes API backends"
    for i in "${!host_names[@]}"; do
      name=${host_names[$i]}
      ip=${host_ips[$i]}
      port=${host_ports[$i]}
      echo "    server $name $ip:$port check verify none"
    done
  } >> "$HAPROXY_CFG"
else
  echo "WARN: $HAPROXY_CFG not found, skipping haproxy.cfg update"
fi

# ----------------------------
# 3. Update check_apiserver.sh
# ----------------------------
if [[ -f "$CHECK_APISERVER_FILE" ]]; then
  # Replace ${APISERVER_DEST_PORT} with actual value
  sed -i "s/\${APISERVER_DEST_PORT}/$APISERVER_DEST_PORT/g" "$CHECK_APISERVER_FILE"
else
  echo "WARN: $CHECK_APISERVER_FILE not found, skipping check_apiserver.sh update"
fi

# ----------------------------
# 4. Update haproxy.yaml
# ----------------------------
if [[ -f "$HAPROXY_YAML_FILE" ]]; then
  sed -i "s/\${APISERVER_DEST_PORT}/$APISERVER_DEST_PORT/g" "$HAPROXY_YAML_FILE"
else
  echo "WARN: $HAPROXY_YAML_FILE not found, skipping haproxy.yaml update"
fi

# ----------------------------
# 5. Ask user to pick a host
# ----------------------------
echo "Available hosts from env.yaml:"
for i in "${!host_names[@]}"; do
  idx=$((i+1))
  echo "  $idx) ${host_names[$i]} (${host_ips[$i]}:${host_ports[$i]}) state=${host_states[$i]} priority=${host_priorities[$i]}"
done

read -rp "Select host number to apply to keepalived.conf: " host_choice

# sanitize choice
if ! [[ "$host_choice" =~ ^[0-9]+$ ]]; then
  echo "Invalid choice."
  exit 1
fi

host_idx=$((host_choice-1))
if (( host_idx < 0 || host_idx >= ${#host_names[@]} )); then
  echo "Choice out of range."
  exit 1
fi

sel_name=${host_names[$host_idx]}
sel_ip=${host_ips[$host_idx]}
sel_port=${host_ports[$host_idx]}
sel_state=${host_states[$host_idx]}
sel_priority=${host_priorities[$host_idx]}

# interface isn't in env.yaml, so we default it
INTERFACE_VALUE=${INTERFACE_VALUE:-eth0}

# ----------------------------
# 6. Detect interface and update keepalived.conf
# ----------------------------
if [[ -f "$KEEPALIVED_FILE" ]]; then
  # Detect main interface (using default route)
  MAIN_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5; exit}')
  if [[ -z "$MAIN_IFACE" ]]; then
    MAIN_IFACE=$(ip route | awk '/default/ {print $5; exit}')
  fi
  if [[ -z "$MAIN_IFACE" ]]; then
    MAIN_IFACE="eth0"  # fallback
  fi

  echo "Detected main interface: $MAIN_IFACE"

  # replace placeholders in keepalived.conf
  sed -i "s/\${STATE}/$sel_state/g" "$KEEPALIVED_FILE"
  sed -i "s/\${PRIORITY}/$sel_priority/g" "$KEEPALIVED_FILE"
  sed -i "s/\${APISERVER_VIP}/$APISERVER_VIP/g" "$KEEPALIVED_FILE"
  sed -i "s/\${INTERFACE}/$MAIN_IFACE/g" "$KEEPALIVED_FILE"

else
  echo "WARN: $KEEPALIVED_FILE not found, skipping keepalived.conf update"
fi

# ----------------------------
# 7. Done
# ----------------------------
echo "Updated files:"
echo "  - $HAPROXY_CFG (backends added)"
echo "  - $CHECK_APISERVER_FILE (APISERVER_DEST_PORT updated)"
echo "  - $HAPROXY_YAML_FILE (APISERVER_DEST_PORT updated)"
echo "  - $KEEPALIVED_FILE (STATE/PRIORITY/APISERVER_VIP/INTERFACE updated for $sel_name)"
