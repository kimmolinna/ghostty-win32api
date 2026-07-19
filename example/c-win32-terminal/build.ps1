# Build the #82 Win32 spike host using Zig as the C compiler (zig cc).
# Requires ghostty.dll from: zig build -Dapp-runtime=none

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "../..")
$ZigRoot = Resolve-Path (Join-Path $Root "../zig-0.15.2/zig-x86_64-windows-0.15.2") -ErrorAction SilentlyContinue
if (-not $ZigRoot) {
    # Fallback: zig on PATH
    $Zig = "zig"
} else {
    $Zig = Join-Path $ZigRoot "zig.exe"
}

$OutDir = Join-Path $PSScriptRoot "out"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$DllCandidates = @(
    (Join-Path $Root "zig-out/bin/ghostty.dll"),
    (Join-Path $Root "zig-out/lib/ghostty.dll")
)
$Dll = $DllCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Dll) {
    Write-Error "ghostty.dll not found. From repo root run: zig build -Dapp-runtime=none"
}

$LibDir = Split-Path $Dll -Parent
$Def = Join-Path $OutDir "ghostty.def"
$ImportLib = Join-Path $OutDir "ghostty.lib"

Write-Host "Using DLL: $Dll"
Write-Host "Using Zig: $Zig"

# Generate .def from DLL exports via Zig-friendly Python-free PowerShell
$bytes = [System.IO.File]::ReadAllBytes($Dll)
$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
$numSections = [BitConverter]::ToUInt16($bytes, $peOffset + 6)
$optHeaderSize = [BitConverter]::ToUInt16($bytes, $peOffset + 20)
$optHeader = $peOffset + 24
$magic = [BitConverter]::ToUInt16($bytes, $optHeader)
$dataDirOffset = if ($magic -eq 0x20B) { $optHeader + 112 } else { $optHeader + 96 }
$exportRva = [BitConverter]::ToUInt32($bytes, $dataDirOffset)
$sectionTable = $optHeader + $optHeaderSize

function RvaToOffset([uint32]$rva) {
    for ($i = 0; $i -lt $numSections; $i++) {
        $s = $sectionTable + $i * 40
        $va = [BitConverter]::ToUInt32($bytes, $s + 12)
        $vs = [BitConverter]::ToUInt32($bytes, $s + 8)
        $ro = [BitConverter]::ToUInt32($bytes, $s + 20)
        if ($rva -ge $va -and $rva -lt ($va + $vs)) {
            return [int]($rva - $va + $ro)
        }
    }
    return -1
}

$eo = RvaToOffset $exportRva
if ($eo -lt 0) { Write-Error "Could not map export directory" }
$nn = [BitConverter]::ToUInt32($bytes, $eo + 24)
$namesRva = [BitConverter]::ToUInt32($bytes, $eo + 32)
$nto = RvaToOffset $namesRva
$names = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $nn; $i++) {
    $nr = [BitConverter]::ToUInt32($bytes, $nto + $i * 4)
    $no = RvaToOffset $nr
    $end = $no
    while ($bytes[$end] -ne 0) { $end++ }
    $names.Add([System.Text.Encoding]::ASCII.GetString($bytes, $no, $end - $no))
}
$defLines = @("LIBRARY ghostty", "EXPORTS") + ($names | Sort-Object | ForEach-Object { "    $_" })
$defLines | Set-Content -Path $Def -Encoding ASCII

& $Zig dlltool -m i386:x86-64 -d $Def -l $ImportLib
if ($LASTEXITCODE -ne 0) { Write-Error "zig dlltool failed" }

$Include = Join-Path $Root "include"
$Src = Join-Path $PSScriptRoot "src/main.c"
$Exe = Join-Path $OutDir "c_win32_terminal.exe"

# Prefer MSVC ABI to match a typical ghostty.dll build; fall back to gnu.
$Target = "x86_64-windows-msvc"
Write-Host "Compiling with: $Zig cc -target $Target"

& $Zig cc -target $Target `
    $Src `
    "-I$Include" `
    $ImportLib `
    -luser32 -lgdi32 -ldwmapi -limm32 `
    -o $Exe

if ($LASTEXITCODE -ne 0) {
    Write-Host "MSVC target failed, retrying with gnu..."
    $Target = "x86_64-windows-gnu"
    & $Zig cc -target $Target `
        $Src `
        "-I$Include" `
        $ImportLib `
        -luser32 -lgdi32 -ldwmapi -limm32 `
        -o $Exe
    if ($LASTEXITCODE -ne 0) { Write-Error "zig cc failed" }
}

Copy-Item -Force $Dll (Join-Path $OutDir "ghostty.dll")
Write-Host "Built: $Exe"
Write-Host "Run:   $Exe"
