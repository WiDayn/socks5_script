#!/bin/bash

#================================================================
# Dante Socks5 Proxy Management Script (English Version)
#================================================================

# Variables
CONFIG_FILE="/etc/danted.conf"
LOG_FILE="/var/log/danted.log"
SERVICE_NAME="danted"
USER_REGISTRY="/var/lib/dante-proxy/users.list"

#================================================================
# Helper functions
#================================================================

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
       echo "Error: this script must be run as root (sudo)."
       exit 1
    fi
}

check_installed() {
    if ! command -v danted &> /dev/null; then
        echo "Error: Dante Server (danted) is not installed."
        echo "Please run: $0 install"
        exit 1
    fi
}

restart_service() {
    echo "Restarting ${SERVICE_NAME} service..."
    systemctl restart ${SERVICE_NAME}
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        echo "${SERVICE_NAME} restarted successfully."
    else
        echo "Error: failed to start ${SERVICE_NAME}!"
        echo "Check logs via 'sudo journalctl -xeu ${SERVICE_NAME}'."
    fi
}

get_current_port() {
    if [ -f "$CONFIG_FILE" ]; then
        grep -Po 'internal:.*port\s*=\s*\K[0-9]+' "$CONFIG_FILE" | head -n1
    fi
}

ensure_user_registry() {
    mkdir -p "$(dirname "$USER_REGISTRY")"
    [ -f "$USER_REGISTRY" ] || touch "$USER_REGISTRY"
}

register_user() {
    local username="$1"
    ensure_user_registry
    if [ -n "$username" ] && ! grep -Fxq "$username" "$USER_REGISTRY"; then
        echo "$username" >> "$USER_REGISTRY"
    fi
}

unregister_user() {
    local username="$1"
    ensure_user_registry
    if [ -n "$username" ] && grep -Fxq "$username" "$USER_REGISTRY"; then
        grep -Fxv "$username" "$USER_REGISTRY" > "${USER_REGISTRY}.tmp" && mv "${USER_REGISTRY}.tmp" "$USER_REGISTRY"
    fi
}

#================================================================
# Core features
#================================================================

do_install() {
    echo "Installing Dante Socks5 server..."
    apt update >/dev/null
    apt install -y dante-server

    if [ $? -ne 0 ]; then
        echo "Error: failed to install Dante server."
        exit 1
    fi

    read -p "Enter desired proxy port (default: 1080): " PROXY_PORT
    PROXY_PORT=${PROXY_PORT:-1080}

    read -p "Enter initial proxy username (default: proxyuser): " PROXY_USER
    PROXY_USER=${PROXY_USER:-proxyuser}

    echo "Auto-detecting external interface..."
    EXT_INTERFACE=$(ip route get 1.1.1.1 | awk '{print $5}' | head -n1)
    
    if [ -z "$EXT_INTERFACE" ]; then
        echo "Error: unable to detect network interface automatically."
        echo "Please run 'ip addr show' to find the primary interface (e.g., eth0, ens18)."
        read -p "Enter primary interface name: " EXT_INTERFACE
        if [ -z "$EXT_INTERFACE" ]; then
            echo "Operation canceled."
            exit 1
        fi
    else
        echo "Detected interface: $EXT_INTERFACE"
    fi

    [ -f "$CONFIG_FILE" ] && mv "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%s)"

    echo "Creating config file: $CONFIG_FILE"
    cat << EOF > "$CONFIG_FILE"
logoutput: $LOG_FILE
internal: 0.0.0.0 port = $PROXY_PORT
external: $EXT_INTERFACE

method: username
user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}

pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    method: username
    log: connect error
}
EOF

    echo "Creating proxy user: $PROXY_USER"
    if id "$PROXY_USER" &>/dev/null; then
        echo "User $PROXY_USER already exists."
    else
        useradd --shell /usr/sbin/nologin "$PROXY_USER"
        if [ $? -ne 0 ]; then
            echo "Error: failed to create user $PROXY_USER."
            exit 1
        fi
    fi
    
    echo "--- Set password for $PROXY_USER ---"
    passwd "$PROXY_USER"
    echo "------------------------------------"
    register_user "$PROXY_USER"

    echo "Configuring firewall (UFW)..."
    ufw allow $PROXY_PORT/tcp
    ufw reload

    echo "Preparing log file: $LOG_FILE"
    touch "$LOG_FILE"
    chown nobody:nogroup "$LOG_FILE"

    systemctl enable ${SERVICE_NAME}
    restart_service

    echo "---"
    echo "✅ Dante Socks5 proxy installed and running!"
    echo "   Server IP: $(hostname -I | cut -d' ' -f1)"
    echo "   Port:      $PROXY_PORT"
    echo "   Username:  $PROXY_USER"
    echo "---"
}

