#!/bin/bash
# source this file:  source ./load_env.sh

YAML_FILE="env.yaml"

apiserver_vip=""
apiserver_dest_port=""
ipv6_enabled=""

host_names=()
host_ips=()
host_ports=()

in_hosts=0
current_name=""
current_ip=""
current_port=""

while IFS= read -r line; do
  # strip outer spaces
  trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # detect sections
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

  # cluster-level keys
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

  # hosts section
  if [[ $in_hosts -eq 1 ]]; then
    # start of a new host: "- name: k8s1" or just "-"
    if [[ "$trimmed" == "- "* ]]; then
      # if we already collected a host, store it
      if [[ -n "$current_name" ]]; then
        host_names+=("$current_name")
        host_ips+=("$current_ip")
        host_ports+=("$current_port")
      fi

      # reset for new host
      current_name=""
      current_ip=""
      current_port=""

      # maybe this line already has "name: ..."
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

    # lines under a host: "name:", "ip:", "src_port:"
    if [[ "$trimmed" == *:* ]]; then
      k=${trimmed%%:*}
      v=${trimmed#*:}
      k=$(echo "$k" | xargs)
      v=$(echo "$v" | xargs)
      case "$k" in
        name) current_name="$v" ;;
        ip) current_ip="$v" ;;
        src_port) current_port="$v" ;;
      esac
    fi
  fi

done < "$YAML_FILE"

# after loop, push the last host (if any)
if [[ -n "$current_name" ]]; then
  host_names+=("$current_name")
  host_ips+=("$current_ip")
  host_ports+=("$current_port")
fi

# export cluster vars
export APISERVER_VIP="$apiserver_vip"
export APISERVER_DEST_PORT="$apiserver_dest_port"
export IPV6_ENABLED="$ipv6_enabled"

# export per-host vars and show them
for i in "${!host_names[@]}"; do
  idx=$((i+1))
  export "HOST${idx}_NAME=${host_names[$i]}"
  export "HOST${idx}_IP=${host_ips[$i]}"
  export "HOST${idx}_PORT=${host_ports[$i]}"
  echo "HOST${idx}_NAME=${host_names[$i]} HOST${idx}_IP=${host_ips[$i]} HOST${idx}_PORT=${host_ports[$i]}"
done

echo "APISERVER_VIP=$APISERVER_VIP"
echo "APISERVER_DEST_PORT=$APISERVER_DEST_PORT"
echo "IPV6_ENABLED=$IPV6_ENABLED"
echo "HOST_COUNT=${#host_names[@]}"
