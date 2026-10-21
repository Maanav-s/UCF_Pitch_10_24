# Network setup for the laptop trader on Windows.
#
# The FPGA exchange sends market data to MAC 02:00:00:00:00:01 /
# 192.168.10.1:5000 and does not answer ARP. This script sets up the Ethernet
# adapter the exchange is cabled to so it receives those frames and can reply:
#   - MAC address 02-00-00-00-00-01 (the adapter's driver must support the
#     "Network Address" setting; most do)
#   - static IP 192.168.10.1/24, DHCP off
#   - permanent ARP entry: 192.168.10.2 -> 02-00-00-00-00-02 (the exchange)
#   - firewall rule allowing inbound UDP 5000
#   - interrupt moderation off, if the driver has that setting (lower latency)
#
# Run in PowerShell as Administrator, from the repo folder:
#   Get-NetAdapter                      # find the adapter name, e.g. "Ethernet 2"
#   powershell -ExecutionPolicy Bypass -File host\setup_windows.ps1 -Adapter "Ethernet 2"
# Undo everything:
#   powershell -ExecutionPolicy Bypass -File host\setup_windows.ps1 -Adapter "Ethernet 2" -Restore

#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory = $true)][string]$Adapter,
    [switch]$Restore
)

$ErrorActionPreference = "Stop"

$TraderMac   = "02-00-00-00-00-01"
$TraderIp    = "192.168.10.1"
$ExchangeIp  = "192.168.10.2"
$ExchangeMac = "02-00-00-00-00-02"
$Port        = 5000
$RuleName    = "UCF tick-to-trade UDP $Port"

$nic = Get-NetAdapter -Name $Adapter
Write-Host "Adapter: $($nic.Name) ($($nic.InterfaceDescription)), MAC $($nic.MacAddress)"

function Set-InterruptModeration([string]$Value) {
    $prop = Get-NetAdapterAdvancedProperty -Name $Adapter -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "Interrupt Moderation*" -and $_.DisplayName -notlike "*Rate*" }
    if ($prop) {
        Set-NetAdapterAdvancedProperty -Name $Adapter -DisplayName $prop.DisplayName -DisplayValue $Value
        Write-Host "Interrupt moderation: $Value"
    } else {
        Write-Host "Interrupt moderation: no such setting on this adapter, skipped"
    }
}

if ($Restore) {
    Remove-NetNeighbor -InterfaceAlias $Adapter -IPAddress $ExchangeIp -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetIPAddress -InterfaceAlias $Adapter -IPAddress $TraderIp -Confirm:$false -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceAlias $Adapter -Dhcp Enabled
    Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    Set-InterruptModeration "Enabled"
    Reset-NetAdapterAdvancedProperty -Name $Adapter -RegistryKeyword "NetworkAddress" -ErrorAction SilentlyContinue
    Write-Host "Restored: DHCP on, original MAC, ARP entry and firewall rule removed."
    exit 0
}

# MAC first: changing it restarts the adapter.
Set-NetAdapter -Name $Adapter -MacAddress $TraderMac -Confirm:$false
Start-Sleep -Seconds 5
$mac = (Get-NetAdapter -Name $Adapter).MacAddress
if ($mac -ne $TraderMac) {
    Write-Warning "MAC is $mac, not $TraderMac. The driver may not support changing it; try another adapter."
}

# Static IP.
Set-NetIPInterface -InterfaceAlias $Adapter -Dhcp Disabled
Get-NetIPAddress -InterfaceAlias $Adapter -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceAlias $Adapter -IPAddress $TraderIp -PrefixLength 24 | Out-Null

# Permanent ARP entry for the exchange.
Remove-NetNeighbor -InterfaceAlias $Adapter -IPAddress $ExchangeIp -Confirm:$false -ErrorAction SilentlyContinue
New-NetNeighbor -InterfaceAlias $Adapter -IPAddress $ExchangeIp -LinkLayerAddress $ExchangeMac -State Permanent | Out-Null

# Firewall: the link has no gateway, so Windows usually calls it a Public
# network. The rule applies to all profiles.
if (-not (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol UDP `
        -LocalPort $Port -Action Allow -Profile Any | Out-Null
}

Set-InterruptModeration "Disabled"

Write-Host ""
Write-Host "Done:"
Write-Host "  MAC   $((Get-NetAdapter -Name $Adapter).MacAddress)"
Get-NetIPAddress -InterfaceAlias $Adapter -AddressFamily IPv4 |
    ForEach-Object { Write-Host "  IP    $($_.IPAddress)/$($_.PrefixLength)" }
Get-NetNeighbor -InterfaceAlias $Adapter -IPAddress $ExchangeIp |
    ForEach-Object { Write-Host "  ARP   $($_.IPAddress) -> $($_.LinkLayerAddress) ($($_.State))" }
Write-Host ""
Write-Host "Now run:  python host\laptop_trader.py"