do_uninstall() {
    echo "Uninstalling Dante Server..."
    check_installed
    
    CURRENT_PORT=$(get_current_port)

    systemctl stop ${SERVICE_NAME}
    systemctl disable ${SERVICE_NAME}
    
    apt purge -y dante-server
    
    rm -f "$CONFIG_FILE"
    rm -f "$LOG_FILE"
    rm -f "$USER_REGISTRY"
    
    if [ -n "$CURRENT_PORT" ]; then
        echo "Closing firewall port $CURRENT_PORT..."
        ufw delete allow $CURRENT_PORT/tcp
        ufw reload
    fi
    
    echo "Dante Server removed."
    echo "Note: system users created for Dante (e.g., proxyuser) are not deleted automatically."
    echo "Use 'sudo userdel <username>' if needed."
}

do_stop() {
    check_installed
    echo "Stopping ${SERVICE_NAME} service..."
    systemctl stop ${SERVICE_NAME}
    echo "${SERVICE_NAME} stopped."
}

do_change_port() {
    check_installed
    NEW_PORT="$1"

    if [ -z "$NEW_PORT" ]; then
        echo "Error: missing new port."
        echo "Usage: $0 changeport <port>"
        exit 1
    fi

    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo "Error: invalid port (must be 1-65535)."
        exit 1
    fi

    CURRENT_PORT=$(get_current_port)

    if [ -z "$CURRENT_PORT" ]; then
        echo "Error: unable to read current port from $CONFIG_FILE."
        exit 1
    fi

    echo "Changing port from $CURRENT_PORT to $NEW_PORT..."
    
    sed -i "s/port = $CURRENT_PORT/port = $NEW_PORT/" "$CONFIG_FILE"
    
    ufw delete allow $CURRENT_PORT/tcp
    ufw allow $NEW_PORT/tcp
    ufw reload
    
    restart_service
    echo "Port updated to $NEW_PORT."
}

do_change_pass() {
    check_installed
    TARGET_USER="$1"
    
    if [ -z "$TARGET_USER" ]; then
        echo "Error: missing username."
        echo "Usage: $0 changepass <username>"
        exit 1
    fi

    if ! id "$TARGET_USER" &>/dev/null; then
        echo "Error: user '$TARGET_USER' not found."
        exit 1
    fi

    echo "--- Updating password for $TARGET_USER ---"
    passwd "$TARGET_USER"
    echo "------------------------------------------"
    echo "Password updated."
}

do_rename_user() {
    check_installed
    OLD_USER="$1"
    NEW_USER="$2"

    if [ -z "$OLD_USER" ] || [ -z "$NEW_USER" ]; then
        echo "Error: missing arguments."
        echo "Usage: $0 renameuser <old> <new>"
        exit 1
    fi

    if ! id "$OLD_USER" &>/dev/null; then
        echo "Error: old user '$OLD_USER' not found."
        exit 1
    fi
    
    if id "$NEW_USER" &>/dev/null; then
        echo "Error: new user '$NEW_USER' already exists."
        exit 1
    fi

    usermod -l "$NEW_USER" "$OLD_USER"
    unregister_user "$OLD_USER"
    register_user "$NEW_USER"
    echo "Renamed '$OLD_USER' to '$NEW_USER'."
}

do_start() {
    check_installed
    echo "Starting ${SERVICE_NAME}..."
    systemctl start ${SERVICE_NAME}
    systemctl status ${SERVICE_NAME} --no-pager
}

do_restart() {
    check_installed
    restart_service
}

do_status() {
    check_installed
    systemctl status ${SERVICE_NAME} --no-pager
}

do_add_user() {
    check_installed
    NEW_USER="$1"
    if [ -z "$NEW_USER" ]; then
        echo "Error: missing username."
        echo "Usage: $0 adduser <username>"
        exit 1
    fi

    if id "$NEW_USER" &>/dev/null; then
        echo "Error: user '$NEW_USER' already exists."
        exit 1
    fi

    echo "Adding new user: $NEW_USER"
    useradd --shell /usr/sbin/nologin "$NEW_USER"
    echo "--- Set password for $NEW_USER ---"
    passwd "$NEW_USER"
    echo "----------------------------------"
    register_user "$NEW_USER"
    echo "User $NEW_USER added."
}

do_del_user() {
    check_installed
    TARGET_USER="$1"
    if [ -z "$TARGET_USER" ]; then
        echo "Error: missing username."
        echo "Usage: $0 deluser <username>"
        exit 1
    fi

    if ! id "$TARGET_USER" &>/dev/null; then
        echo "Error: user '$TARGET_USER' not found."
        exit 1
    fi
    
    read -p "Delete system user '$TARGET_USER'? [y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        userdel "$TARGET_USER"
        unregister_user "$TARGET_USER"
        echo "User '$TARGET_USER' removed."
    else
        echo "Operation canceled."
    fi
}

