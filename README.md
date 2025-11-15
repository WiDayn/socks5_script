# Socks5 Proxy Management Script

Tested in `Debian 12.2`

## UI
```bash
========================================
Dante service status: 2025-11-15 17:58:27
- Current state: running
● danted.service - SOCKS (v4 and v5) proxy daemon (danted)
     Loaded: loaded (/lib/systemd/system/danted.service; enabled; preset: enabled)
     Active: active (running) since Sat 2025-11-15 17:32:03 CST; 26min ago
       Docs: man:danted(8)
             man:danted.conf(5)
    Process: 817769 ExecStartPre=/bin/sh -c     uid=`sed -n -e "s/[[:space:]]//g" -e "s/#.*//" -e "/^user\.privileged/{s/[^:]*://p;q;}" /etc/danted.conf`;      if [ -n "$uid" ]; then            touch /var/run/danted.pid;              chown $uid /var/run/danted.pid;         fi       (code=exited, status=0/SUCCESS)
   Main PID: 817773 (danted)
      Tasks: 22 (limit: 435)
     Memory: 12.6M
        CPU: 4.530s
     CGroup: /system.slice/danted.service
             ├─817773 /usr/sbin/danted
========================================

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
```

## Usage
### English Version
```bash
wget https://raw.githubusercontent.com/WiDayn/socks5_script/refs/heads/main/script.en.sh && chmod +x ./script.en.sh && ./script.en.sh
```

### Chinese Version
```bash
wget https://raw.githubusercontent.com/WiDayn/socks5_script/refs/heads/main/script.cn.sh && chmod +x ./script.cn.sh && ./script.cn.sh
```