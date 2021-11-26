#!/usr/bin/env bash

red=$(tput setaf 5)
green=$(tput setaf 2)
normal=$(tput sgr0)
SC_SUB="demo.sub"
SB_SUB="demo.shop"


function start_setup {
printf "\n\n\n=================================================================\n\n\n"
printf "${green}Start${normal}\n\n"

CS_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' compose_cacheserve_1)
PX_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' compose_proxy_1)
PX_IP_PREFIX=$(echo -n "$PX_IP" | sed -n -e 's/\([0-9]\+\.[0-9]\+\.[0-9]\+\)\.[0-9]\+/\1/p')

echo "Cacheserve IP is ${CS_IP}"
echo "Proxy IP is ${PX_IP}"
}

function prepare_proxy {
echo "Installing iproute package on nom-proxy"
docker exec -i compose_proxy_1 bash -c 'yum -y install iproute'

for DG in {100..102}
do
    echo "Adding IP to nom-proxy container interface ${PX_IP_PREFIX}.${DG}"
    docker exec -i compose_proxy_1 bash -c "ip addr add ${PX_IP_PREFIX}.${DG}/16 dev eth0"
done
}


function update_proxy_routing {
ROUTING="---
global:
  routing:
    device-groups:
      - name: DEFAULT
        sites:
          - name: DEFAULT
            addresses:
              - ${PX_IP}
      - name: DG-1
        sites:
          - name: DEFAULT
            addresses:
              - ${PX_IP_PREFIX}.100
      - name: DG-2
        sites:
          - name: DEFAULT
            addresses:
              - ${PX_IP_PREFIX}.101
      - name: DG-3
        sites:
          - name: DEFAULT
            addresses:
              - ${PX_IP_PREFIX}.102
"

echo -n "$ROUTING" | docker exec -i compose_levant_1 bash -c "cat >./demo-routing.yaml"
docker exec -t compose_levant_1 bash -c '/usr/local/nom/sbin/levant-cli -h pgaas -p 15433 --load ./demo-routing.yaml --commit'
}