list_proxy_users() {
    check_installed
    ensure_user_registry
    echo "=== Registered proxy users ==="
    if [ ! -s "$USER_REGISTRY" ]; then
        echo "No records."
        return
    fi

    while IFS= read -r user; do
        [ -z "$user" ] && continue
        if id "$user" &>/dev/null; then
            local uid gid
            uid=$(id -u "$user")
            gid=$(id -g "$user")
            echo " - $user (UID: $uid, GID: $gid)"
        else
            echo " - $user (not found on system; consider cleanup)"
        fi
    done < "$USER_REGISTRY"
}

show_connection_info() {
    check_installed
    local current_port
    current_port=$(get_current_port)
    echo "=== Active connections (listen port: ${current_port:-unknown}) ==="
    if ! command -v ss &>/dev/null; then
        echo "Command 'ss' not available; install iproute2 package."
        return
    fi

    local output
    if [ -n "$current_port" ]; then
        output=$(ss -ntp 2>/dev/null | awk -v port=":$current_port" 'NR==1 || $4 ~ port || $5 ~ port')
    else
        output=$(ss -ntp 2>/dev/null | grep -i "$SERVICE_NAME")
    fi

    if [ -n "$output" ]; then
        echo "$output"
    else
        echo "No active connections."
    fi
}

print_service_status() {
    echo "========================================"
    echo "Dante service status: $(date '+%Y-%m-%d %H:%M:%S')"
    if systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null; then
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            echo "- Current state: running"
        else
            echo "- Current state: stopped"
        fi
        systemctl status "${SERVICE_NAME}" --no-pager | sed -n '1,12p'
    else
        echo "- Current state: not installed"
    fi
    echo "========================================"
}

#================================================================
# CLI & Menu
#================================================================

show_usage() {
    echo "Dante Socks5 Proxy Management"
    echo "--------------------------------"
    echo "Usage: $0 <action> [arguments]"
    echo
    echo "Main actions:"
    echo "  install                  - install and configure Dante"
    echo "  uninstall                - remove Dante and cleanup"
    echo "  stop                     - stop Dante service"
    echo "  changeport <port>        - change listening port"
    echo "  changepass <username>    - update user password"
    echo "  renameuser <old> <new>   - rename proxy user"
    echo
    echo "Other management:"
    echo "  start                    - start Dante service"
    echo "  restart                  - restart service"
    echo "  status                   - show service status"
    echo "  adduser <username>       - add proxy user"
    echo "  deluser <username>       - delete proxy user"
    echo "  listusers                - list registered users"
    echo "  connections              - show current connections"
    echo
}

show_menu() {
    cat <<'EOF'

========= Dante Management Menu =========
[1] Install Dante
[2] Uninstall Dante
[3] Start service
[4] Stop service
[5] Restart service
[6] Change port
[7] Change user password
[8] Rename user
[9] Add user
[10] Delete user
[11] List users
[12] Show connections
[13] Service status
[0] Exit
=========================================
EOF
}

run_interactive() {
    print_service_status
    while true; do
        show_menu
        read -rp "Select an option: " choice
        case "$choice" in
            1) do_install ;;
            2) do_uninstall ;;
            3) do_start ;;
            4) do_stop ;;
            5) do_restart ;;
            6)
                read -rp "Enter new port: " port
                do_change_port "$port"
                ;;
            7)
                read -rp "Enter username: " user
                do_change_pass "$user"
                ;;
            8)
                read -rp "Enter old username: " old_user
                read -rp "Enter new username: " new_user
                do_rename_user "$old_user" "$new_user"
                ;;
            9)
                read -rp "Enter new username: " new_user
                do_add_user "$new_user"
                ;;
            10)
                read -rp "Enter username to delete: " target_user
                do_del_user "$target_user"
                ;;
            11) list_proxy_users ;;
            12) show_connection_info ;;
            13) do_status ;;
            0)
                echo "Goodbye."
                break
                ;;
            *)
                echo "Invalid selection."
                ;;
        esac
    done
}

#================================================================
# Main entry
#================================================================

check_root

if [ $# -eq 0 ]; then
    run_interactive
    exit 0
fi

ACTION="$1"
shift

case "$ACTION" in
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    stop)
        do_stop
        ;;
    changeport)
        do_change_port "$1"
        ;;
    changepass)
        do_change_pass "$1"
        ;;
    renameuser)
        do_rename_user "$1" "$2"
        ;;
    start)
        do_start
        ;;
    restart)
        do_restart
        ;;
    status)
        do_status
        ;;
    adduser)
        do_add_user "$1"
        ;;
    deluser)
        do_del_user "$1"
        ;;
    listusers)
        list_proxy_users
        ;;
    connections)
        show_connection_info
        ;;
    *)
        show_usage
        exit 1
        ;;
esac

exit 0

