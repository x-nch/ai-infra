# AI Infrastructure Documentation

## Network Topology

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Home Network                                   │
│                         192.168.1.0/24                                   │
│                              ↑                                           │
│                    WiFi Router / Gateway                                 │
│                     192.168.1.1 (gateway)                                │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
          ┌──────────────────────┴───────────────────────┐
          │                                              │
          ↓                                              ↓
┌─────────────────────┐                      ┌─────────────────────┐
│       i7 Server     │                      │        i9 Server    │
│                     │                      │                     │
│  wlp4s0 (WiFi)      │    LAN Cable         │  enp3s0 (Ethernet)  │
│  MAC: ac:12:03:...  │◄────────────────────►│  MAC: d8:43:ae:...  │
│  IP: 192.168.1.8    │                      │  IP: 192.168.50.2   │
│                     │                      │                     │
│  enp5s0 (Ethernet)  │                      │  wlp4s0 (WiFi)      │
│  MAC: 3c:7c:3f:...  │                      │  IP: 192.168.1.10   │
│  IP: 192.168.50.1   │                      │                     │
│                     │                      │                     │
│  Purpose:           │                      │  Purpose:           │
│  - AI workloads     │                      │  - Wake target      │
│  - Network gateway  │                      │  - SSH accessible    │
│  - WoL controller  │                      │                     │
└─────────────────────┘                      └─────────────────────┘
```

## Device Summary

| Device | Hostname | LAN Interface | MAC Address | IP Address | WiFi Interface | WiFi IP |
|--------|----------|---------------|-------------|------------|----------------|---------|
| i7     | i7-server | enp5s0        | 3c:7c:3f:5a:a3:cc | 192.168.50.1 | wlp4s0 | 192.168.1.8 |
| i9     | i9-wake   | enp3s0        | d8:43:ae:9e:93:52 | 192.168.50.2 | wlp4s0 | 192.168.1.10 |

## i7 Server Configuration

### Network Interfaces

#### WiFi (Internet)
- **Interface**: wlp4s0
- **MAC**: ac:12:03:40:54:3e
- **IP**: 192.168.1.8/24
- **Gateway**: 192.168.1.1

#### LAN (to i9)
- **Interface**: enp5s0
- **MAC**: 3c:7c:3f:5a:a3:cc
- **IP**: 192.168.50.1/24
- **Purpose**: Direct connection to i9 for WoL and SSH

### Netplan Configuration

**File**: `/etc/netplan/default.yaml`

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp5s0:
      dhcp4: true
      addresses:
        - 192.168.50.1/24
```

### Routing Table

```
default via 192.168.1.1 dev wlp4s0    # WiFi gateway
192.168.1.0/24 dev wlp4s0         # Home network
192.168.50.0/24 dev enp5s0         # LAN subnet
```

## i9 Server Configuration

### Network Interfaces

#### LAN (Primary)
- **Interface**: enp3s0
- **MAC**: d8:43:ae:9e:93:52
- **IP**: 192.168.50.2/24
- **Purpose**: WoL wake target, SSH from i7

#### WiFi (Internet)
- **Interface**: wlp4s0
- **MAC**: e8:65:38:89:78:c9
- **IP**: 192.168.1.10/24

### Routing Table

```
default via 192.168.1.1 dev wlp4s0   # WiFi gateway
192.168.1.0/24 dev wlp4s0        # Home network
192.168.50.0/24 dev enp3s0       # LAN subnet
```

### SSH Configuration

**File**: `/etc/ssh/sshd_config`

```
ListenAddress 0.0.0.0    # Listen on all interfaces
Port 22
PermitRootLogin without-password
PubkeyAuthentication yes
PasswordAuthentication yes
```

**Note**: After modifying sshd_config, run:
```bash
sudo systemctl daemon-reload
sudo systemctl restart ssh.socket
```

## Wake-on-LAN (WoL) Setup

### Overview

The i7 server sends WoL magic packets to wake the i9 server from sleep/shutdown.

