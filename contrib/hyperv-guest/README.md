# hyperv-guest

Talos guests on Hyper-V do not ship Hyper-V **Key-Value Pair (KVP)** user-space daemons. Without them,
the host cannot populate `Get-VMNetworkAdapter.IPAddresses`, so automation still prompts for the Talos
console IP while Windows workers autodiscover via integration services.

This extension runs the upstream Linux Hyper-V tools as
[Talos extension services](https://www.talos.dev/latest/advanced/extension-services/):

| Service | Binary | Purpose |
| --- | --- | --- |
| `ext-hyperv-kvp` | `hv_kvp_daemon` | Guest intrinsic exchange: IPv4/IPv6, hostname, OS build → host `Get-VMNetworkAdapter` |
| `ext-hyperv-vss` | `hv_vss_daemon` | Application-consistent Hyper-V checkpoints (optional) |

Kernel side: Talos already includes `hv_vmbus` / `hv_utils` on Hyper-V. The daemons use `/dev/vmbus/hv_kvp`
and pools under `/var/lib/hyperv`.

## Layout (extension OCI image)

```
manifest.yaml
rootfs/
  usr/local/etc/containers/
    hyperv-kvp.yaml
    hyperv-vss.yaml
  usr/local/lib/containers/
    hyperv-kvp/
      hv_kvp_daemon
      run-hyperv-kvp.sh
    hyperv-vss/
      hv_vss_daemon
```

## Build

```bash
make hyperv-guest PLATFORM=linux/amd64
```

`manifest.yaml` is generated from `manifest.yaml.tmpl` and `vars.yaml` at build time (Sidero bldr convention). Sources are compiled from the pinned Linux `tools/hv/` tree (`LINUX_TOOLS_TAG` in `pkg.yaml`).

## Install on Talos (Hyper-V VMs)

1. **Enable integration services on the VM** (Data Exchange is required for KVP):

   ```powershell
   Enable-VMIntegrationService -VMName '<vm-name>' -Name 'Guest Service Interface'
   Enable-VMIntegrationService -VMName '<vm-name>' -Name 'Key-Value Pair Exchange'
   ```

2. **Bake the extension** via schematic or machine config (pin digest in production):

   ```bash
   talosctl gen config <cluster> https://<endpoint>:6443 \
     --config-patch @examples/machine-config.patch.yaml
   ```

3. **Verify on the node:**

   ```bash
   talosctl -n <node> services | grep ext-hyperv
   talosctl -n <node> logs ext-hyperv-kvp
   ```

4. **Verify on the Hyper-V host:**

   ```powershell
   Get-VMNetworkAdapter -VMName '<vm-name>' | Select-Object IPAddresses
   ```

   Helper: [`examples/Get-TalosVmReportedIpv4.ps1`](examples/Get-TalosVmReportedIpv4.ps1).

## References

- [Hyper-V KVP on Linux](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/integration-services-data-exchange)
- [Talos extension services](https://www.talos.dev/latest/advanced/extension-services/)
- [hello-world-service](https://github.com/siderolabs/extensions/tree/main/examples/hello-world-service)