function deploy_cpe {
DC_CPE="
#CPE START
  cpe:
    image: andyshinn/dnsmasq:2.78
    networks:
    - default
    - cpe-1
    cap_add:
    - NET_ADMIN
    command: [\"--add-mac=text\", \"--cache-size=0\", \"--log-queries\", \"--log-facility=-\", \"--no-daemon\", \"--port\", \"53\", \"--no-resolv\", \"-S\", \"${CS_IP}\"]
#CPE END
"

DC_CPE_NET="
networks:
  cpe-1:
"

egrep 'CPE START' /usr/local/nom/share/nom-demo/docker/compose/docker-compose.yml >/dev/null
RC=$?

if [[ $RC == 1 ]]
then
    echo -n "${DC_CPE}" >>/usr/local/nom/share/nom-demo/docker/compose/docker-compose.yml
    echo -n "${DC_CPE_NET}" >>/usr/local/nom/share/nom-demo/docker/compose/docker-compose.yml
fi

dc up -d cpe
CPE_PRIV_IP=$(docker inspect compose_cpe_1 | jq -r '.[] | .NetworkSettings.Networks["compose_cpe-1"]["IPAddress"]')
CPE_DEF_IP=$(docker inspect compose_cpe_1 | jq -r '.[] | .NetworkSettings.Networks["compose_default"]["IPAddress"]')
echo "CPE private ip address $CPE_PRIV_IP and default ip address $CPE_DEF_IP"

}


function deploy_clients {

DC_WIFI_DEV="
#WIFI DEV START
  wifi-dev:
    image: jlesage/firefox
    networks:
    - cpe-1
    cap_add:
    - NET_ADMIN
    dns:
    - ${CPE_PRIV_IP}
    ports:
    - \"8083:5800\"
"

DC_MOBILE_DEV="
  mob-dev:
    image: jlesage/firefox
    cap_add:
    - NET_ADMIN
    dns:
    - ${CS_IP}
    ports:
    - \"8085:5800\"
"

echo -n "${DC_WIFI_DEV}" >/tmp/dc-demo-svc.yaml
echo -n "${DC_MOBILE_DEV}" >>/tmp/dc-demo-svc.yaml

egrep 'WIFI DEV START' /usr/local/nom/share/nom-demo/docker/compose/docker-compose.yml >/dev/null
RC=$?

if [[ $RC == 1 ]]
then
    INSERT_LINE=$(awk '/#CPE END/ {print NR}' /usr/local/nom/share/nom-demo/docker/compose/docker-compose.yml)
    sed -i "${INSERT_LINE}r /tmp/dc-demo-svc.yaml" /usr/local/nom/share/nom-demo/docker/compose/docker-compose.yml
fi

dc up -d wifi-dev mob-dev

}


function configure_cpe {
docker exec -i compose_cpe_1 sh -c "apk update && apk upgrade &>/dev/null"
docker exec -i compose_cpe_1 sh -c "apk add iptables"
docker exec -i compose_cpe_1 sh -c "ip route del default"
docker exec -i compose_cpe_1 sh -c "ip route add default via ${PX_IP_PREFIX}.1"
CPE_NET_IP_PREFIX=$(echo -n "$CPE_PRIV_IP" | sed -n -e 's/\([0-9]\+\.[0-9]\+\.[0-9]\+\)\.[0-9]\+/\1/p')
docker exec -i compose_cpe_1 sh -c "iptables -t nat -A POSTROUTING -s ${CPE_NET_IP_PREFIX}.0/16 -o eth1 -j MASQUERADE"
}


function confiugure_wifi_dev {
docker exec -i compose_wifi-dev_1 sh -c "ip route del default"
docker exec -i compose_wifi-dev_1 sh -c "ip route add default via ${CPE_PRIV_IP}"
YOUR_IP=$(echo $SSH_CLIENT | cut -d" " -f 1)
docker exec -i compose_wifi-dev_1 sh -c "ip route add ${YOUR_IP}/32 via ${CPE_NET_IP_PREFIX}.1"
}


function configure_subscriber_sc {
SSM_PWD=$(docker exec -i compose_sportal_1 sh -c 'cat /usr/local/nom/etc/sportal/sportal_test_users.properties | head -1 | cut -d" " -f 4')
WIFI_DEV_MAC=$(docker inspect compose_wifi-dev_1 | jq -r '.[] | .NetworkSettings.Networks["compose_cpe-1"]["MacAddress"]')
MOB_DEV_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' compose_mob-dev_1)
# Setup subscriber
curl -H 'Content-type: application/json' -u admin:${SSM_PWD} --request POST --data "{\"id\":\"${SC_SUB}\",\"time-zone\":\"UTC\"}" http://localhost:9090/control
curl -H 'Content-type: application/json' -u admin:${SSM_PWD} --request POST --data '{"service":"personal-internet","service-profile":"perdevice"}' http://localhost:9090/control/${SC_SUB}/service
curl -H 'Content-type: application/json' -u admin:${SSM_PWD} --request POST --data '{"service":"subscriber-safety","service-profile":"standard"}' http://localhost:9090/control/${SC_SUB}/service
curl -H 'Content-type: application/json' -u admin:${SSM_PWD} --request POST --data '{"add": [{"name": "demo.sub@wifi", "list": "fixed"},{"name": "3955555555", "list": "mobile"}]}' http://localhost:9090/account/${SC_SUB}/line
# Setup view-selectors
curl -H 'Content-type: application/json' -u admin:${SSM_PWD} --request POST --data "{\"view\":\"${SC_SUB}\", \"source-address\":\"${MOB_DEV_IP}\", \"default-device-id\": \"3955555555\"}" http://localhost:8082/view-selector/
curl -H 'Content-type: application/json' -u admin:${SSM_PWD} --request POST --data "{\"view\":\"${SC_SUB}\", \"source-address\":\"${CPE_DEF_IP}\"}" http://localhost:8082/view-selector/
# Add pwd for sportal
docker exec -i compose_sportal_1 bash -c "echo \"${SC_SUB} = ${SC_SUB} demo ROLE_USER per-device\" >>/usr/local/nom/etc/sportal/sportal_test_users.properties"
# Configure profiles
cat >profiles.json <<EOF
[
    {
        "name": "Default",
        "default": true,
        "internet-access": true,
        "protection-enabled": true,
        "protection": "light",
        "safe-search": true,
        "safe-search-services": {
            "youtube": true,
            "google": true,
            "bing": true
        }
    },
    {
        "default": false,
        "internet-access": true,
        "protection-enabled": true,
        "safe-search": true,
        "safe-search-services": {
            "youtube": true,
            "google": true,
            "bing": true
        },
        "name": "kids",
        "age-group": "pi-ag1",
        "protection": "strict",
        "inspect-stream": false
    },
    {
        "default": false,
        "internet-access": true,
        "protection-enabled": true,
        "safe-search": false,
        "safe-search-services": {
            "youtube": false,
            "google": false,
            "bing": false
        },
        "name": "adults",
        "age-group": "pi-ag3",
        "protection": "light",
        "inspect-stream": false
    },
    {
        "default": false,
        "internet-access": true,
        "protection-enabled": true,
        "safe-search": true,
        "safe-search-services": {
            "youtube": true,
            "google": true,
            "bing": true
        },
        "name": "guests",
        "age-group": "pi-ag2",
        "protection": "medium",
        "inspect-stream": false
    }
]
EOF

curl -H 'Content-type: application/json' -u admin:${SSM_PWD} --request POST --data @profiles.json http://localhost:9090/pi/${SC_SUB}/profile
curl -H 'Content-type: application/json' -u admin:${SSM_PWD} --request POST --data "{\"add\":[{\"name\":\"Tablet\",\"profile\":\"kids\",\"identifiers\":[\"${WIFI_DEV_MAC}\"]}]}" http://localhost:9090/account/${SC_SUB}/logical-device
curl -H 'Content-type: application/json' -u admin:${SSM_PWD} --request POST --data "{\"add\":[{\"name\":\"Mobile\",\"profile\":\"adults\",\"identifiers\":[\"3955555555\"]}]}" http://localhost:9090/account/${SC_SUB}/logical-device
}

function finish_setup {
EXT_IP=$(curl --silent --header 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
printf "\n\n\n=================================================================\n\n\n"
printf "${green}Setup completed${normal}\n\n"
echo "Mobile device web-browser available at http://${EXT_IP}:8085"
echo "Home wi-fi device web-browser available at http://${EXT_IP}:8083"
echo "Subscriber account management via portal is available at http://${EXT_IP}:8444, login: ${SC_SUB}, pwd: demo"
}

function stop_services {
sed -i '/CPE START/,$d' /usr/local/nom/share/nom-demo/docker/compose/docker-compose.yml
dc up -d --remove-orphans
}

function remove_subscriber {
subscriber=$1
SSM_PWD=$(docker exec -i compose_sportal_1 sh -c 'cat /usr/local/nom/etc/sportal/sportal_test_users.properties | head -1 | cut -d" " -f 4')
curl -H 'Content-type: application/json' -u admin:${SSM_PWD} --request POST --data '{"metrics": ["content", "safety", "botnet", "dns", "device-discovery"]}' http://localhost:9090/account/${subscriber}/history:force-clear
curl -u admin:${SSM_PWD} --request DELETE http://localhost:9090/account/${subscriber}
}


if [[ $1 == start_sc ]]
then
  start_setup
  prepare_proxy
  update_proxy_routing
  deploy_cpe
  deploy_clients
  configure_cpe
  confiugure_wifi_dev
  configure_subscriber_sc
  finish_setup
fi

if [[ $1 == stop_sc ]]
then
  stop_services
  remove_subscriber ${SC_SUB}
fi