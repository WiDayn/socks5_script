#!/bin/bash

#================================================================
# Dante Socks5 Proxy Management Script for Ubuntu 22.04
#================================================================

# 变量
CONFIG_FILE="/etc/danted.conf"
LOG_FILE="/var/log/danted.log"
SERVICE_NAME="danted"
USER_REGISTRY="/var/lib/dante-proxy/users.list"

#================================================================
# 辅助函数
#================================================================

# 检查是否以 root 身份运行
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
       echo "错误：此脚本必须以 root (sudo) 权限运行。"
       exit 1
    fi
}

# 检查 Dante 是否已安装
check_installed() {
    if ! command -v danted &> /dev/null; then
        echo "错误：Dante Server (danted) 未安装。"
        echo "请先运行: $0 install"
        exit 1
    fi
}

# 重启服务并检查状态
restart_service() {
    echo "正在重启 ${SERVICE_NAME} 服务..."
    systemctl restart ${SERVICE_NAME}
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        echo "${SERVICE_NAME} 已成功重启。"
    else
        echo "错误：${SERVICE_NAME} 启动失败！"
        echo "请使用 'sudo journalctl -xeu ${SERVICE_NAME}' 查看日志。"
    fi
}

# 获取当前端口
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
# 主要功能
#================================================================

# 1. 安装
# 1. 安装 (已修正)
do_install() {
    echo "正在安装 Dante Socks5 服务器..."
    apt update >/dev/null
    apt install -y dante-server

    if [ $? -ne 0 ]; then
        echo "错误：Dante 服务器安装失败。"
        exit 1
    fi

    # 交互式设置
    read -p "请输入您想要的代理端口 (默认: 1080): " PROXY_PORT
    PROXY_PORT=${PROXY_PORT:-1080}

    read -p "请输入初始代理用户名 (默认: proxyuser): " PROXY_USER
    PROXY_USER=${PROXY_USER:-proxyuser}

    echo "正在自动检测外部网卡..."
    EXT_INTERFACE=$(ip route get 1.1.1.1 | awk '{print $5}' | head -n1)
    
    if [ -z "$EXT_INTERFACE" ]; then
        echo "错误：无法自动检测网卡。"
        echo "请手动运行 'ip addr show' 找到您的主网卡名 (例如 eth0, ens18)..."
        read -p "请输入您的主网卡名称: " EXT_INTERFACE
        if [ -z "$EXT_INTERFACE" ]; then
            echo "操作已取消。"
            exit 1
        fi
    else
        echo "检测到网卡: $EXT_INTERFACE"
    fi

    # 备份旧配置
    [ -f "$CONFIG_FILE" ] && mv "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%s)"

    # 写入新配置
    echo "正在创建配置文件: $CONFIG_FILE"
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

    # 创建用户
    echo "正在创建代理用户: $PROXY_USER"
    if id "$PROXY_USER" &>/dev/null; then
        echo "用户 $PROXY_USER 已存在。"
    else
        useradd --shell /usr/sbin/nologin "$PROXY_USER"
        if [ $? -ne 0 ]; then
            echo "错误：创建用户 $PROXY_USER 失败。"
            exit 1
        fi
    fi
    
    echo "--- 请为用户 $PROXY_USER 设置密码 ---"
    passwd "$PROXY_USER"
    echo "-----------------------------------"
    register_user "$PROXY_USER"

    # 配置防火墙
    echo "正在配置防火墙 (UFW)..."
    ufw allow $PROXY_PORT/tcp
    ufw reload

    # 
    # ===================== 
    #  *** 错误修正 ***
    # =====================
    # 在启动服务前，创建日志文件并分配 'nobody' 权限
    echo "正在创建并设置日志文件权限: $LOG_FILE"
    touch "$LOG_FILE"
    chown nobody:nogroup "$LOG_FILE"
    # =====================
    #

    # 启动并设为开机自启
    systemctl enable ${SERVICE_NAME}
    restart_service

    echo "---"
    echo "✅ Dante Socks5 代理安装并启动成功！"
    echo "   服务器IP: $(hostname -I | cut -d' ' -f1)"
    echo "   端口:     $PROXY_PORT"
    echo "   用户名:   $PROXY_USER"
    echo "---"
}

