#!/usr/bin/env bash
#=================================================================#
#   System Required:  Ubuntu 20.04+ / Debian 10+                 #
#   Description: One click Install Shadowsocks-libev server       #
#   Author: Gemini (Modernized from Teddysun's original script)   #
#   Intro:  https://github.com/shadowsocks/shadowsocks-libev      #
#=================================================================#

clear
echo
echo "#############################################################"
echo "# One click Install Shadowsocks-libev server (Modernized)   #"
echo "# This script installs shadowsocks-libev using apt          #"
echo "# and configures systemd and UFW firewall.                  #"
echo "#############################################################"
echo

# Stream Ciphers (Modern ciphers first)
ciphers=(
aes-256-gcm
aes-192-gcm
aes-128-gcm
chacha20-ietf-poly1305
aes-256-ctr
aes-192-ctr
aes-128-ctr
aes-256-cfb
aes-192-cfb
aes-128-cfb
camellia-128-cfb
camellia-192-cfb
camellia-256-cfb
)
# Color
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# Make sure only root can run our script
[[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] This script must be run as root!" && exit 1

# Check for apt
if ! command -v apt-get &> /dev/null; then
    echo -e "[${red}Error${plain}] This script is designed for Debian/Ubuntu systems using apt."
    exit 1
fi

# Get public IP address
get_ip(){
    local IP=$( ip addr | egrep -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | egrep -v "^192\.168|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-2]\.|^10\.|^127\.|^255\.|^0\." | head -n 1 )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipv4.icanhazip.com )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipinfo.io/ip )
    [ ! -z ${IP} ] && echo ${IP} || echo "Unknown"
}

get_char(){
    SAVEDSTTY=`stty -g`
    stty -echo
    stty cbreak
    dd if=/dev/tty bs=1 count=1 2> /dev/null
    stty -raw
    stty echo
    stty $SAVEDSTTY
}

