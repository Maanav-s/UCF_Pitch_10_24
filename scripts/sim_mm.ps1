# Runs one of the two-trader exchange testbenches in xsim without the Vivado
# project, from a PowerShell where Vivado's settings64.bat has been applied
# (or with <Vivado>\bin on PATH):
#
#   powershell -File scripts\sim_mm.ps1 tb_mm_frames
#   powershell -File scripts\sim_mm.ps1 tb_mm_trader
#   powershell -File scripts\sim_mm.ps1 tb_mm_exchange
#   powershell -File scripts\sim_mm.ps1 tb_mm_e2e
#
# Regenerates the vectors (tools/mm_vectors.py) and the FIX package first,
# compiles into sim\xsim_mm\, elaborates with the XPM library and runs to
# $finish. Look for "<TB> PASS" at the end of the log.

param(
    [Parameter(Mandatory = $true)][string]$Top
)

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$work = Join-Path $root "sim\xsim_mm"
New-Item -ItemType Directory -Force $work | Out-Null

python (Join-Path $root "tools\mm_fix.py") --sv (Join-Path $root "rtl\mm\mm_fix_pkg.sv")
if (-not $?) { exit 1 }
python (Join-Path $root "tools\mm_vectors.py")
if (-not $?) { exit 1 }

$src = @(
    "rtl\mm\mm_fix_pkg.sv", "rtl\mm\mm_pkg.sv", "rtl\board2_eth\crc32.sv",
    "rtl\board2_eth\rmii_rx.sv", "rtl\board2_eth\rmii_tx.sv", "rtl\common\bin2bcd.sv",
    "rtl\common\debounce.sv", "rtl\common\sevenseg.sv", "rtl\common\uart_tx.sv",
    "rtl\mm\fix_frame_gen.sv", "rtl\mm\fix_frame_parse.sv", "rtl\mm\rmii_port.sv",
    "rtl\mm\mm_book.sv", "rtl\mm\mm_event_log.sv", "rtl\mm\mm_dump.sv",
    "rtl\mm\mm_exchange.sv", "rtl\mm\mm_trader.sv", "rtl\mm\mm_top.sv",
    "sim\mm_tb_port.sv", "sim\$Top.sv"
) | ForEach-Object { Join-Path $root $_ }

Set-Location $work
xvlog -sv -L xpm @src
if (-not $?) { exit 1 }
# The vectors are read relative to the xsim working directory.
xelab -L xpm -L unisims_ver -debug typical -generic_top "VEC_DIR=../mm" -top $Top -snapshot "${Top}_snap"
if (-not $?) { exit 1 }
xsim "${Top}_snap" -R