# 2. 卸载
do_uninstall() {
    echo "正在卸载 Dante Server..."
    check_installed
    
    CURRENT_PORT=$(get_current_port)

    systemctl stop ${SERVICE_NAME}
    systemctl disable ${SERVICE_NAME}
    
    apt purge -y dante-server
    
    rm -f "$CONFIG_FILE"
    rm -f "$LOG_FILE"
    rm -f "$USER_REGISTRY"
    
    if [ -n "$CURRENT_PORT" ]; then
        echo "正在关闭防火墙端口 $CURRENT_PORT..."
        ufw delete allow $CURRENT_PORT/tcp
        ufw reload
    fi
    
    echo "Dante Server 已卸载。"
    echo "注意：为Dante创建的系统用户 (例如 proxyuser) 不会自动删除。"
    echo "如果需要，请使用 'sudo userdel <用户名>' 手动删除。"
}

# 3. 停止
do_stop() {
    check_installed
    echo "正在停止 ${SERVICE_NAME} 服务..."
    systemctl stop ${SERVICE_NAME}
    echo "${SERVICE_NAME} 已停止。"
}

# 4. 修改端口
do_change_port() {
    check_installed
    NEW_PORT="$1"

    if [ -z "$NEW_PORT" ]; then
        echo "错误：未提供新端口。"
        echo "用法: $0 changeport <新端口号>"
        exit 1
    fi

    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo "错误：无效的端口号 (必须在 1-65535 之间)。"
        exit 1
    fi

    CURRENT_PORT=$(get_current_port)

    if [ -z "$CURRENT_PORT" ]; then
        echo "错误：无法从 $CONFIG_FILE 读取当前端口。"
        exit 1
    fi

    echo "正在将端口从 $CURRENT_PORT 更改为 $NEW_PORT..."
    
    # 1. 修改配置文件
    sed -i "s/port = $CURRENT_PORT/port = $NEW_PORT/" "$CONFIG_FILE"
    
    # 2. 修改防火墙
    ufw delete allow $CURRENT_PORT/tcp
    ufw allow $NEW_PORT/tcp
    ufw reload
    
    # 3. 重启服务
    restart_service
    echo "端口已成功修改为 $NEW_PORT。"
}

# 5. 修改密码
do_change_pass() {
    check_installed
    TARGET_USER="$1"
    
    if [ -z "$TARGET_USER" ]; then
        echo "错误：未提供用户名。"
        echo "用法: $0 changepass <用户名>"
        exit 1
    fi

    if ! id "$TARGET_USER" &>/dev/null; then
        echo "错误：用户 '$TARGET_USER' 不存在。"
        exit 1
    fi

    echo "--- 正在为用户 $TARGET_USER 修改密码 ---"
    passwd "$TARGET_USER"
    echo "-----------------------------------"
    echo "用户 $TARGET_USER 的密码已更新。"
}

# 6. 修改用户名 (重命名)
do_rename_user() {
    check_installed
    OLD_USER="$1"
    NEW_USER="$2"

    if [ -z "$OLD_USER" ] || [ -z "$NEW_USER" ]; then
        echo "错误：参数不足。"
        echo "用法: $0 renameuser <旧用户名> <新用户名>"
        exit 1
    fi

    if ! id "$OLD_USER" &>/dev/null; then
        echo "错误：旧用户 '$OLD_USER' 不存在。"
        exit 1
    fi
    
    if id "$NEW_USER" &>/dev/null; then
        echo "错误：新用户 '$NEW_USER' 已存在。"
        exit 1
    fi

    usermod -l "$NEW_USER" "$OLD_USER"
    unregister_user "$OLD_USER"
    register_user "$NEW_USER"
    echo "用户名已从 '$OLD_USER' 成功修改为 '$NEW_USER'。"
}

# (附赠) 其他常用功能
do_start() {
    check_installed
    echo "正在启动 ${SERVICE_NAME} 服务..."
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
        echo "错误：未提供用户名。"
        echo "用法: $0 adduser <新用户名>"
        exit 1
    fi

    if id "$NEW_USER" &>/dev/null; then
        echo "错误：用户 '$NEW_USER' 已存在。"
        exit 1
    fi

    echo "正在添加新用户: $NEW_USER"
    useradd --shell /usr/sbin/nologin "$NEW_USER"
    echo "--- 请为新用户 $NEW_USER 设置密码 ---"
    passwd "$NEW_USER"
    echo "-----------------------------------"
    register_user "$NEW_USER"
    echo "用户 $NEW_USER 添加成功。"
}