### i9 WoL Configuration

WoL must be enabled on the target machine (i9) and persists via systemd service.

#### Systemd Service

**File**: `/etc/systemd/system/wol.service`

```ini
[Unit]
Description=Enable Wake-on-LAN on boot
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s enp3s0 wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

**Enable on boot**:
```bash
sudo systemctl enable wol.service
```

**Verify WoL status**:
```bash
sudo ethtool enp3s0 | grep -i wake
```

### WoL Commands on i7

#### Alias (in ~/.bashrc)

```bash
alias wakecore='wakeonlan -i 192.168.50.255 d8:43:ae:9e:93:52'
```

#### /usr/local/bin/wakecore Script

```bash
#!/bin/bash
wakeonlan d8:43:ae:9e:93:52
```

#### Usage

From any directory, simply run:
```bash
wakecore
```

Or with explicit broadcast address:
```bash
wakeonlan -i 192.168.50.255 d8:43:ae:9e:93:52
```

### WoL Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| Target MAC | d8:43:ae:9e:93:52 | i9 enp3s0 interface |
| Broadcast IP | 192.168.50.255 | LAN subnet broadcast |
| Protocol | UDP port 9 | Standard WoL port |
| Interface | enp5s0 | Source on i7 |

## SSH Access

### From i7 to i9

#### Via LAN (192.168.50.x subnet)
```bash
ssh 192.168.50.2
```

#### Via WiFi (192.168.1.x subnet)
```bash
ssh 192.168.1.10
```

### SSH Key Setup

For passwordless SSH, copy your public key:
```bash
ssh-copy-id 192.168.50.2
```

### SSH Config (optional)

Add to `~/.ssh/config` for easier access:

```
Host i9-lan
    HostName 192.168.50.2
    User <username>

Host i9-wifi
    HostName 192.168.1.10
    User <username>
```

Then simply run:
```bash
ssh i9-lan   # Via LAN
ssh i9-wifi  # Via WiFi
```

## Troubleshooting

### Check Interface Status

**i7**:
```bash
ip addr show enp5s0
ip route
```

**i9**:
```bash
ssh 192.168.50.2 "ip addr show enp3s0"
```

### Verify Connectivity

**Ping i9 from i7**:
```bash
ping 192.168.50.2
```

**Check ARP table**:
```bash
ip neigh show 192.168.50.2
```

### Restart Network on i7

```bash
sudo netplan apply
```

### Restart SSH on i9

```bash
ssh 192.168.50.2 "sudo systemctl restart ssh.socket"
```

### Test WoL

1. Shutdown i9:
   ```bash
   ssh 192.168.50.2 "sudo shutdown -h now"
   ```

2. Wait for i9 to fully shutdown (ping will timeout)

3. Send WoL packet:
   ```bash
   wakecore
   ```

4. Wait 10-30 seconds for i9 to boot

5. Verify with ping:
   ```bash
   ping 192.168.50.2
   ```

6. SSH in:
   ```bash
   ssh 192.168.50.2
   ```

### WoL Not Working

1. Verify WoL enabled on i9:
   ```bash
   ssh 192.168.50.2 "sudo ethtool enp3s0 | grep Wake-on"
   ```
   Should show `g` (magic packet enabled)

2. Check broadcast routing on i7:
   ```bash
   ip route | grep 192.168.50
   ```

3. Try direct MAC (requires root):
   ```bash
   sudo ether-wake -i enp5s0 d8:43:ae:9e:93:52
   ```

## Quick Reference

| Action | Command |
|--------|---------|
| Wake i9 | `wakecore` |
| SSH to i9 (LAN) | `ssh 192.168.50.2` |
| SSH to i9 (WiFi) | `ssh 192.168.1.10` |
| Shutdown i9 | `ssh 192.168.50.2 sudo shutdown -h now` |
| Check i9 status | `ping 192.168.50.2` |
| Restart network | `sudo netplan apply` |