# Pre-installation settings
get_config(){
    # Set shadowsocks config password
    echo "Please enter password for Shadowsocks"
    read -p "(Default password: teddysun.com):" shadowsockspwd
    [ -z "${shadowsockspwd}" ] && shadowsockspwd="teddysun.com"
    echo
    echo "---------------------------"
    echo "password = ${shadowsockspwd}"
    echo "---------------------------"
    echo

    # Set shadowsocks config port
    while true
    do
    dport=$(shuf -i 9000-19999 -n 1)
    echo "Please enter a port for Shadowsocks [1-65535]"
    read -p "(Default port: ${dport}):" shadowsocksport
    [ -z "$shadowsocksport" ] && shadowsocksport=${dport}
    expr ${shadowsocksport} + 1 &>/dev/null
    if [ $? -eq 0 ]; then
        if [ ${shadowsocksport} -ge 1 ] && [ ${shadowsocksport} -le 65535 ]; then
            echo
            echo "---------------------------"
            echo "port = ${shadowsocksport}"
            echo "---------------------------"
            echo
            break
        fi
    fi
    echo -e "[${red}Error${plain}] Please enter a correct number [1-65535]"
    done

    # Set shadowsocks config stream ciphers
    while true
    do
    echo -e "Please select stream cipher for Shadowsocks:"
    for ((i=1;i<=${#ciphers[@]};i++ )); do
        hint="${ciphers[$i-1]}"
        echo -e "${green}${i}${plain}) ${hint}"
    done
    read -p "Which cipher you'd select(Default: ${ciphers[0]}):" pick
    [ -z "$pick" ] && pick=1
    expr ${pick} + 1 &>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "[${red}Error${plain}] Please enter a number"
        continue
    fi
    if [[ "$pick" -lt 1 || "$pick" -gt ${#ciphers[@]} ]]; then
        echo -e "[${red}Error${plain}] Please enter a number between 1 and ${#ciphers[@]}"
        continue
    fi
    shadowsockscipher=${ciphers[$pick-1]}
    echo
    echo "---------------------------"
    echo "cipher = ${shadowsockscipher}"
    echo "---------------------------"
    echo
    break
    done

    echo
    echo "Press any key to start...or Press Ctrl+C to cancel"
    char=`get_char`
}

# Config shadowsocks
config_shadowsocks(){
    # The config file for shadowsocks-libev package is different
    mkdir -p /etc/shadowsocks-libev
    cat > /etc/shadowsocks-libev/config.json<<-EOF
{
    "server":"0.0.0.0",
    "server_port":${shadowsocksport},
    "password":"${shadowsockspwd}",
    "timeout":300,
    "method":"${shadowsockscipher}",
    "fast_open":false,
    "mode": "tcp_and_udp"
}
EOF
}

# Firewall set
firewall_set(){
    echo -e "[${green}Info${plain}] Setting up firewall (ufw)..."
    if ! command -v ufw &> /dev/null; then
        echo -e "[${yellow}Warning${plain}] ufw is not installed. Skipping firewall setup."
        return
    fi
    
    # Allow SSH, so we don't get locked out
    ufw allow ssh
    
    # Allow shadowsocks port
    ufw allow ${shadowsocksport}/tcp
    ufw allow ${shadowsocksport}/udp
    
    # Enable firewall
    echo "y" | ufw enable > /dev/null 2>&1
    
    echo -e "[${green}Info${plain}] Firewall configured. Port ${shadowsocksport} (TCP/UDP) opened."
}

# Install Shadowsocks
install(){
    echo -e "[${green}Info${plain}] Installing dependencies (shadowsocks-libev, ufw)..."
    apt-get update -y
    apt-get install -y shadowsocks-libev ufw
    if [ $? -ne 0 ]; then
        echo -e "[${red}Error${plain}] Failed to install shadowsocks-libev. Aborting."
        exit 1
    fi
    
    # Start and enable the service using systemd
    echo -e "[${green}Info${plain}] Starting and enabling shadowsocks-libev service..."
    systemctl enable shadowsocks-libev
    systemctl restart shadowsocks-libev
    
    if ! systemctl is-active --quiet shadowsocks-libev; then
        echo -e "[${red}Error${plain}] Shadowsocks-libev service failed to start."
        echo "Please check the logs with: journalctl -u shadowsocks-libev"
        exit 1
    fi

    clear
    echo
    echo -e "Congratulations, Shadowsocks-libev server install completed!"
    echo -e "Your Server IP        : \033[41;37m $(get_ip) \033[0m"
    echo -e "Your Server Port      : \033[41;37m ${shadowsocksport} \033[0m"
    echo -e "Your Password         : \033[41;37m ${shadowsockspwd} \033[0m"
    echo -e "Your Encryption Method: \033[41;37m ${shadowsockscipher} \033[0m"
    echo
    echo "Enjoy it!"
    echo
}

# Uninstall Shadowsocks
uninstall_shadowsocks(){
    printf "Are you sure uninstall Shadowsocks-libev? (y/n) "
    printf "\n"
    read -p "(Default: n):" answer
    [ -z ${answer} ] && answer="n"
    if [ "${answer}" == "y" ] || [ "${answer}" == "Y" ]; then
        # Try to read port from config file to remove firewall rule
        if [ -f /etc/shadowsocks-libev/config.json ]; then
            shadowsocksport=$(grep -oP '"server_port":\s*\K[0-9]+' /etc/shadowsocks-libev/config.json)
            if [ ! -z "$shadowsocksport" ]; then
                echo -e "[${green}Info${plain}] Removing firewall rule for port ${shadowsocksport}..."
                ufw delete allow ${shadowsocksport}/tcp
                ufw delete allow ${shadowsocksport}/udp
            fi
        fi

        echo -e "[${green}Info${plain}] Stopping and disabling shadowsocks-libev service..."
        systemctl stop shadowsocks-libev
        systemctl disable shadowsocks-libev
        
        echo -e "[${green}Info${plain}] Purging shadowsocks-libev package and config..."
        apt-get remove --purge -y shadowsocks-libev
        rm -rf /etc/shadowsocks-libev
        
        echo "Shadowsocks-libev uninstall success!"
    else
        echo
        echo "Uninstall cancelled, nothing to do..."
        echo
    fi
}

# Install Shadowsocks-libev
install_shadowsocks(){
    get_config
    config_shadowsocks
    firewall_set
    install
}

# Initialization step
action=$1
[ -z $1 ] && action=install
case "$action" in
    install|uninstall)
        ${action}_shadowsocks
        ;;
    *)
        echo "Arguments error! [${action}]"
        echo "Usage: `basename $0` [install|uninstall]"
    ;;
esac