do_del_user() {
    check_installed
    TARGET_USER="$1"
    if [ -z "$TARGET_USER" ]; then
        echo "错误：未提供用户名。"
        echo "用法: $0 deluser <用户名>"
        exit 1
    fi

    if ! id "$TARGET_USER" &>/dev/null; then
        echo "错误：用户 '$TARGET_USER' 不存在。"
        exit 1
    fi
    
    read -p "确定要删除系统用户 '$TARGET_USER' 吗? [y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        userdel "$TARGET_USER"
        unregister_user "$TARGET_USER"
        echo "用户 '$TARGET_USER' 已删除。"
    else
        echo "操作已取消。"
    fi
}

list_proxy_users() {
    check_installed
    ensure_user_registry
    echo "=== 当前登记的代理用户 ==="
    if [ ! -s "$USER_REGISTRY" ]; then
        echo "暂无记录。"
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
            echo " - $user (系统中未找到，建议清理)"
        fi
    done < "$USER_REGISTRY"
}

show_connection_info() {
    check_installed
    local current_port
    current_port=$(get_current_port)
    echo "=== 当前连接信息 (监听端口: ${current_port:-未知}) ==="
    if ! command -v ss &>/dev/null; then
        echo "系统未安装 'ss' 命令，无法显示连接。"
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
        echo "暂无活跃连接。"
    fi
}

print_service_status() {
    echo "========================================"
    echo "Dante 服务状态: $(date '+%Y-%m-%d %H:%M:%S')"
    if systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null; then
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            echo "- 当前状态: 运行中"
        else
            echo "- 当前状态: 未运行"
        fi
        systemctl status "${SERVICE_NAME}" --no-pager | sed -n '1,12p'
    else
        echo "- 当前状态: 未安装"
    fi
    echo "========================================"
}


# 帮助菜单
show_usage() {
    echo "Dante Socks5 代理管理脚本"
    echo "--------------------------------"
    echo "用法: $0 <action> [arguments]"
    echo
    echo "主要操作:"
    echo "  install                  - 安装并配置 Dante 服务"
    echo "  uninstall                - 卸载 Dante 服务并清理配置"
    echo "  stop                     - 停止 Dante 服务"
    echo "  changeport <新端口>        - 修改代理监听端口"
    echo "  changepass <用户名>        - 修改指定用户的密码"
    echo "  renameuser <旧> <新>   - 重命名一个代理用户 (修改用户名)"
    echo
    echo "其他管理:"
    echo "  start                    - 启动 Dante 服务"
    echo "  restart                  - 重启 Dante 服务"
    echo "  status                   - 查看 Dante 服务状态"
    echo "  adduser <用户名>         - 添加一个新的代理用户"
    echo "  deluser <用户名>         - 删除一个代理用户"
    echo "  listusers                - 查看登记的代理用户"
    echo "  connections              - 查看当前连接信息"
    echo
}

show_menu() {
    cat <<'EOF'

========= Dante 管理菜单 =========
[1] 安装 Dante
[2] 卸载 Dante
[3] 启动服务
[4] 停止服务
[5] 重启服务
[6] 修改端口
[7] 修改用户密码
[8] 重命名用户
[9] 添加用户
[10] 删除用户
[11] 查看用户列表
[12] 查看连接信息
[13] 查看服务状态
[0] 退出
=================================
EOF
}

run_interactive() {
    print_service_status
    while true; do
        show_menu
        read -rp "请选择操作: " choice
        case "$choice" in
            1) do_install ;;
            2) do_uninstall ;;
            3) do_start ;;
            4) do_stop ;;
            5) do_restart ;;
            6)
                read -rp "请输入新的端口号: " port
                do_change_port "$port"
                ;;
            7)
                read -rp "请输入需要修改密码的用户名: " user
                do_change_pass "$user"
                ;;
            8)
                read -rp "请输入旧用户名: " old_user
                read -rp "请输入新用户名: " new_user
                do_rename_user "$old_user" "$new_user"
                ;;
            9)
                read -rp "请输入新用户名: " new_user
                do_add_user "$new_user"
                ;;
            10)
                read -rp "请输入要删除的用户名: " target_user
                do_del_user "$target_user"
                ;;
            11) list_proxy_users ;;
            12) show_connection_info ;;
            13) do_status ;;
            0)
                echo "操作结束，再见。"
                break
                ;;
            *)
                echo "无效选项，请重新输入。"
                ;;
        esac
    done
}

#================================================================
# 主程序入口
#================================================================

check_root

if [ $# -eq 0 ]; then
    run_interactive
    exit 0
fi

ACTION="$1"
shift # 移除第一个参数，方便后续参数传递

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