# Poll Hyper-V for a Talos guest IPv4 (requires hyper-v-linux-guest extension + Data Exchange enabled).
function Get-TalosVmReportedIpv4Candidates {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $VMName
  )
  $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
  if (-not $vm -or $vm.State -ne 'Running') { return @() }
  $list = [System.Collections.Generic.List[string]]::new()
  foreach ($adapter in Get-VMNetworkAdapter -VMName $VMName -ErrorAction SilentlyContinue) {
    if (-not $adapter.IPAddresses) { continue }
    foreach ($addrRaw in @($adapter.IPAddresses)) {
      if ([string]::IsNullOrWhiteSpace([string]$addrRaw)) { continue }
      $s = [string]$addrRaw
      if ($s.IndexOf(':') -ge 0) { continue }
      try { $parsed = [System.Net.IPAddress]::Parse($s) } catch { continue }
      if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
      $b = $parsed.GetAddressBytes()
      if ($b[0] -eq 127) { continue }
      if ($b[0] -eq 169 -and $b[1] -eq 254) { continue }
      if (-not $list.Contains($s)) { $list.Add($s) }
    }
  }
  return @($list | Sort-Object)
}

function Resolve-TalosVmIpFromHyperV {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $VMName,
    [int] $TimeoutSeconds = 180,
    [int] $PollIntervalSeconds = 5
  )
  $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
  while ((Get-Date) -lt $deadline) {
    $cand = @(Get-TalosVmReportedIpv4Candidates -VMName $VMName)
    if ($cand.Count -gt 0) { return $cand[0] }
    Start-Sleep -Seconds ([Math]::Max(1, $PollIntervalSeconds))
  }
  return $null
}
