# GPU-aware Dell fan control for Proxmox

This repo contains a small two-part setup for using GPU temperatures from a passthrough VM/render node to control Dell PowerEdge chassis fans from the Proxmox host.

It is useful when:

- GPUs are passed through to a VM.
- iDRAC cannot see the real GPU temperatures.
- Dell's automatic fan logic does not react to GPU heat.
- Static manual fan speed is either too loud or not safe enough.

## Architecture

```text
GPU VM / render node
  nvidia-smi
      ↓
  /mnt/nas_ai/shared/gpu_fan_bridge/gpu_temp
      ↓
Proxmox host
  gpu-fan-control.sh
      ↓
  ipmitool raw Dell fan control
```

The VM exports:

```text
/mnt/nas_ai/shared/gpu_fan_bridge/gpu_temp
/mnt/nas_ai/shared/gpu_fan_bridge/gpu_temps_detail
/mnt/nas_ai/shared/gpu_fan_bridge/heartbeat
/mnt/nas_ai/shared/gpu_fan_bridge/status
```

The Proxmox host reads those files and sets Dell chassis fan speed.

## Files

```text
scripts/gpu-temp-export.sh         # run inside the GPU VM/render node
scripts/gpu-fan-control.sh         # run on the Proxmox host
systemd/gpu-temp-export.service    # VM service
systemd/gpu-fan-control.service    # Proxmox oneshot service
systemd/gpu-fan-control.timer      # Proxmox timer
```

## Requirements

### GPU VM / render node

- NVIDIA driver working
- `nvidia-smi` available
- shared NAS/NFS mount available at `/mnt/nas_ai/shared`

### Proxmox host

- `ipmitool`
- same shared NAS/NFS mount available at `/mnt/nas_ai/shared`
- Dell server that supports the Dell raw fan commands

Install ipmitool on Proxmox:

```bash
apt update
apt install -y ipmitool
```

## Install on the GPU VM / render node

Copy:

```bash
sudo cp scripts/gpu-temp-export.sh /usr/local/bin/gpu-temp-export.sh
sudo chmod +x /usr/local/bin/gpu-temp-export.sh
sudo cp systemd/gpu-temp-export.service /etc/systemd/system/gpu-temp-export.service
sudo systemctl daemon-reload
sudo systemctl enable --now gpu-temp-export.service
```

Watch logs:

```bash
sudo journalctl -u gpu-temp-export.service -f
```

Check output:

```bash
cat /mnt/nas_ai/shared/gpu_fan_bridge/gpu_temp
cat /mnt/nas_ai/shared/gpu_fan_bridge/gpu_temps_detail
cat /mnt/nas_ai/shared/gpu_fan_bridge/heartbeat
cat /mnt/nas_ai/shared/gpu_fan_bridge/status
```

## Install on the Proxmox host

Copy:

```bash
cp scripts/gpu-fan-control.sh /usr/local/sbin/gpu-fan-control.sh
chmod +x /usr/local/sbin/gpu-fan-control.sh
cp systemd/gpu-fan-control.service /etc/systemd/system/gpu-fan-control.service
cp systemd/gpu-fan-control.timer /etc/systemd/system/gpu-fan-control.timer
systemctl daemon-reload
systemctl enable --now gpu-fan-control.timer
```

Watch logs:

```bash
tail -f /var/log/gpu-fan-control.log
```

Check state:

```bash
cat /run/gpu-fan-state
```

## Default fan curve

The Proxmox script uses fan levels rather than raw one-shot thresholds.

| Temp | Level |
| --- | --- |
| `<65C` | 32% |
| `65C+` | 40% |
| `72C+` | 50% |
| `78C+` | 60% |
| `84C+` | 80% |
| `88C+` | 100% |
| `92C+` | immediate 100% |

It also has:

- hysteresis
- minimum hold time
- one-step fan transitions
- stale heartbeat handling
- 100% failsafe for long stale data

## Emergency quiet command

On Proxmox:

```bash
systemctl stop gpu-fan-control.timer
ipmitool raw 0x30 0x30 0x01 0x00
ipmitool raw 0x30 0x30 0x02 0xff 0x28
```

That sets manual fan mode around 40%.

## Return to Dell automatic mode

```bash
ipmitool raw 0x30 0x30 0x01 0x01
```

## Secure Boot warning for GPU VMs

If `nvidia-smi` fails after reboot and `modprobe nvidia` says:

```text
Key was rejected by service
```

then Secure Boot is blocking the NVIDIA kernel module. On Proxmox VMs with OVMF, this can happen when the EFI disk was created with pre-enrolled keys.

Check inside the VM:

```bash
mokutil --sb-state
dkms status
sudo modprobe nvidia
```

If Secure Boot is enabled, either disable validation through MOK or recreate the VM EFI variable store without pre-enrolled keys.

## Important safety note

This setup intentionally does not fall back to iDRAC automatic fan control when GPU data is stale. On systems where iDRAC does not see passed-through GPU temperatures, automatic fan control may be too slow or unaware of the GPU heat. Long stale data forces 100% instead.
