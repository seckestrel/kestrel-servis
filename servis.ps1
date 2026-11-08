<#
    =====================================================================
     KESTRELTECH SERVIS TOOLKIT  v2.0  (graficki interfejs)
     Servisni alat za Windows 10 / 11
    ---------------------------------------------------------------------
     Pokretanje : dupli klik na "Pokreni-Servis.bat"
                  (skripta sama trazi Administrator prava)
     Izvjestaji : .\Izvjestaji\<RACUNAR>_<datum>\
     Drajveri   : .\Drajveri\<proizvodjac_model>\
     Backup     : .\Backup\
     Programi   : .\Programi\   (winget liste)
     Alati      : .\Alati\      (ubaci portable alate, pokreces iz programa)
    =====================================================================
#>

# ============================ PODESAVANJA ============================
$Firma   = 'KestrelTech'
$Verzija = '3.2'

# Podaci firme za zaglavlje izvjestaja (prazno = ne prikazuje se).
# Logo: stavi logo.png (ili .jpg) pored ove skripte i pojavice se u izvjestaju.
$FirmaAdresa  = ''
$FirmaTelefon = ''
$FirmaEmail   = ''
$Valuta       = 'KM'
$GenerisiPDF  = $true     # uz HTML automatski napravi i PDF izvjestaj (preko Edge-a)

# Azuriranje i podrska
$UpdateUrl    = 'https://raw.githubusercontent.com/seckestrel/kestrel-servis/main/verzija.json'
$PodrskaEmail = ''        # email na koji testeri salju prijave gresaka (prazno = samo napravi ZIP)

# Standardni paket programa (winget ID). ID nadjes sa: winget search <naziv>
$StandardniProgrami = @(
    'Google.Chrome'
    'Mozilla.Firefox'
    '7zip.7zip'
    'VideoLAN.VLC'
    'Adobe.Acrobat.Reader.64-bit'
    'Notepad++.Notepad++'
)
# =====================================================================


# ---------------------------------------------------------------------
#  START: admin prava + STA
# ---------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ErrorAction Stop `
            -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    } catch {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show('Alat treba Administrator prava da bi radio.', $Firma)
    }
    exit
}
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Data
try {
    Add-Type -Namespace KT -Name Win -ErrorAction Stop -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
} catch {}

try {
    Add-Type -Namespace KT -Name Dwm -ErrorAction Stop -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int attrValue, int attrSize);
'@
} catch {}

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------
#  Folderi i dijeljeno stanje
# ---------------------------------------------------------------------
$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }
$Stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'

$ReportDir = Join-Path $Root ('Izvjestaji\{0}_{1}' -f $env:COMPUTERNAME, $Stamp)
try {
    New-Item -ItemType Directory -Path $ReportDir -Force -ErrorAction Stop | Out-Null
} catch {
    $ReportDir = Join-Path ([Environment]::GetFolderPath('Desktop')) ('{0}_Servis_{1}_{2}' -f $Firma, $env:COMPUTERNAME, $Stamp)
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
}
New-Item -ItemType Directory -Path (Join-Path $Root 'Alati') -Force -ErrorAction SilentlyContinue | Out-Null

$sync = [hashtable]::Synchronized(@{})
$sync.Queue     = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync.Done      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.Root      = $Root
$sync.ReportDir = $ReportDir
$sync.LogFile   = Join-Path $ReportDir 'servis_log.txt'
$sync.Firma     = $Firma
$sync.Verzija   = $Verzija
$sync.Stamp     = $Stamp
$sync.Client    = ''
$sync.Note      = ''
$sync.Dash      = $null
$sync.DashReady = $false
$sync.Programs     = $null
$sync.ShowPrograms = $false
# v3
$sync.Valuta        = $Valuta
$sync.FirmaAdresa   = $FirmaAdresa
$sync.FirmaTelefon  = $FirmaTelefon
$sync.FirmaEmail    = $FirmaEmail
$sync.GenerisiPDF   = $GenerisiPDF
$sync.DoneKeys      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.StartupOff    = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.StartupDel    = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.WorkItems     = @()
$sync.Discount      = 0.0
$sync.Phone         = ''
$sync.NalogBroj     = ''
$sync.SessionStarted = ''
$sync.Baseline      = $null
$sync.SaveSession   = $false
$sync.StartupItems  = $null
$sync.ShowStartup   = $false
$sync.DebloatFound  = $null
$sync.ShowDebloat   = $false
$sync.SensorRows    = @()
$sync.SensorSummary = $null
$sync.SensorNote    = ''
$sync.SensorStamp   = 0
$sync.StopSensors   = $false
$sync.WantLhm       = $false
$sync.StopStress    = $false
$sync.TempMax       = [hashtable]::Synchronized(@{})
$sync.AskRestart    = $false
$sync.ResultMsg     = ''
$sync.OfferLocation = $false
$sync.LogoB64        = $null
$sync.UpdateUrl      = $UpdateUrl
$sync.ScriptPath     = $PSCommandPath
$sync.UpdateInfo     = $null
$sync.ShowUpdate     = $false
$sync.AskRelaunch    = $false

# Sesija servisa se cuva na USB-u po racunaru (serijski broj), da se moze nastaviti nakon restarta
$SerialRaw = ''
try { $SerialRaw = "$((Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber)".Trim() } catch {}
if ($SerialRaw -match '(?i)^(to be filled.*|default string|system serial number|none|n/?a|0+)?$') { $SerialRaw = '' }
$SessionKey = $env:COMPUTERNAME
if ($SerialRaw) { $SessionKey += '_' + $SerialRaw }
$SessionKey  = $SessionKey -replace '[\\/:*?"<>|\s]', '_'
$SessionDir  = Join-Path $Root "Servisi\$SessionKey"
$SessionFile = Join-Path $SessionDir 'sesija.json'
$sync.SessionDir = $SessionDir


# =====================================================================
#  WORKER KOD - izvrsava se u pozadini (UI ne zamrzava)
# =====================================================================
$WorkerBlock = {

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$Root      = $sync.Root
$ReportDir = $sync.ReportDir
$LogFile   = $sync.LogFile
$Firma     = $sync.Firma
$Verzija   = $sync.Verzija
$Stamp     = $sync.Stamp
$Valuta    = $sync.Valuta
$PC        = $env:COMPUTERNAME

# ---------------- Log i pomocne funkcije ----------------
function Log {
    param([string]$Text, [string]$Level = 'info')
    $sync.Queue.Enqueue([pscustomobject]@{ T = (Get-Date -Format 'HH:mm:ss'); M = $Text; L = $Level })
    try { Add-Content -Path $LogFile -Value ('[{0}] {1,-4} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper(), $Text) -Encoding UTF8 -ErrorAction Stop } catch {}
}
function Section { param([string]$t) Log '' 'info'; Log ('-- {0} --' -f $t.ToUpper()) 'head' }
function Table {
    param($Data)
    $d = @($Data | Where-Object { $null -ne $_ })
    if ($d.Count -eq 0) { Log '(nema podataka)' 'dim'; return }
    $txt = ($d | Format-Table -AutoSize | Out-String -Width 200)
    foreach ($l in ($txt -split "`r?`n")) { if ($l.Trim()) { Log $l.TrimEnd() 'out' } }
}
function Add-Done {
    param([string]$t, [string]$Key = '')
    [void]$sync.Done.Add(('{0}  {1}' -f (Get-Date -Format 'dd.MM. HH:mm'), $t))
    if ($Key) { Add-DoneKey $Key }
    $sync.SaveSession = $true
}

function Format-Size {
    param($Bytes)
    if (-not $Bytes) { return '0 MB' }
    $b = [double]$Bytes
    if ($b -ge 1TB) { return ('{0:N2} TB' -f ($b / 1TB)) }
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    return ('{0:N0} MB' -f ($b / 1MB))
}
function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [double]0 }
    $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($s) { return [double]$s }
    return [double]0
}
function Get-FreeSpace {
    param([string]$Drive = $env:SystemDrive)
    return [double](Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $Drive)).FreeSpace
}
function Format-Date { param($d) if ($d) { return ([datetime]$d).ToString('dd.MM.yyyy HH:mm') } return '-' }
function HtmlEnc { param($s) return [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Read-SharedFile {
    param([string]$Path)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = New-Object System.IO.StreamReader($fs)
    try { return $sr.ReadToEnd() } finally { $sr.Close(); $fs.Close() }
}

# Pokrece komandu (DISM, SFC, chkdsk...) i salje izlaz u konzolu programa
function Run-Native {
    param([string]$Exe, [string[]]$Arguments = @(), [switch]$Utf8)
    Log ('> {0} {1}' -f $Exe, ($Arguments -join ' ')) 'cmd'
    $oldEnc = $null
    if ($Utf8) { try { $oldEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {} }
    $skip = [regex]('[{0}{1}]' -f [char]0x2588, [char]0x2592)
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object {
            $l = ("$_" -replace "`0", '')
            $parts = @($l -split "`r" | Where-Object { $_.Trim() })
            if ($parts.Count) {
                $last = $parts[-1].TrimEnd()
                if ($last.Trim().Length -gt 1 -and -not $skip.IsMatch($last)) { Log $last 'out' }
            }
        }
    } finally {
        if ($oldEnc) { try { [Console]::OutputEncoding = $oldEnc } catch {} }
    }
    return $LASTEXITCODE
}

function Test-Step {
    param([string]$Name, [scriptblock]$Test)
    $ok = $false
    try { $ok = [bool](& $Test) } catch {}
    if ($ok) { Log ('{0,-32} OK' -f $Name) 'ok' } else { Log ('{0,-32} NE RADI' -f $Name) 'err' }
}

function ConvertTo-HtmlTable {
    param($Data)
    $d = @($Data | Where-Object { $null -ne $_ })
    if ($d.Count -eq 0) { return "<p class='muted'>Nema podataka.</p>" }
    $props = @($d[0].PSObject.Properties | ForEach-Object { $_.Name })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><tr>')
    foreach ($p in $props) { [void]$sb.Append('<th>' + (HtmlEnc $p) + '</th>') }
    [void]$sb.Append('</tr>')
    foreach ($r in $d) {
        [void]$sb.Append('<tr>')
        foreach ($p in $props) { [void]$sb.Append('<td>' + (HtmlEnc $r.$p) + '</td>') }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>')
    return $sb.ToString()
}
function ConvertTo-KVTable {
    param($Obj)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table>')
    foreach ($p in $Obj.PSObject.Properties) {
        [void]$sb.Append("<tr><th style='width:28%'>" + (HtmlEnc $p.Name) + '</th><td>' + (HtmlEnc $p.Value) + '</td></tr>')
    }
    [void]$sb.Append('</table>')
    return $sb.ToString()
}

# ---------------- Prikupljanje podataka ----------------
function Get-BitLockerText {
    param([string]$Drive = $env:SystemDrive)
    try {
        if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
            $b = Get-BitLockerVolume -MountPoint $Drive -ErrorAction Stop
            if ("$($b.VolumeStatus)" -eq 'FullyDecrypted') { return 'Iskljucen' }
            return ('UKLJUCEN - zastita: {0}, status: {1} ({2}%)' -f $b.ProtectionStatus, $b.VolumeStatus, $b.EncryptionPercentage)
        }
    } catch {}
    try {
        $v = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $Drive) -ErrorAction Stop
        if ($v) {
            $st = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus -ErrorAction Stop
            if ($st.ConversionStatus -eq 0) { return 'Iskljucen' }
            if ($v.ProtectionStatus -eq 1) { return 'UKLJUCEN (zastita aktivna)' }
            return 'UKLJUCEN (zastita pauzirana)'
        }
    } catch {}
    return 'Nije moguce provjeriti'
}

function Get-BatteryInfo {
    $r = [pscustomobject]@{ Present = $false; Pct = $null; Text = 'Nema baterije (desktop racunar)' }
    $wb = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $wb) { return $r }
    $r.Present = $true
    $r.Text = 'Baterija prisutna (kapacitet nije dostupan - pokreni izvjestaj baterije)'
    try {
        $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
        $full   = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
        if ($design -gt 0 -and $full -gt 0) {
            $r.Pct  = [math]::Round(($full / $design) * 100)
            $r.Text = '{0}% originalnog kapaciteta ({1} / {2} mWh), napunjena {3}%' -f $r.Pct, $full, $design, $wb.EstimatedChargeRemaining
        }
    } catch {}
    return $r
}

function Get-AntivirusInfo {
    try {
        $av = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntivirusProduct -ErrorAction Stop
        foreach ($a in $av) {
            $hex = '{0:X6}' -f [int]$a.productState
            $on  = @('10', '11') -contains $hex.Substring(2, 2)
            $upd = $hex.Substring(4, 2) -eq '00'
            [pscustomobject]@{
                'Antivirus'  = $a.displayName
                'Aktivan'    = $(if ($on) { 'Da' } else { 'Ne' })
                'Definicije' = $(if ($upd) { 'Azurne' } else { 'ZASTARJELE' })
            }
        }
    } catch {}
}

function Get-SystemData {
    $os    = Get-CimInstance Win32_OperatingSystem
    $cs    = Get-CimInstance Win32_ComputerSystem
    $bios  = Get-CimInstance Win32_BIOS
    $cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
    $board = Get-CimInstance Win32_BaseBoard | Select-Object -First 1
    $gpus  = @(Get-CimInstance Win32_VideoController)
    $ram   = @(Get-CimInstance Win32_PhysicalMemory)
    $slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object -Property MemoryDevices -Sum).Sum
    $cv    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $up    = (Get-Date) - $os.LastBootUpTime

    $mods = foreach ($m in $ram) {
        $spd = $m.ConfiguredClockSpeed
        if (-not $spd) { $spd = $m.Speed }
        '{0} GB {1} MHz' -f [math]::Round($m.Capacity / 1GB), $spd
    }
    $biosDate = ''
    if ($bios.ReleaseDate) { $biosDate = ' (' + $bios.ReleaseDate.ToString('dd.MM.yyyy') + ')' }

    $act = 'Nepoznato'
    try {
        $lic = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop `
            -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1
        if ($lic) {
            $map = @{ 0 = 'NIJE AKTIVIRAN'; 1 = 'Aktiviran'; 2 = 'Grace period'; 3 = 'Grace period'; 4 = 'Non-genuine'; 5 = 'Notifikacija (nije aktiviran)'; 6 = 'Extended grace' }
            $act = '{0} (kljuc ...{1})' -f $map[[int]$lic.LicenseStatus], $lic.PartialProductKey
        }
    } catch {}

    $av = @(Get-AntivirusInfo)
    $avText = 'Nije pronadjen'
    if ($av.Count) { $avText = ($av | ForEach-Object { '{0} ({1})' -f $_.Antivirus, $(if ($_.Aktivan -eq 'Da') { 'aktivan' } else { 'neaktivan' }) }) -join ', ' }

    $build = "$($os.BuildNumber)"
    if ($cv.UBR) { $build = '{0}.{1}' -f $os.BuildNumber, $cv.UBR }
    $installed = '-'
    if ($os.InstallDate) { $installed = $os.InstallDate.ToString('dd.MM.yyyy') }

    [pscustomobject]@{
        'Racunar'        = $cs.Name
        'Proizvodjac'    = $cs.Manufacturer
        'Model'          = $cs.Model
        'Serijski broj'  = $bios.SerialNumber
        'Maticna ploca'  = (('{0} {1}' -f $board.Manufacturer, $board.Product).Trim())
        'BIOS'           = ($bios.SMBIOSBIOSVersion + $biosDate)
        'Windows'        = ('{0} {1} ({2}, build {3})' -f ($os.Caption -replace 'Microsoft ', ''), $cv.DisplayVersion, $os.OSArchitecture, $build)
        'Instaliran'     = $installed
        'Aktivacija'     = $act
        'Procesor'       = ('{0} ({1} jezgara / {2} niti)' -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
        'RAM'            = ('{0} | slotovi: {1}/{2} | {3}' -f (Format-Size $cs.TotalPhysicalMemory), $ram.Count, $slots, ($mods -join ', '))
        'Graficka'       = (($gpus | ForEach-Object { $_.Name }) -join ' + ')
        'Uptime'         = ('{0} d {1} h {2} min' -f $up.Days, $up.Hours, $up.Minutes)
        'Antivirus'      = $avText
        'BitLocker (C:)' = (Get-BitLockerText)
        'Baterija'       = ((Get-BatteryInfo).Text)
        'Korisnik'       = $cs.UserName
    }
}

function Get-DiskData {
    foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId)) {
        $rel = $null
        try { $rel = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        [pscustomobject]@{
            'Disk'           = $pd.DeviceId
            'Naziv'          = $pd.FriendlyName
            'Tip'            = ('{0}/{1}' -f $pd.MediaType, $pd.BusType)
            'Velicina'       = (Format-Size $pd.Size)
            'Zdravlje'       = "$($pd.HealthStatus)"
            'Temp (C)'       = $(if ($rel -and $rel.Temperature) { $rel.Temperature } else { '-' })
            'Istrosenost %'  = $(if ($rel -and $null -ne $rel.Wear) { $rel.Wear } else { '-' })
            'Sati rada'      = $(if ($rel -and $rel.PowerOnHours) { $rel.PowerOnHours } else { '-' })
            'Greske citanja' = $(if ($rel -and $null -ne $rel.ReadErrorsTotal) { $rel.ReadErrorsTotal } else { '-' })
        }
    }
}

function Get-VolumeData {
    Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Fixed' } | Sort-Object DriveLetter | ForEach-Object {
        $pct = 0
        if ($_.Size -gt 0) { $pct = [math]::Round($_.SizeRemaining / $_.Size * 100) }
        [pscustomobject]@{
            'Particija'  = "$($_.DriveLetter):"
            'Naziv'      = $_.FileSystemLabel
            'FS'         = $_.FileSystem
            'Velicina'   = (Format-Size $_.Size)
            'Slobodno'   = (Format-Size $_.SizeRemaining)
            'Slobodno %' = $pct
            'Zdravlje'   = "$($_.HealthStatus)"
        }
    }
}

function Get-SmartWarnings {
    try {
        return @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | Where-Object { $_.PredictFailure })
    } catch { return @() }
}

function Get-NetData {
    Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { "$($_.Status)" -eq 'Up' } | ForEach-Object {
        $ip  = Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $cfg = Get-NetIPConfiguration -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue
        [pscustomobject]@{
            'Adapter' = $_.Name
            'Opis'    = $_.InterfaceDescription
            'Brzina'  = $_.LinkSpeed
            'MAC'     = $_.MacAddress
            'IP'      = $ip.IPAddress
            'Gateway' = (@($cfg.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ', ')
            'DNS'     = (@($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ', ')
        }
    }
}

function Get-ProblemDevices {
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22 } | ForEach-Object {
            [pscustomobject]@{
                'Uredjaj'     = $(if ($_.Name) { $_.Name } else { '(nepoznat uredjaj)' })
                'Kod greske'  = $_.ConfigManagerErrorCode
                'Hardware ID' = (@($_.HardwareID) | Select-Object -First 1)
            }
        }
}

# ---- Instalirani programi: registry (64/32-bit, SVI korisnici) + Store aplikacije ----
function Read-UninstallKey {
    param([Microsoft.Win32.RegistryKey]$Base, [string]$SubPath, [string]$Tip)
    $k = $null
    try { $k = $Base.OpenSubKey($SubPath, $false) } catch {}
    if (-not $k) { return }
    try {
        foreach ($n in $k.GetSubKeyNames()) {
            $s = $null
            try { $s = $k.OpenSubKey($n, $false) } catch {}
            if (-not $s) { continue }
            try {
                $name = "$($s.GetValue('DisplayName'))".Trim()
                if (-not $name) { continue }
                if ("$($s.GetValue('SystemComponent'))" -eq '1') { continue }
                if ($s.GetValue('ParentKeyName') -or "$($s.GetValue('ReleaseType'))" -match 'Update|Hotfix') { continue }
                $dt = ''
                if ("$($s.GetValue('InstallDate'))" -match '^(\d{4})(\d{2})(\d{2})$') { $dt = '{0}-{1}-{2}' -f $Matches[1], $Matches[2], $Matches[3] }
                $kb = 0.0
                try { $kb = [double]$s.GetValue('EstimatedSize', 0) } catch {}
                [pscustomobject]@{
                    Naziv          = $name
                    Verzija        = "$($s.GetValue('DisplayVersion'))".Trim()
                    Izdavac        = "$($s.GetValue('Publisher'))".Trim()
                    Instalirano    = $dt
                    VelicinaMB     = [math]::Round($kb / 1024, 1)
                    Tip            = $Tip
                    Uninstall      = "$($s.GetValue('UninstallString'))".Trim()
                    QuietUninstall = "$($s.GetValue('QuietUninstallString'))".Trim()
                    Lokacija       = "$($s.GetValue('InstallLocation'))".Trim().Trim('"')
                    Paket          = ''
                }
            } finally { $s.Close() }
        }
    } finally { $k.Close() }
}

function Get-ProfileName {
    param([string]$Sid, $Profiles)
    try { return (((New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value) -split '\\')[-1] } catch {}
    if ($Profiles.ContainsKey($Sid)) { return (Split-Path $Profiles[$Sid].LocalPath -Leaf) }
    return $Sid
}

function Initialize-IndirectString {
    if (-not ('KT.Shl' -as [type])) {
        try {
            Add-Type -Namespace KT -Name Shl -ErrorAction Stop -MemberDefinition @'
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
public static extern int SHLoadIndirectString(string pszSource, System.Text.StringBuilder pszOutBuf, int cchOutBuf, System.IntPtr ppvReserved);
'@
        } catch {}
    }
    return [bool]('KT.Shl' -as [type])
}

# Pretvara "ms-resource:AppName" iz manifesta u pravo ime aplikacije
function Resolve-AppxText {
    param([string]$Text, $Pkg)
    if (-not $Text) { return $null }
    if ($Text -notlike 'ms-resource:*') { return $Text }
    if (-not (Initialize-IndirectString)) { return $null }
    $r = $Text.Substring(12)
    $cands = @()
    if ($r.StartsWith('///'))    { $cands += 'ms-resource://' + $Pkg.Name + $r.Substring(2) }
    elseif ($r.StartsWith('//')) { $cands += 'ms-resource:' + $r }
    elseif ($r.StartsWith('/'))  { $cands += 'ms-resource://' + $Pkg.Name + $r }
    else { $cands += ('ms-resource://{0}/Resources/{1}' -f $Pkg.Name, $r); $cands += ('ms-resource://{0}/{1}' -f $Pkg.Name, $r) }
    foreach ($c in $cands) {
        $sb = New-Object System.Text.StringBuilder 1024
        $src = '@{' + $Pkg.PackageFullName + '?' + $c + '}'
        try { if ([KT.Shl]::SHLoadIndirectString($src, $sb, $sb.Capacity, [IntPtr]::Zero) -eq 0 -and $sb.Length -gt 0) { return $sb.ToString() } } catch {}
    }
    return $null
}

function Get-StoreApps {
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { return }
    $pk = @()
    try { $pk = @(Get-AppxPackage -AllUsers -PackageTypeFilter Main -ErrorAction Stop) }
    catch { try { $pk = @(Get-AppxPackage -PackageTypeFilter Main -ErrorAction Stop) } catch {} }
    foreach ($p in $pk) {
        if ($p.IsFramework -or $p.NonRemovable -or "$($p.SignatureKind)" -eq 'System') { continue }
        $x = $null
        try { [xml]$x = Get-Content -LiteralPath (Join-Path $p.InstallLocation 'AppxManifest.xml') -Raw -ErrorAction Stop } catch {}
        $disp = $null
        $pub = ("$($p.Publisher)" -replace '^CN=([^,]+).*$', '$1').Trim('"')
        if ($x) {
            # preskoci pakete bez vidljive aplikacije (ekstenzije, servisi)
            $apps = @($x.Package.Applications.Application | Where-Object { $_ })
            if ($apps.Count -eq 0) { continue }
            if (@($apps | Where-Object { "$($_.VisualElements.AppListEntry)" -ne 'none' }).Count -eq 0) { continue }
            $disp = Resolve-AppxText "$($x.Package.Properties.DisplayName)" $p
            $pd = Resolve-AppxText "$($x.Package.Properties.PublisherDisplayName)" $p
            if ($pd) { $pub = $pd }
        }
        if (-not $disp) { $disp = (($p.Name -replace '^[^.]+\.', '') -creplace '(?<=[a-z])(?=[A-Z])', ' ') }
        $dt = ''
        try { $dt = (Get-Item -LiteralPath $p.InstallLocation -ErrorAction Stop).CreationTime.ToString('yyyy-MM-dd') } catch {}
        [pscustomobject]@{
            Naziv          = $disp
            Verzija        = "$($p.Version)"
            Izdavac        = $pub
            Instalirano    = $dt
            VelicinaMB     = 0
            Tip            = 'Store aplikacija'
            Uninstall      = ''
            QuietUninstall = ''
            Lokacija       = "$($p.InstallLocation)"
            Paket          = $p.PackageFullName
        }
    }
}

function Get-InstalledPrograms {
    param([switch]$Quick)   # -Quick = bez Store aplikacija i bez korisnika koji nisu prijavljeni
    $list  = New-Object System.Collections.Generic.List[object]
    $sub   = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $sub32 = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'

    # 1) Programi za sve korisnike - eksplicitno 64-bit i 32-bit pogled registry-ja
    if ([Environment]::Is64BitOperatingSystem) {
        foreach ($v in @(@('Registry64', 'Svi korisnici (64-bit)'), @('Registry32', 'Svi korisnici (32-bit)'))) {
            $h = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $v[0])
            foreach ($x in @(Read-UninstallKey $h $sub $v[1])) { $list.Add($x) }
            $h.Close()
        }
    } else {
        $h = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Default')
        foreach ($x in @(Read-UninstallKey $h $sub 'Svi korisnici')) { $list.Add($x) }
        $h.Close()
    }

    # 2) Programi instalirani samo za korisnika (Zoom, Teams, Discord, Spotify, VS Code...) - za SVE profile
    $profiles = @{}
    foreach ($pr in @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.LocalPath })) { $profiles[$pr.SID] = $pr }
    $hku = [Microsoft.Win32.RegistryKey]::OpenBaseKey('Users', 'Default')
    $loaded = @($hku.GetSubKeyNames() | Where-Object { $_ -match '^S-1-5-21-[\d-]+$' })
    foreach ($sid in $loaded) {
        $un = Get-ProfileName $sid $profiles
        foreach ($sp in $sub, $sub32) { foreach ($x in @(Read-UninstallKey $hku "$sid\$sp" "Korisnik: $un")) { $list.Add($x) } }
    }
    if (-not $Quick) {
        # korisnici koji nisu prijavljeni: privremeno ucitaj njihov NTUSER.DAT
        foreach ($sid in @($profiles.Keys)) {
            if ($loaded -contains $sid) { continue }
            $nt = Join-Path $profiles[$sid].LocalPath 'NTUSER.DAT'
            if (-not (Test-Path -LiteralPath $nt)) { continue }
            $un  = Get-ProfileName $sid $profiles
            $tmp = 'KT_Hive_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            & reg.exe load "HKU\$tmp" "$nt" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Log "Profil $un nije moguce procitati (zakljucan)." 'dim'; continue }
            try {
                foreach ($sp in $sub, $sub32) { foreach ($x in @(Read-UninstallKey $hku "$tmp\$sp" "Korisnik: $un")) { $list.Add($x) } }
            } finally {
                $ok = $false
                for ($i = 0; $i -lt 6 -and -not $ok; $i++) {
                    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                    & reg.exe unload "HKU\$tmp" 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { $ok = $true } else { Start-Sleep -Milliseconds 500 }
                }
                if (-not $ok) { Log "Profil $un ostao ucitan - RESTARTUJ racunar prije nego se taj korisnik prijavi." 'warn' }
            }
        }
    }
    $hku.Close()

    # 3) Microsoft Store aplikacije (WhatsApp, Spotify, Netflix, novi Teams...)
    if (-not $Quick) { foreach ($x in @(Get-StoreApps)) { $list.Add($x) } }

    $seen = @{}
    foreach ($x in ($list | Sort-Object Naziv)) {
        $key = '{0}|{1}|{2}' -f $x.Naziv, $x.Verzija, $x.Tip
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = 1
        $x
    }
}

function Get-BugChecks {
    param([int]$Days = 30)
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; StartTime = (Get-Date).AddDays(-$Days) } -ErrorAction Stop |
            Where-Object { $_.ProviderName -match 'WER-SystemErrorReporting|BugCheck' }
    } catch {}
}
function Get-KernelPower41 {
    param([int]$Days = 30)
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = (Get-Date).AddDays(-$Days) } -ErrorAction Stop
    } catch {}
}

$BugCheckInfo = @{
    '0x0000000a' = 'IRQL_NOT_LESS_OR_EQUAL|Drajver ili RAM - azuriraj drajvere, testiraj RAM (MemTest86).'
    '0x00000019' = 'BAD_POOL_HEADER|Drajver ili RAM.'
    '0x0000001a' = 'MEMORY_MANAGEMENT|Najcesce RAM - MemTest86, testiraj module jedan po jedan.'
    '0x0000001e' = 'KMODE_EXCEPTION_NOT_HANDLED|Drajver - provjeri skoro instalirane drajvere/programe.'
    '0x00000024' = 'NTFS_FILE_SYSTEM|Fajl sistem - CHKDSK, provjeri SMART.'
    '0x0000003b' = 'SYSTEM_SERVICE_EXCEPTION|Drajver ili antivirus - azuriraj graficku, provjeri AV.'
    '0x00000050' = 'PAGE_FAULT_IN_NONPAGED_AREA|RAM ili drajver - MemTest86, SFC.'
    '0x00000077' = 'KERNEL_STACK_INPAGE_ERROR|Disk ili RAM - SMART i MemTest86.'
    '0x0000007a' = 'KERNEL_DATA_INPAGE_ERROR|Disk ili kabl - SMART, SATA kabl, CHKDSK.'
    '0x0000007e' = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED|Drajver - pogledaj minidump (BlueScreenView).'
    '0x0000009f' = 'DRIVER_POWER_STATE_FAILURE|Drajver kod sleep/hibernacije - chipset, WiFi, graficka.'
    '0x000000be' = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY|Drajver ili RAM.'
    '0x000000c2' = 'BAD_POOL_CALLER|Drajver ili antivirus.'
    '0x000000d1' = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL|Drajver (cesto mreza/WiFi) - azuriraj drajvere.'
    '0x000000ef' = 'CRITICAL_PROCESS_DIED|Ostecen sistem ili disk - DISM+SFC, provjeri disk.'
    '0x000000f4' = 'CRITICAL_OBJECT_TERMINATION|Disk ili kabl - SMART i SATA kabl.'
    '0x00000101' = 'CLOCK_WATCHDOG_TIMEOUT|CPU - overclock, BIOS update, temperature.'
    '0x00000116' = 'VIDEO_TDR_FAILURE|Graficka - DDU + cista instalacija drajvera, temperature.'
    '0x00000124' = 'WHEA_UNCORRECTABLE_ERROR|Hardver - temperature, napajanje, overclock, BIOS.'
    '0x00000133' = 'DPC_WATCHDOG_VIOLATION|Drajver ili SSD firmware - chipset i SSD firmware.'
    '0x00000139' = 'KERNEL_SECURITY_CHECK_FAILURE|Drajver ili RAM - drajveri, MemTest86, SFC.'
    '0x00000154' = 'UNEXPECTED_STORE_EXCEPTION|Disk/SSD - SMART, firmware, CHKDSK.'
}
function Resolve-BugCheck {
    param($Ev)
    $code = 'nepoznat'
    $texts = @("$($Ev.Message)", ((@($Ev.Properties) | ForEach-Object { "$($_.Value)" }) -join ' '))
    foreach ($t in $texts) { if ($t -match '0x[0-9a-fA-F]{8}') { $code = $Matches[0].ToLower(); break } }
    $name = 'Nepoznat kod'; $hint = 'Analiziraj minidump (BlueScreenView / WinDbg).'
    if ($BugCheckInfo.ContainsKey($code)) { $parts = $BugCheckInfo[$code] -split '\|', 2; $name = $parts[0]; $hint = $parts[1] }
    [pscustomobject]@{ Code = $code; Name = $name; Hint = $hint }
}

function Get-TopErrors {
    param([int]$Days = 7, [int]$Top = 15)
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = (Get-Date).AddDays(-$Days) } -MaxEvents 3000 -ErrorAction Stop
        $ev | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First $Top | ForEach-Object {
            $first = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $msg = ''
            if ($first.Message) { $msg = ($first.Message -split "`r?`n")[0]; if ($msg.Length -gt 150) { $msg = $msg.Substring(0, 150) + '...' } }
            [pscustomobject]@{
                'Broj'       = $_.Count
                'Izvor'      = $first.ProviderName
                'ID'         = $first.Id
                'Zadnji put' = $first.TimeCreated.ToString('dd.MM. HH:mm')
                'Poruka'     = $msg
            }
        }
    } catch {}
}

function Test-PendingReboot {
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path $k) { return $true }
    }
    return $false
}

function Get-Findings {
    param($Sys, $Disks, $Vols, $Devices)
    $f = New-Object System.Collections.Generic.List[object]
    $add = { param($n, $t) $f.Add([pscustomobject]@{ Nivo = $n; Opis = $t }) }

    foreach ($d in @($Disks)) {
        if ($d.Zdravlje -and $d.Zdravlje -ne 'Healthy') { & $add 'KRITICNO' ('Disk {0} ({1}) prijavljuje stanje: {2}. Hitno backup podataka!' -f $d.Disk, $d.Naziv, $d.Zdravlje) }
        $t = "$($d.'Temp (C)')";      if ($t -match '^\d+$' -and [double]$t -ge 60) { & $add 'UPOZORENJE' ('Disk {0} je zagrijan: {1} C.' -f $d.Naziv, $t) }
        $w = "$($d.'Istrosenost %')"; if ($w -match '^\d+$' -and [double]$w -ge 80) { & $add 'UPOZORENJE' ('SSD {0} je istrosen {1}% - planirati zamjenu.' -f $d.Naziv, $w) }
    }
    if (@(Get-SmartWarnings).Count) { & $add 'KRITICNO' 'SMART predvidja kvar diska! Odmah backup i zamjena diska.' }
    foreach ($v in @($Vols)) {
        if ($v.'Slobodno %' -lt 5)      { & $add 'KRITICNO'   ('Particija {0} ima samo {1}% slobodnog prostora.' -f $v.Particija, $v.'Slobodno %') }
        elseif ($v.'Slobodno %' -lt 15) { & $add 'UPOZORENJE' ('Particija {0} ima {1}% slobodnog prostora.' -f $v.Particija, $v.'Slobodno %') }
    }
    if (@($Devices).Count) { & $add 'UPOZORENJE' ('{0} uredjaj(a) nema drajver ili ima gresku - Device Manager / SDIO.' -f @($Devices).Count) }

    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.TotalPhysicalMemory -lt 7.5GB) { & $add 'INFO' ('RAM je {0} - za Windows 10/11 preporuka je minimum 8 GB.' -f (Format-Size $cs.TotalPhysicalMemory)) }
    if ($Sys.Aktivacija -notmatch '^Aktiviran') { & $add 'UPOZORENJE' ('Windows aktivacija: {0}' -f $Sys.Aktivacija) }

    $av = @(Get-AntivirusInfo)
    if ($av.Count -eq 0) { & $add 'UPOZORENJE' 'Antivirus nije pronadjen.' }
    elseif (-not ($av | Where-Object { $_.Aktivan -eq 'Da' })) { & $add 'UPOZORENJE' 'Nijedan antivirus nije aktivan!' }
    elseif ($av | Where-Object { $_.Aktivan -eq 'Da' -and $_.Definicije -ne 'Azurne' }) { & $add 'UPOZORENJE' 'Antivirus definicije nisu azurne.' }

    if ($Sys.'BitLocker (C:)' -match 'UKLJUCEN') { & $add 'INFO' 'BitLocker je ukljucen - sacuvaj recovery kljuc prije rada na disku ili BIOS-u.' }

    $bat = Get-BatteryInfo
    if ($bat.Pct) {
        if ($bat.Pct -lt 60)     { & $add 'UPOZORENJE' ('Baterija ima {0}% originalnog kapaciteta - preporuka zamjena.' -f $bat.Pct) }
        elseif ($bat.Pct -lt 80) { & $add 'INFO' ('Baterija ima {0}% originalnog kapaciteta.' -f $bat.Pct) }
    }

    $os = Get-CimInstance Win32_OperatingSystem
    $upDays = ((Get-Date) - $os.LastBootUpTime).Days
    if ($upDays -ge 14) { & $add 'INFO' ('Racunar nije restartovan {0} dana.' -f $upDays) }
    if (Test-PendingReboot) { & $add 'INFO' 'Windows ceka restart (zavrsetak update-a).' }

    $bc = @(Get-BugChecks -Days 30)
    if ($bc.Count) { & $add 'UPOZORENJE' ('Plavi ekran (BSOD) {0}x u zadnjih 30 dana.' -f $bc.Count) }
    $kp = @(Get-KernelPower41 -Days 30)
    if ($kp.Count -ge 3) { & $add 'INFO' ('Neocekivano gasenje {0}x u zadnjih 30 dana (struja, napajanje, temperatura?).' -f $kp.Count) }

    if ($f.Count -eq 0) { & $add 'OK' 'Nisu pronadjeni problemi.' }
    return $f
}

function Show-Findings {
    param($Findings)
    foreach ($x in @($Findings)) {
        switch ($x.Nivo) {
            'KRITICNO'   { Log ('[X] ' + $x.Opis) 'err' }
            'UPOZORENJE' { Log ('[!] ' + $x.Opis) 'warn' }
            'INFO'       { Log ('[i] ' + $x.Opis) 'head' }
            default      { Log ('[OK] ' + $x.Opis) 'ok' }
        }
    }
}

function Get-WingetPath {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($p) { return $p.FullName }
    return $null
}

# =================== ZADACI ===================

function Task-Dashboard {
    $sys   = Get-SystemData
    $disks = @(Get-DiskData)
    $vols  = @(Get-VolumeData)
    $devs  = @(Get-ProblemDevices)
    $find  = @(Get-Findings -Sys $sys -Disks $disks -Vols $vols -Devices $devs)
    $cs    = Get-CimInstance Win32_ComputerSystem
    $c     = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive)
    $sync.Dash = @{
        Model     = ('{0} {1}' -f $sys.Proizvodjac, $sys.Model)
        Serial    = $sys.'Serijski broj'
        Windows   = $sys.Windows
        Act       = $sys.Aktivacija
        Cpu       = ($sys.Procesor -replace '\s*\(\d+ jezgara.*$', '')
        Ram       = (Format-Size $cs.TotalPhysicalMemory)
        Gpu       = $sys.Graficka
        DiskTotal = [double]$c.Size
        DiskFree  = [double]$c.FreeSpace
        Uptime    = $sys.Uptime
        Crit      = @($find | Where-Object { $_.Nivo -eq 'KRITICNO' }).Count
        Warn      = @($find | Where-Object { $_.Nivo -eq 'UPOZORENJE' }).Count
        BaseFree  = $null
    }
    if ($sync.Baseline) { $sync.Dash.BaseFree = [double]$sync.Baseline.FreeC }
    $sync.DashReady = $true
    Log ('Racunar: {0} {1}  |  {2}' -f $sys.Proizvodjac, $sys.Model, $sys.Windows) 'info'
    Section 'Nalazi'
    Show-Findings $find
    if (-not $sync.Baseline) {
        Log 'Biljezim pocetno stanje racunara (za izvjestaj prije/poslije)...' 'dim'
        $b = Get-Snapshot -Crit $sync.Dash.Crit -Warn $sync.Dash.Warn
        $sync.Baseline = $b
        $sync.SaveSession = $true
        $bt = 'nepoznato'
        if ($b.BootSec) { $bt = '{0} s' -f $b.BootSec }
        Log ('Pocetno stanje: slobodno {0} | pri pokretanju {1} programa | instalirano {2} | podizanje sistema {3}' -f (Format-Size $b.FreeC), $b.StartupOn, $b.Programs, $bt) 'info'
    }
}

function Task-Quick {
    Add-DoneKey 'diag'
    Log 'Prikupljam podatke...' 'dim'
    $sys = Get-SystemData
    Section 'Sistem'
    foreach ($p in $sys.PSObject.Properties) { Log ('{0,-16} {1}' -f ($p.Name + ':'), $p.Value) 'info' }
    $disks = @(Get-DiskData); $vols = @(Get-VolumeData); $devs = @(Get-ProblemDevices)
    Section 'Diskovi';   Table ($disks | Select-Object Disk, Naziv, Tip, Velicina, Zdravlje, 'Temp (C)', 'Istrosenost %')
    Section 'Particije'; Table $vols
    if ($devs.Count) { Section 'Uredjaji bez drajvera / sa greskom'; Table $devs }
    Section 'Mreza';     Table (Get-NetData | Select-Object Adapter, Brzina, IP, Gateway)
    Section 'Nalazi';    Show-Findings (Get-Findings -Sys $sys -Disks $disks -Vols $vols -Devices $devs)
}

function Task-Disk {
    Log 'Citam SMART podatke...' 'dim'
    $disks = @(Get-DiskData)
    Section 'Fizicki diskovi'; Table $disks
    Section 'Particije';       Table (Get-VolumeData)
    Section 'Procjena'
    $bad = $false
    if (@(Get-SmartWarnings).Count) { Log 'SMART PREDVIDJA KVAR DISKA! Odmah backup podataka i zamjena diska.' 'err'; $bad = $true }
    foreach ($d in $disks) {
        if ($d.Zdravlje -and $d.Zdravlje -ne 'Healthy') { Log ('Disk {0} ({1}): stanje {2}' -f $d.Disk, $d.Naziv, $d.Zdravlje) 'err'; $bad = $true }
        $t = "$($d.'Temp (C)')";       if ($t -match '^\d+$' -and [double]$t -ge 60) { Log ('{0}: temperatura {1} C' -f $d.Naziv, $t) 'warn'; $bad = $true }
        $w = "$($d.'Istrosenost %')";  if ($w -match '^\d+$' -and [double]$w -ge 80) { Log ('{0}: istrosen {1}%' -f $d.Naziv, $w) 'warn'; $bad = $true }
        $e = "$($d.'Greske citanja')"; if ($e -match '^\d+$' -and [double]$e -gt 0)  { Log ('{0}: {1} gresaka citanja' -f $d.Naziv, $e) 'warn'; $bad = $true }
    }
    if (-not $bad) { Log 'Svi diskovi prijavljuju ispravno stanje.' 'ok' }
    Log 'Windows ne cita sve SMART atribute - za detalje koristi CrystalDiskInfo / HD Sentinel.' 'dim'
}

function Task-Crash {
    Section 'Plavi ekrani - zadnjih 90 dana'
    $bc = @(Get-BugChecks -Days 90)
    if ($bc.Count -eq 0) { Log 'Nema zabiljezenih plavih ekrana.' 'ok' }
    else {
        $rows = foreach ($e in $bc) {
            $r = Resolve-BugCheck $e
            [pscustomobject]@{ 'Datum' = (Format-Date $e.TimeCreated); 'Kod' = $r.Code; 'Naziv' = $r.Name }
        }
        Table $rows
        Section 'Savjeti'
        foreach ($g in ($bc | ForEach-Object { Resolve-BugCheck $_ } | Group-Object Code)) {
            $r = $g.Group[0]
            Log ('{0} ({1}x): {2}' -f $r.Name, $g.Count, $r.Hint) 'warn'
        }
        $bc | ForEach-Object { $r = Resolve-BugCheck $_; [pscustomobject]@{ Datum = (Format-Date $_.TimeCreated); Kod = $r.Code; Naziv = $r.Name; Savjet = $r.Hint } } |
            Export-Csv (Join-Path $ReportDir 'bsod.csv') -NoTypeInformation -UseCulture -Encoding UTF8
    }

    Section 'Neocekivana gasenja (Kernel-Power 41) - 30 dana'
    $kp = @(Get-KernelPower41 -Days 30)
    if ($kp.Count -eq 0) { Log 'Nema.' 'ok' }
    else { Log ('{0} neocekivanih gasenja. Zadnje: {1}' -f $kp.Count, (Format-Date $kp[0].TimeCreated)) 'warn' }

    Section 'Minidump fajlovi'
    $md = @(Get-ChildItem "$env:windir\Minidump\*.dmp" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($md.Count -eq 0) { Log 'Nema minidump fajlova.' 'dim' }
    else {
        $dst = Join-Path $ReportDir 'Minidump'
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        foreach ($m in ($md | Select-Object -First 10)) {
            Log ('{0}  {1}' -f (Format-Date $m.LastWriteTime), $m.Name) 'out'
            Copy-Item -LiteralPath $m.FullName -Destination $dst -ErrorAction SilentlyContinue
        }
        Log 'Kopirano u folder izvjestaja - otvori ih sa BlueScreenView ili WinDbg.' 'ok'
    }

    Section 'Najcesce greske u Event Logu - 7 dana'
    $te = @(Get-TopErrors -Days 7 -Top 15)
    Table ($te | Select-Object Broj, Izvor, ID, 'Zadnji put')
    if ($te.Count) {
        $te | Export-Csv (Join-Path $ReportDir 'event_greske.csv') -NoTypeInformation -UseCulture -Encoding UTF8
        Log 'Detalji sa porukama: event_greske.csv u folderu izvjestaja.' 'dim'
    }
}

function Task-Battery {
    $b = Get-BatteryInfo
    if (-not $b.Present) { Log 'Ovaj racunar nema bateriju.' 'info'; return }
    Section 'Baterija'
    if ($b.Pct) {
        if ($b.Pct -lt 60) { Log $b.Text 'err'; Log 'Preporuka: zamjena baterije.' 'warn' }
        elseif ($b.Pct -lt 80) { Log $b.Text 'warn' }
        else { Log $b.Text 'ok' }
    } else { Log $b.Text 'info' }
    $out = Join-Path $ReportDir 'baterija.html'
    Run-Native 'powercfg.exe' @('/batteryreport', '/output', $out) | Out-Null
    if (Test-Path $out) { Log "Detaljan izvjestaj: $out" 'ok'; Start-Process $out }
}

function Task-Security {
    param([bool]$Scan)
    Section 'Antivirus'
    $av = @(Get-AntivirusInfo)
    if ($av.Count) { Table $av } else { Log 'Antivirus nije pronadjen.' 'warn' }

    $mp = $null
    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) { try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch {} }
    if ($mp) {
        Log ('Defender: real-time {0} | definicije: {1} | zadnji quick scan: {2}' -f `
            $(if ($mp.RealTimeProtectionEnabled) { 'UKLJUCEN' } else { 'iskljucen' }), (Format-Date $mp.AntivirusSignatureLastUpdated), (Format-Date $mp.QuickScanEndTime)) 'info'
    }

    Section 'Programi za daljinski pristup'
    $pat = 'AnyDesk|TeamViewer|RustDesk|UltraViewer|Supremo|ScreenConnect|ConnectWise|LogMeIn|Ammyy|RemotePC|Splashtop|Zoho Assist|AeroAdmin|Radmin|VNC|Remote Utilities'
    $remote = @(Get-InstalledPrograms -Quick | Where-Object { $_.Naziv -match $pat })
    $procs  = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)anydesk|teamviewer|rustdesk|ultraviewer|supremo|screenconnect|ammyy|aeroadmin|rutserv|rfusclient' } |
                Select-Object -ExpandProperty ProcessName -Unique)
    if ($remote.Count) { Table ($remote | Select-Object Naziv, Verzija, Instalirano) }
    if ($procs.Count)  { Log ('Pokrenuti procesi: ' + ($procs -join ', ')) 'warn' }
    if ($remote.Count -or $procs.Count) { Log 'Provjeri sa klijentom da li zna za ove programe (cesto ih koriste prevaranti).' 'warn' }
    else { Log 'Nije pronadjen.' 'ok' }

    Section 'Programi koji se pokrecu sa Windowsom'
    Table (Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object @{ n = 'Naziv'; e = { $_.Name } }, @{ n = 'Komanda'; e = { $_.Command } }, @{ n = 'Lokacija'; e = { $_.Location } })

    Section 'Zakazani zadaci (nisu Microsoftovi)'
    Table (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and "$($_.State)" -ne 'Disabled' } | ForEach-Object {
        [pscustomobject]@{
            'Zadatak' = $_.TaskName
            'Pokrece' = ((@($_.Actions) | ForEach-Object { ("$($_.Execute) $($_.Arguments)").Trim() }) -join ' | ')
        }
    })

    Section 'Hosts fajl'
    $hosts = @(Get-Content "$env:windir\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*[^#\s]' })
    if ($hosts.Count) { foreach ($h in $hosts) { Log "Unos: $h" 'warn' } } else { Log 'Hosts fajl je cist.' 'ok' }

    Section 'Proxy podesavanja'
    $is = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($is.ProxyEnable -eq 1) { Log ('Proxy ukljucen: {0}' -f $is.ProxyServer) 'warn' }
    elseif ($is.AutoConfigURL) { Log ('Auto-config skripta: {0}' -f $is.AutoConfigURL) 'warn' }
    else { Log 'Proxy nije podesen.' 'ok' }

    Section 'Lokalni administratori'
    try { Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { Log ('{0}  ({1})' -f $_.Name, $_.PrincipalSource) 'info' } }
    catch { Run-Native 'net.exe' @('localgroup', 'administrators') | Out-Null }

    if ($Scan) {
        Section 'Windows Defender'
        if (-not $mp) { Log 'Defender nije dostupan na ovom racunaru.' 'warn'; return }
        try { Update-MpSignature -ErrorAction Stop; Log 'Definicije azurirane.' 'ok' } catch { Log ('Azuriranje definicija nije uspjelo: ' + $_.Exception.Message) 'warn' }
        Log 'Brzo skeniranje u toku (par minuta)...' 'info'
        try {
            Start-MpScan -ScanType QuickScan -ErrorAction Stop
            Log 'Skeniranje zavrseno.' 'ok'
            $thr = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddHours(-2) })
            if ($thr.Count) { Log ('Defender je pronasao {0} prijetnji - provjeri u Windows Security.' -f $thr.Count) 'err' } else { Log 'Nema novih detekcija.' 'ok' }
            Add-Done 'Defender azuriranje i brzo skeniranje' 'security'
        } catch { Log ('Skeniranje nije uspjelo: ' + $_.Exception.Message) 'err' }
    }
}

function Task-Repair {
    Log 'DISM popravlja Windows image (treba internet), zatim SFC popravlja sistemske fajlove.' 'dim'
    Section 'DISM /RestoreHealth'
    $d = Run-Native 'DISM.exe' @('/Online', '/Cleanup-Image', '/RestoreHealth')
    if ($d -eq 0) { Log 'DISM zavrsen uspjesno.' 'ok' } else { Log "DISM izlazni kod: $d (provjeri internet; log: C:\Windows\Logs\DISM\dism.log)" 'warn' }

    Section 'SFC /scannow'
    $start = Get-Date
    Run-Native 'sfc.exe' @('/scannow') | Out-Null

    Section 'Rezultat'
    $cbs = "$env:windir\Logs\CBS\CBS.log"
    try {
        $lines = (Read-SharedFile $cbs) -split "`r?`n" | Where-Object { $_ -like '*[SR]*' }
        $recent = @($lines | Where-Object {
            if ($_ -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') { try { [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null) -ge $start.AddMinutes(-1) } catch { $false } } else { $false }
        })
        $recent | Set-Content -Path (Join-Path $ReportDir 'sfc_detalji.txt') -Encoding UTF8
        $bad   = @($recent | Where-Object { $_ -match 'Cannot repair' }).Count
        $fixed = @($recent | Where-Object { $_ -match 'Repaired file|Repairing corrupted file' }).Count
        if ($bad)       { Log "SFC: $bad fajlova NIJE moguce popraviti (sfc_detalji.txt). Razmisli o in-place upgrade-u Windowsa." 'err' }
        elseif ($fixed) { Log "SFC: popravljeno $fixed fajlova. Restartuj racunar." 'ok' }
        else            { Log 'SFC: nisu pronadjeni osteceni fajlovi.' 'ok' }
    } catch { Log 'Nije moguce procitati CBS.log - provjeri rezultat iznad.' 'warn' }
    Add-Done 'Popravka sistema (DISM RestoreHealth + SFC scannow)' 'repair'
}

function Task-Chkdsk {
    param([string]$Drive, [bool]$Fix)
    $L = $Drive.TrimEnd(':').ToUpper()
    $code = Run-Native 'chkdsk.exe' @("$($L):", '/scan')
    Section 'Rezultat'
    if ($code -eq 0) { Log "Na particiji $($L): nisu pronadjene greske." 'ok'; return }
    Log "CHKDSK izlazni kod $code - moguce greske na fajl sistemu." 'warn'
    if (-not $Fix) { Log 'Pokreni ponovo i izaberi "Provjera + popravka".' 'info'; return }
    if ("$($L):" -eq $env:SystemDrive) {
        Run-Native 'fsutil.exe' @('dirty', 'set', "$($L):") | Out-Null
        Log "Popravka particije $($L): je zakazana - restartuj racunar (provjera ide prije pokretanja Windowsa)." 'ok'
        Add-Done "Zakazana CHKDSK popravka particije $($L):" 'chkdsk'
    } else {
        try {
            $r = Repair-Volume -DriveLetter $L -OfflineScanAndFix -ErrorAction Stop
            Log "Rezultat popravke: $r" 'ok'
            Add-Done "CHKDSK popravka particije $($L):" 'chkdsk'
        } catch { Log ('Popravka nije uspjela: ' + $_.Exception.Message) 'err' }
    }
}

function Task-WUReset {
    Log 'Zaustavljam Windows Update servise...' 'info'
    foreach ($s in 'wuauserv', 'bits', 'cryptsvc', 'msiserver', 'usosvc', 'dosvc') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    foreach ($p in @("$env:windir\SoftwareDistribution", "$env:windir\System32\catroot2")) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $newName = (Split-Path $p -Leaf) + '.old_' + $Stamp
        $ok = $false
        for ($n = 1; $n -le 4 -and -not $ok; $n++) {
            Stop-Service -Name wuauserv, bits, cryptsvc -Force -ErrorAction SilentlyContinue
            try { Rename-Item -LiteralPath $p -NewName $newName -ErrorAction Stop; $ok = $true } catch { Start-Sleep -Seconds 2 }
        }
        if ($ok) { Log "Preimenovano: $p -> $newName" 'ok' } else { Log "Nije moguce preimenovati $p (zauzet). Restartuj pa pokusaj ponovo." 'warn' }
    }
    Remove-Item "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader\qmgr*.dat" -Force -ErrorAction SilentlyContinue
    foreach ($s in 'cryptsvc', 'bits', 'wuauserv') { Start-Service -Name $s -ErrorAction SilentlyContinue }
    Log 'Windows Update je resetovan. Pokreni provjeru update-a u Postavkama.' 'ok'
    Add-Done 'Reset Windows Update komponenti' 'wureset'
}

function Task-Network {
    param([string]$Mode)
    switch ($Mode) {
        'diag' {
            Section 'Aktivni adapteri'
            $net = @(Get-NetData)
            Table ($net | Select-Object Adapter, Brzina, IP, Gateway, DNS)
            Section 'Testovi konekcije'
            $gw = (@($net | Where-Object { $_.Gateway }) | Select-Object -First 1).Gateway
            if ($gw) { $g = ($gw -split ',')[0].Trim(); Test-Step "Ruter ($g)" { Test-Connection -ComputerName $g -Count 2 -Quiet } }
            else { Log 'Nema default gateway-a - racunar nije spojen na mrezu.' 'err' }
            Test-Step 'Internet (1.1.1.1)'      { Test-Connection -ComputerName '1.1.1.1' -Count 2 -Quiet }
            Test-Step 'DNS (google.com)'        { [bool](Resolve-DnsName -Name 'google.com' -ErrorAction Stop) }
            Test-Step 'HTTPS (google.com:443)'  { Test-NetConnection -ComputerName 'google.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue }
        }
        'quick' {
            Run-Native 'ipconfig.exe' @('/flushdns') | Out-Null
            Run-Native 'ipconfig.exe' @('/release') | Out-Null
            Run-Native 'ipconfig.exe' @('/renew') | Out-Null
            Log 'DNS ociscen i IP adresa obnovljena.' 'ok'
            Add-Done 'Brza popravka mreze (flush DNS, obnova IP)' 'network'
        }
        'full' {
            Run-Native 'netsh.exe' @('winsock', 'reset') | Out-Null
            Run-Native 'netsh.exe' @('int', 'ip', 'reset') | Out-Null
            Run-Native 'ipconfig.exe' @('/flushdns') | Out-Null
            Log 'Mreza resetovana. RESTARTUJ RACUNAR.' 'warn'
            Add-Done 'Potpuni reset mreze (Winsock + TCP/IP)' 'network'
        }
        'wifi' {
            $o = @(& netsh.exe wlan show interfaces 2>&1 | ForEach-Object { "$_" })
            $blocked = (($o -join "`n") -match '(?i)location permission|lokacij|error 5|access is denied|pristup.*odbijen')
            if (-not $blocked) {
                Section 'Wi-Fi konekcija (signal, kanal, band)'
                foreach ($l in $o) { if ($l.Trim()) { Log $l.TrimEnd() 'out' } }
            } else {
                Log 'Windows 11 trazi ukljucenu LOKACIJU da bi pokazao jacinu signala, kanal i band. Ostale podatke citam drugim putem.' 'warn'
            }
            Section 'Wi-Fi adapter'
            $wa = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { "$($_.PhysicalMediaType)" -match '802\.11|Wireless' -or $_.InterfaceDescription -match '(?i)wi-?fi|wireless|802\.11|wlan' })
            if ($wa.Count -eq 0) { Log 'Wi-Fi adapter nije pronadjen.' 'warn'; return }
            foreach ($a in $wa) {
                $prof = Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1
                $ip   = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
                $drv  = "$($a.DriverVersion)"
                if (-not $drv) { $drv = "$($a.DriverVersionString)" }
                $st   = 'warn'
                if ("$($a.Status)" -eq 'Up') { $st = 'ok' }
                Log ('Adapter:      {0}' -f $a.InterfaceDescription) 'info'
                Log ('Status:       {0}' -f $a.Status) $st
                if ($prof) { Log ('Mreza (SSID): {0}   ({1})' -f $prof.Name, $prof.IPv4Connectivity) 'info' }
                if ("$($a.Status)" -eq 'Up') { Log ('Brzina veze:  {0}   (manje od ~100 Mbps obicno znaci slab signal ili stari standard)' -f $a.LinkSpeed) 'info' }
                if ($ip) { Log ('IP adresa:    {0}' -f $ip) 'info' }
                Log ('MAC adresa:   {0}' -f $a.MacAddress) 'info'
                Log ('Drajver:      {0}  ({1}, {2})' -f $drv, $a.DriverProvider, $a.DriverDate) 'info'
            }
            if ($blocked) { $sync.OfferLocation = $true }
        }
    }
}

function Task-Cleanup {
    param([string[]]$Items)
    $sd = $env:SystemDrive
    $defs = @(
        @{ K = 'usertemp'; N = 'Temp fajlovi korisnika';      P = @(Get-Item "$sd\Users\*\AppData\Local\Temp" -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }); WU = $false },
        @{ K = 'wintemp';  N = 'Windows Temp';                P = @("$env:windir\Temp"); WU = $false },
        @{ K = 'wucache';  N = 'Windows Update cache';        P = @("$env:windir\SoftwareDistribution\Download"); WU = $true },
        @{ K = 'wer';      N = 'Izvjestaji o greskama (WER)'; P = @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"); WU = $false },
        @{ K = 'do';       N = 'Delivery Optimization cache'; P = @("$env:windir\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"); WU = $false }
    )
    $before = Get-FreeSpace $sd
    foreach ($it in $defs) {
        if ($Items -notcontains $it.K) { continue }
        $sz = 0
        foreach ($p in $it.P) { $sz += Get-FolderSize $p }
        if ($it.WU) { Stop-Service -Name wuauserv, bits -Force -ErrorAction SilentlyContinue }
        foreach ($p in $it.P) {
            if (Test-Path -LiteralPath $p) { Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if ($it.WU) { Start-Service -Name bits, wuauserv -ErrorAction SilentlyContinue }
        Log ('{0,-30} {1}' -f $it.N, (Format-Size $sz)) 'ok'
    }
    if (Test-Path "$sd\Windows.old") { Log 'Postoji Windows.old (stara instalacija) - obrisi ga kroz Disk Cleanup > System files ako vise ne treba.' 'info' }
    if ($Items -contains 'winsxs') {
        Section 'WinSxS ciscenje'
        Run-Native 'DISM.exe' @('/Online', '/Cleanup-Image', '/StartComponentCleanup') | Out-Null
    }
    $freed = [math]::Max(0, (Get-FreeSpace $sd) - $before)
    Log ('Oslobodjeno ukupno: {0}' -f (Format-Size $freed)) 'ok'
    Add-Done ('Ciscenje sistema (oslobodjeno {0})' -f (Format-Size $freed)) 'cleanup'
}

function Task-DriverBackup {
    $cs = Get-CimInstance Win32_ComputerSystem
    $name = (('{0}_{1}' -f $cs.Manufacturer, $cs.Model) -replace '[\\/:*?"<>|]', '') -replace '\s+', '_'
    $dest = Join-Path $Root "Drajveri\$name"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Log "Odrediste: $dest" 'info'
    Log 'Izvozim drajvere (1-5 min)...' 'info'
    try {
        $drv = @(Export-WindowsDriver -Online -Destination $dest -ErrorAction Stop)
        $drv | Select-Object @{ n = 'Fajl'; e = { Split-Path $_.OriginalFileName -Leaf } }, ClassName, ProviderName, Version, Date |
            Export-Csv (Join-Path $dest '_lista_drajvera.csv') -NoTypeInformation -UseCulture -Encoding UTF8
        Table ($drv | Group-Object ClassName | Sort-Object Count -Descending | Select-Object @{ n = 'Klasa'; e = { $_.Name } }, @{ n = 'Broj'; e = { $_.Count } })
        Log ('Izvezeno {0} drajvera ({1}).' -f $drv.Count, (Format-Size (Get-FolderSize $dest))) 'ok'
        Add-Done ('Backup drajvera ({0} kom)' -f $drv.Count) 'drvbackup'
    } catch { Log ('Greska: ' + $_.Exception.Message) 'err' }
}

function Task-DriverRestore {
    param([string]$Path)
    $before = @(Get-ProblemDevices)
    Log ('Uredjaja bez drajvera prije: {0}' -f $before.Count) 'info'
    Run-Native 'pnputil.exe' @('/add-driver', (Join-Path $Path '*.inf'), '/subdirs', '/install') | Out-Null
    $after = @(Get-ProblemDevices)
    Section 'Rezultat'
    Log ('Uredjaja bez drajvera poslije: {0}' -f $after.Count) $(if ($after.Count) { 'warn' } else { 'ok' })
    if ($after.Count) { Table $after }
    Add-Done "Instalirani drajveri iz $Path" 'drvrestore'
}

function Task-UserBackup {
    param([string]$ProfilePath, [string]$Dest, [bool]$OneDrive)
    $user = Split-Path $ProfilePath -Leaf
    Log "Korisnik: $user  ->  $Dest" 'info'
    Log 'Racunam velicine...' 'dim'
    $sel = New-Object System.Collections.Generic.List[object]
    foreach ($n in 'Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music', 'Favorites') {
        $p = Join-Path $ProfilePath $n
        if (Test-Path -LiteralPath $p) { $sel.Add([pscustomobject]@{ Folder = $n; Putanja = $p; Bajtova = (Get-FolderSize $p) }) }
    }
    if ($OneDrive) {
        foreach ($o in @(Get-ChildItem -LiteralPath $ProfilePath -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
            $sel.Add([pscustomobject]@{ Folder = $o.Name; Putanja = $o.FullName; Bajtova = (Get-FolderSize $o.FullName) })
        }
    }
    $pst = @(Get-ChildItem -LiteralPath (Join-Path $ProfilePath 'AppData\Local\Microsoft\Outlook') -Filter *.pst -ErrorAction SilentlyContinue)
    $total = [double](($sel | Measure-Object Bajtova -Sum).Sum) + [double](($pst | Measure-Object Length -Sum).Sum)
    Table ($sel | Select-Object Folder, @{ n = 'Velicina'; e = { Format-Size $_.Bajtova } })
    Log ('Ukupno za kopiranje: {0}' -f (Format-Size $total)) 'info'

    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    try {
        $free = (New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($Dest))).AvailableFreeSpace
        if ($total -gt $free) { Log ('Nema dovoljno prostora na odredistu (slobodno {0}).' -f (Format-Size $free)) 'err'; return }
    } catch {}

    $rcLog = Join-Path $Dest '_robocopy_log.txt'
    $fail = 0
    foreach ($s in $sel) {
        Section $s.Folder
        $code = Run-Native 'robocopy.exe' @($s.Putanja, (Join-Path $Dest $s.Folder), '/E', '/R:1', '/W:1', '/XJ', '/MT:16', '/NP', '/NFL', '/NDL', '/NJH', '/XF', 'desktop.ini', 'thumbs.db', "/LOG+:$rcLog", '/TEE')
        if ($code -ge 8) { Log "$($s.Folder): neki fajlovi nisu kopirani (vidi _robocopy_log.txt)." 'warn'; $fail++ } else { Log "$($s.Folder): OK" 'ok' }
    }

    Section 'Browser bookmarks i Outlook'
    $bm = Join-Path $Dest '_Browser'
    New-Item -ItemType Directory -Path $bm -Force | Out-Null
    $srcs = @(
        @{ N = 'Chrome';  P = (Join-Path $ProfilePath 'AppData\Local\Google\Chrome\User Data\*\Bookmarks') },
        @{ N = 'Edge';    P = (Join-Path $ProfilePath 'AppData\Local\Microsoft\Edge\User Data\*\Bookmarks') },
        @{ N = 'Firefox'; P = (Join-Path $ProfilePath 'AppData\Roaming\Mozilla\Firefox\Profiles\*\places.sqlite') }
    )
    foreach ($s in $srcs) {
        foreach ($f in @(Get-ChildItem -Path $s.P -File -ErrorAction SilentlyContinue)) {
            $t = Join-Path $bm ('{0}_{1}_{2}' -f $s.N, $f.Directory.Name, $f.Name)
            try { Copy-Item -LiteralPath $f.FullName -Destination $t -Force -ErrorAction Stop; Log ('{0} ({1}) kopiran' -f $s.N, $f.Directory.Name) 'ok' }
            catch { Log ('{0}: fajl zakljucan - zatvori browser i ponovi' -f $s.N) 'warn' }
        }
    }
    if ($pst.Count) {
        $od = Join-Path $Dest '_Outlook'
        New-Item -ItemType Directory -Path $od -Force | Out-Null
        foreach ($p in $pst) {
            try { Copy-Item -LiteralPath $p.FullName -Destination $od -Force -ErrorAction Stop; Log ('{0} ({1}) kopiran' -f $p.Name, (Format-Size $p.Length)) 'ok' }
            catch { Log ('{0}: zakljucan - zatvori Outlook' -f $p.Name) 'warn' }
        }
    }

    @(
        "Backup korisnika: $user"
        "Racunar: $PC"
        "Datum: $(Get-Date -Format 'dd.MM.yyyy HH:mm')"
        "Izvor: $ProfilePath"
        "Velicina: $(Format-Size (Get-FolderSize $Dest))"
    ) | Set-Content -Path (Join-Path $Dest '_info.txt') -Encoding UTF8

    Section 'Rezultat'
    Log ('Backup zavrsen: {0} na odredistu.' -f (Format-Size (Get-FolderSize $Dest))) $(if ($fail) { 'warn' } else { 'ok' })
    Add-Done ('Backup podataka korisnika {0} ({1})' -f $user, (Format-Size $total)) 'userbackup'
}

function Task-Wifi {
    $out = Join-Path $ReportDir 'wifi_i_licenca.txt'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Racunar: $PC   Datum: $(Get-Date -Format 'dd.MM.yyyy HH:mm')")
    $lines.Add('')

    Section 'Sacuvane Wi-Fi mreze'
    $tmp = Join-Path $env:windir ('Temp\kt_wifi_' + (Get-Random))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    & netsh.exe wlan export profile key=clear "folder=$tmp" 2>&1 | Out-Null
    $wifi = @(foreach ($x in @(Get-ChildItem -LiteralPath $tmp -Filter *.xml -ErrorAction SilentlyContinue)) {
        try {
            [xml]$xml = Get-Content -LiteralPath $x.FullName -Raw
            $p = $xml.WLANProfile
            $key = $p.MSM.security.sharedKey.keyMaterial
            [pscustomobject]@{
                'Mreza'   = $p.name
                'Lozinka' = $(if ($key) { $key } else { '(otvorena ili enterprise)' })
                'Zastita' = $p.MSM.security.authEncryption.authentication
            }
        } catch {}
    })
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($wifi.Count) {
        $wifi = @($wifi | Sort-Object Mreza)
        Table ($wifi | Select-Object Mreza, Zastita)
        Log ('{0} mreza - lozinke su upisane samo u fajl (ne prikazuju se na ekranu).' -f $wifi.Count) 'info'
        $lines.Add('WI-FI MREZE')
        foreach ($w in $wifi) { $lines.Add(('{0,-32} {1}' -f $w.Mreza, $w.Lozinka)) }
    } else { Log 'Nema sacuvanih Wi-Fi mreza (ili racunar nema Wi-Fi).' 'info' }

    Section 'Windows licenca'
    $oem = $null
    try { $oem = (Get-CimInstance SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey } catch {}
    $os = Get-CimInstance Win32_OperatingSystem
    Log ('Verzija: {0}' -f $os.Caption) 'info'
    if ($oem) { Log "OEM kljuc iz BIOS-a: $oem" 'ok' } else { Log 'Nema OEM kljuca u BIOS-u (digitalna licenca, retail ili volume kljuc).' 'info' }
    $lines.Add('')
    $lines.Add('WINDOWS LICENCA')
    $lines.Add("Verzija: $($os.Caption)")
    $lines.Add("OEM kljuc (BIOS): $(if ($oem) { $oem } else { 'nema' })")
    $lines | Set-Content -Path $out -Encoding UTF8
    Log "Sacuvano: $out" 'ok'
    Log 'Fajl sadrzi lozinke - predaj ga klijentu i obrisi sa USB-a.' 'warn'
}

function Task-BitLocker {
    param([bool]$Suspend)
    $out = Join-Path $ReportDir 'bitlocker_kljucevi.txt'
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Log 'BitLocker modul nije dostupan (Windows Home) - koristim manage-bde.' 'info'
        Run-Native 'manage-bde.exe' @('-status') | Out-Null
        & manage-bde.exe -protectors -get $env:SystemDrive 2>&1 | Set-Content -Path $out -Encoding UTF8
        Log "Zastite (ako postoje) sacuvane u: $out" 'ok'
        return
    }
    $vols = @(Get-BitLockerVolume -ErrorAction SilentlyContinue)
    Section 'Status'
    Table ($vols | Select-Object @{ n = 'Particija'; e = { $_.MountPoint } }, @{ n = 'Status'; e = { "$($_.VolumeStatus)" } }, @{ n = 'Zastita'; e = { "$($_.ProtectionStatus)" } }, @{ n = 'Enkripcija %'; e = { $_.EncryptionPercentage } })
    $enc = @($vols | Where-Object { "$($_.VolumeStatus)" -ne 'FullyDecrypted' })
    if ($enc.Count -eq 0) { Log 'Nijedna particija nije enkriptovana.' 'ok'; return }

    if ($Suspend) {
        try {
            Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 -ErrorAction Stop | Out-Null
            Log 'BitLocker pauziran do sljedeceg restarta. Sad mozes raditi BIOS update / zamjenu hardvera.' 'ok'
            Add-Done 'BitLocker pauziran do sljedeceg restarta' 'bitlocker'
        } catch { Log ('Nije uspjelo: ' + $_.Exception.Message) 'err' }
        return
    }

    Section 'Recovery kljucevi'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Racunar: $PC   Datum: $(Get-Date -Format 'dd.MM.yyyy HH:mm')")
    foreach ($v in $enc) {
        $rp = @($v.KeyProtector | Where-Object { "$($_.KeyProtectorType)" -eq 'RecoveryPassword' })
        if ($rp.Count -eq 0) { Log "$($v.MountPoint) nema recovery password zastitu." 'warn' }
        foreach ($k in $rp) {
            Log ('{0}  ID {1}' -f $v.MountPoint, $k.KeyProtectorId) 'info'
            Log ('     KLJUC: {0}' -f $k.RecoveryPassword) 'warn'
            $lines.Add(('{0}  ID: {1}' -f $v.MountPoint, $k.KeyProtectorId))
            $lines.Add(('     KLJUC: {0}' -f $k.RecoveryPassword))
        }
    }
    $lines | Set-Content -Path $out -Encoding UTF8
    Log "Kljucevi sacuvani: $out  (predaj klijentu, ne ostavljaj na USB-u)" 'ok'
    Add-Done 'Sacuvani BitLocker recovery kljucevi' 'bitlocker'
}

function Task-RestorePoint {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        New-ItemProperty -Path $key -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description ('{0} servis {1}' -f $Firma, $Stamp) -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Log 'Tacka vracanja kreirana.' 'ok'
        Add-Done 'Kreirana tacka vracanja sistema' 'restore'
    } catch { Log ('Nije uspjelo: ' + $_.Exception.Message) 'err' }
    finally { Remove-ItemProperty -Path $key -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue }
    try {
        $rp = @(Get-ComputerRestorePoint -ErrorAction Stop | Select-Object -Last 5)
        if ($rp.Count) {
            Section 'Zadnje tacke vracanja'
            foreach ($r in $rp) { Log ('{0}  {1}' -f $r.ConvertToDateTime($r.CreationTime).ToString('dd.MM.yyyy HH:mm'), $r.Description) 'out' }
        }
    } catch {}
}

function Task-WingetUpgrade {
    $wg = Get-WingetPath
    if (-not $wg) { Log 'winget nije dostupan (instaliraj "App Installer" iz Microsoft Store-a).' 'warn'; return }
    Run-Native $wg @('upgrade', '--all', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Utf8 | Out-Null
    Log 'Azuriranje programa zavrseno.' 'ok'
    Add-Done 'Azuriranje svih programa (winget)' 'wgupdate'
}

function Task-WingetInstall {
    param([string[]]$Ids)
    $wg = Get-WingetPath
    if (-not $wg) { Log 'winget nije dostupan (instaliraj "App Installer" iz Microsoft Store-a).' 'warn'; return }
    $okList = @()
    foreach ($id in $Ids) {
        Section $id
        $code = Run-Native $wg @('install', '--id', $id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Utf8
        if ($code -eq 0) { Log "$id instaliran." 'ok'; $okList += $id } else { Log "$id - kod $code (mozda je vec instaliran)" 'warn' }
    }
    if ($okList.Count) { Add-Done ('Instalirani programi: ' + ($okList -join ', ')) 'wgstd' }
}

function Task-WingetExport {
    $wg = Get-WingetPath
    if (-not $wg) { Log 'winget nije dostupan.' 'warn'; return }
    $dir = Join-Path $Root 'Programi'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $f = Join-Path $dir "$PC.json"
    Run-Native $wg @('export', '-o', $f, '--accept-source-agreements') -Utf8 | Out-Null
    if (Test-Path $f) { Log "Lista programa sacuvana: $f" 'ok'; Log 'Na novom racunaru: Programi > Uvezi listu programa.' 'dim' }
}

function Task-WingetImport {
    param([string]$File)
    $wg = Get-WingetPath
    if (-not $wg) { Log 'winget nije dostupan.' 'warn'; return }
    Run-Native $wg @('import', '-i', $File, '--ignore-unavailable', '--accept-package-agreements', '--accept-source-agreements') -Utf8 | Out-Null
    Log 'Uvoz liste zavrsen.' 'ok'
    Add-Done ('Instalirani programi iz liste ' + (Split-Path $File -Leaf)) 'wgstd'
}

function Task-Programs {
    Log 'Citam programe: 64 i 32-bit, svi korisnicki profili, Store aplikacije...' 'dim'
    $p = @(Get-InstalledPrograms)
    $csv = Join-Path $ReportDir 'instalirani_programi.csv'
    $p | Select-Object Naziv, Verzija, Izdavac, Instalirano, VelicinaMB, Tip, Lokacija | Export-Csv $csv -NoTypeInformation -UseCulture -Encoding UTF8
    Section 'Po izvoru'
    Table ($p | Group-Object Tip | Sort-Object Name | Select-Object @{ n = 'Izvor'; e = { $_.Name } }, @{ n = 'Broj'; e = { $_.Count } })
    Log ('Ukupno {0} programa. CSV: {1}' -f $p.Count, $csv) 'ok'
    $sync.Programs = $p
    $sync.ShowPrograms = $true
}

function Split-CommandLine {
    param([string]$Cmd)
    $c = $Cmd.Trim()
    if ($c.StartsWith('"')) {
        $i = $c.IndexOf('"', 1)
        if ($i -gt 0) { return @($c.Substring(1, $i - 1), $c.Substring($i + 1).Trim()) }
    }
    $m = [regex]::Match($c, '^(.+?\.exe)(\s+.*)?$', 'IgnoreCase')
    if ($m.Success) { return @($m.Groups[1].Value, $m.Groups[2].Value.Trim()) }
    return @($c, '')
}

function Invoke-UninstallItems {
    param($Items, [bool]$Quiet)
    $removed = New-Object System.Collections.Generic.List[object]
    foreach ($it in @($Items)) {
        Section $it.Naziv
        if ($it.Paket) {
            try { Remove-AppxPackage -Package $it.Paket -AllUsers -ErrorAction Stop; Log 'Store aplikacija uklonjena (svi korisnici).' 'ok'; $removed.Add($it) }
            catch {
                try { Remove-AppxPackage -Package $it.Paket -ErrorAction Stop; Log 'Store aplikacija uklonjena.' 'ok'; $removed.Add($it) }
                catch { Log ('Nije uspjelo: ' + $_.Exception.Message) 'err' }
            }
            continue
        }
        $cmd = $it.Uninstall
        if ($Quiet -and $it.QuietUninstall) { $cmd = $it.QuietUninstall }
        if (-not $cmd) { Log 'Program nema komandu za deinstalaciju u registry-ju.' 'warn'; continue }
        $parts = Split-CommandLine $cmd
        $exe = [Environment]::ExpandEnvironmentVariables($parts[0])
        $a = $parts[1]
        if ($exe -match '(?i)msiexec') {
            $a = $a -replace '(?i)/I\s*(\{)', '/X$1'
            if ($Quiet -and $a -notmatch '(?i)/q') { $a = ($a + ' /qn /norestart').Trim() }
        } elseif ($Quiet -and -not $it.QuietUninstall) {
            Log 'Program nema tihu deinstalaciju - otvorice se njegov prozor.' 'dim'
        }
        Log ('> {0} {1}' -f $exe, $a) 'cmd'
        try {
            $sp = @{ FilePath = $exe; PassThru = $true; Wait = $true; ErrorAction = 'Stop' }
            if ($a) { $sp.ArgumentList = $a }
            $pr = Start-Process @sp
            switch ($pr.ExitCode) {
                0       { Log 'Deinstalacija zavrsena.' 'ok'; $removed.Add($it) }
                3010    { Log 'Deinstalirano - potreban restart.' 'ok'; $removed.Add($it) }
                1605    { Log 'Program vise nije instaliran (1605).' 'info' }
                1602    { Log 'Deinstalacija otkazana.' 'warn' }
                default { Log ('Uninstaller je vratio kod {0}.' -f $pr.ExitCode) 'warn' }
            }
        } catch { Log ('Ne mogu pokrenuti uninstaller: ' + $_.Exception.Message) 'err' }
    }
    return $removed
}

function Task-Uninstall {
    param($Items, [bool]$Quiet)
    $removed = @(Invoke-UninstallItems -Items $Items -Quiet $Quiet)
    Log 'Osvjezavam listu programa...' 'dim'
    $now = @(Get-InstalledPrograms)
    foreach ($it in @($Items)) {
        if ($now | Where-Object { $_.Naziv -eq $it.Naziv -and $_.Tip -eq $it.Tip }) { Log ('Jos uvijek u listi: {0} (mozda treba restart ili je otkazano)' -f $it.Naziv) 'warn' }
    }
    if ($removed.Count) { Add-Done ('Deinstalirano: ' + (($removed | ForEach-Object { $_.Naziv }) -join ', ')) 'uninstall' }
    $sync.Programs = $now
    $sync.ShowPrograms = $true
}

# =====================================================================
#  v3: pomocne funkcije za registry
# =====================================================================
function Add-DoneKey {
    param([string]$k)
    if ($k -and -not $sync.DoneKeys.Contains($k)) { [void]$sync.DoneKeys.Add($k) }
}
function Join-RegPath {
    param([string]$Prefix, [string]$Path)
    if ($Prefix) { return "$Prefix\$Path" }
    return $Path
}
function Get-HiveBase {
    param([string]$Hive)
    if ($Hive -eq 'HKU') { return [Microsoft.Win32.RegistryKey]::OpenBaseKey('Users', 'Default') }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
}
function Get-LoadedUserSids {
    $h = [Microsoft.Win32.RegistryKey]::OpenBaseKey('Users', 'Default')
    try { return @($h.GetSubKeyNames() | Where-Object { $_ -match '^S-1-5-21-[\d-]+$' }) } finally { $h.Close() }
}
function Set-RegDword {
    param([Microsoft.Win32.RegistryKey]$Base, [string]$Path, [string]$Name, [int]$Value)
    $k = $Base.CreateSubKey($Path)
    try { $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $k.Close() }
}
function Test-Rooted {
    param([string]$p)
    try { return [System.IO.Path]::IsPathRooted($p) } catch { return $false }
}

# =====================================================================
#  v3: PROGRAMI PRI POKRETANJU (isto sto i Task Manager > Startup)
# =====================================================================
$StartupApprovedRoot = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

function Get-ApprovedState {
    param([Microsoft.Win32.RegistryKey]$Base, [string]$Prefix, [string]$Sub, [string]$Name)
    $k = $null
    try { $k = $Base.OpenSubKey((Join-RegPath $Prefix "$StartupApprovedRoot\$Sub"), $false) } catch {}
    if (-not $k) { return $true }
    try {
        $v = $k.GetValue($Name)
        if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }
        return $true
    } finally { $k.Close() }
}

function Set-ApprovedState {
    param([Microsoft.Win32.RegistryKey]$Base, [string]$Prefix, [string]$Sub, [string]$Name, [bool]$Enable)
    $k = $Base.CreateSubKey((Join-RegPath $Prefix "$StartupApprovedRoot\$Sub"))
    if (-not $k) { throw 'Ne mogu otvoriti StartupApproved kljuc.' }
    try {
        $b = New-Object byte[] 12
        if ($Enable) { $b[0] = 2 }
        else { $b[0] = 3; [BitConverter]::GetBytes([DateTime]::Now.ToFileTime()).CopyTo($b, 4) }
        $k.SetValue($Name, $b, [Microsoft.Win32.RegistryValueKind]::Binary)
    } finally { $k.Close() }
}

function Resolve-ExePath {
    param([string]$Cmd)
    if (-not $Cmd) { return '' }
    try {
        $p = [Environment]::ExpandEnvironmentVariables((Split-CommandLine $Cmd)[0]).Trim()
        if (-not $p) { return '' }
        if (-not (Test-Rooted $p)) {
            $c = Get-Command $p -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($c) { return $c.Source }
            return ''
        }
        return $p
    } catch { return '' }
}

function Get-FileCompany {
    param([string]$Path)
    if (-not $Path) { return '' }
    try { return ('' + [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path).CompanyName).Trim() } catch { return '' }
}

function New-StartupItem {
    param([string]$Naziv, [string]$Komanda, [string]$Izvor, [bool]$On, [string]$Kind,
          [string]$Hive = '', [string]$Prefix = '', [string]$RunPath = '', [string]$ApprovedSub = '', [string]$ValueName = '',
          [string]$FilePath = '', [string]$TaskPath = '', [string]$TaskName = '', [string]$Target = '')
    $exe = $Target
    if ($exe -and -not (Test-Rooted $exe)) { $exe = Resolve-ExePath $exe }
    if (-not $exe) { $exe = Resolve-ExePath $Komanda }
    $fajl = 'OK'
    try { if ($exe -and (Test-Rooted $exe) -and -not (Test-Path -LiteralPath $exe)) { $fajl = 'NEMA FAJLA' } } catch {}
    $st = 'Iskljucen'
    if ($On) { $st = 'Ukljucen' }
    [pscustomobject]@{
        Status = $st; Naziv = $Naziv; Izdavac = (Get-FileCompany $exe); Izvor = $Izvor; Komanda = $Komanda; Fajl = $fajl
        Kind = $Kind; Hive = $Hive; Prefix = $Prefix; RunPath = $RunPath; ApprovedSub = $ApprovedSub; ValueName = $ValueName
        FilePath = $FilePath; TaskPath = $TaskPath; TaskName = $TaskName; Exe = [string]$exe
    }
}

function Get-StartupItems {
    $out   = New-Object System.Collections.Generic.List[object]
    $run   = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $run32 = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    $profiles = @{}
    foreach ($pr in @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.LocalPath })) { $profiles[$pr.SID] = $pr }
    $sids = @(Get-LoadedUserSids)
    $hklm = Get-HiveBase 'HKLM'
    $hku  = Get-HiveBase 'HKU'
    try {
        $src = New-Object System.Collections.Generic.List[object]
        $src.Add(@{ B = $hklm; H = 'HKLM'; P = ''; R = $run; A = 'Run'; I = 'Registry - svi korisnici' })
        if ([Environment]::Is64BitOperatingSystem) { $src.Add(@{ B = $hklm; H = 'HKLM'; P = ''; R = $run32; A = 'Run32'; I = 'Registry - svi korisnici (32-bit)' }) }
        foreach ($sid in $sids) { $src.Add(@{ B = $hku; H = 'HKU'; P = $sid; R = $run; A = 'Run'; I = ('Registry - ' + (Get-ProfileName $sid $profiles)) }) }
        foreach ($s in $src) {
            $k = $null
            try { $k = $s.B.OpenSubKey((Join-RegPath $s.P $s.R), $false) } catch {}
            if (-not $k) { continue }
            try {
                foreach ($n in $k.GetValueNames()) {
                    if (-not $n) { continue }
                    $cmd = "$($k.GetValue($n))"
                    if (-not $cmd.Trim()) { continue }
                    $on = Get-ApprovedState $s.B $s.P $s.A $n
                    $out.Add((New-StartupItem -Naziv $n -Komanda $cmd -Izvor $s.I -On $on -Kind 'reg' -Hive $s.H -Prefix $s.P -RunPath $s.R -ApprovedSub $s.A -ValueName $n))
                }
            } finally { $k.Close() }
        }

        $folders = New-Object System.Collections.Generic.List[object]
        $folders.Add(@{ D = [Environment]::GetFolderPath('CommonStartup'); B = $hklm; H = 'HKLM'; P = ''; I = 'Startup folder - svi korisnici' })
        foreach ($sid in $sids) {
            if (-not $profiles.ContainsKey($sid)) { continue }
            $folders.Add(@{ D = (Join-Path $profiles[$sid].LocalPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'); B = $hku; H = 'HKU'; P = $sid; I = ('Startup folder - ' + (Get-ProfileName $sid $profiles)) })
        }
        $sh = $null
        try { $sh = New-Object -ComObject WScript.Shell } catch {}
        foreach ($f in $folders) {
            if (-not $f.D -or -not (Test-Path -LiteralPath $f.D)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $f.D -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
                $target = $file.FullName
                $cmd = $file.FullName
                if ($file.Extension -eq '.lnk' -and $sh) {
                    $target = ''
                    try {
                        $l = $sh.CreateShortcut($file.FullName)
                        $target = [string]$l.TargetPath
                        if ($target) { $cmd = ('"{0}" {1}' -f $target, $l.Arguments).Trim() }
                    } catch {}
                }
                $on = Get-ApprovedState $f.B $f.P 'StartupFolder' $file.Name
                $out.Add((New-StartupItem -Naziv $file.BaseName -Komanda $cmd -Izvor $f.I -On $on -Kind 'folder' -Hive $f.H -Prefix $f.P -ApprovedSub 'StartupFolder' -ValueName $file.Name -FilePath $file.FullName -Target $target))
            }
        }
    } finally { $hklm.Close(); $hku.Close() }

    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })) {
        $trg = @($t.Triggers | Where-Object { $_ -and $_.CimClass.CimClassName -match 'Logon|Boot' })
        if ($trg.Count -eq 0) { continue }
        $a = @($t.Actions | Where-Object { $_.Execute }) | Select-Object -First 1
        $cmd = ''; $exe = ''
        if ($a) {
            $exe = [Environment]::ExpandEnvironmentVariables(("$($a.Execute)").Trim().Trim('"'))
            $cmd = ('"{0}" {1}' -f $exe, $a.Arguments).Trim()
        }
        $out.Add((New-StartupItem -Naziv $t.TaskName -Komanda $cmd -Izvor 'Zakazani zadatak (prijava/start)' -On ("$($t.State)" -ne 'Disabled') -Kind 'task' -TaskPath $t.TaskPath -TaskName $t.TaskName -Target $exe))
    }
    return $out
}

function Set-StartupItemState {
    param($Item, [bool]$Enable)
    if ($Item.Kind -eq 'task') {
        if ($Enable) { Enable-ScheduledTask -TaskPath $Item.TaskPath -TaskName $Item.TaskName -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskPath $Item.TaskPath -TaskName $Item.TaskName -ErrorAction Stop | Out-Null }
        return
    }
    $base = Get-HiveBase $Item.Hive
    try { Set-ApprovedState $base $Item.Prefix $Item.ApprovedSub $Item.ValueName $Enable } finally { $base.Close() }
}

function Remove-StartupItem {
    param($Item, [string]$BackupDir)
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    $logf  = Join-Path $BackupDir '_obrisano.txt'
    $stamp = Get-Date -Format 'dd.MM.yyyy HH:mm'
    switch ($Item.Kind) {
        'reg' {
            $base = Get-HiveBase $Item.Hive
            try {
                $k = $base.OpenSubKey((Join-RegPath $Item.Prefix $Item.RunPath), $true)
                if ($k) { try { $k.DeleteValue($Item.ValueName, $false) } finally { $k.Close() } }
                $ak = $base.OpenSubKey((Join-RegPath $Item.Prefix "$StartupApprovedRoot\$($Item.ApprovedSub)"), $true)
                if ($ak) { try { $ak.DeleteValue($Item.ValueName, $false) } finally { $ak.Close() } }
            } finally { $base.Close() }
            $hp = 'HKEY_LOCAL_MACHINE'
            if ($Item.Hive -eq 'HKU') { $hp = 'HKEY_USERS' }
            Add-Content -Path $logf -Encoding UTF8 -Value ("[{0}] REGISTRY  {1}\{2}`r`n    Naziv: {3}`r`n    Komanda: {4}`r`n" -f $stamp, $hp, (Join-RegPath $Item.Prefix $Item.RunPath), $Item.ValueName, $Item.Komanda)
        }
        'folder' {
            Move-Item -LiteralPath $Item.FilePath -Destination (Join-Path $BackupDir (Split-Path $Item.FilePath -Leaf)) -Force -ErrorAction Stop
            Add-Content -Path $logf -Encoding UTF8 -Value ("[{0}] STARTUP FOLDER  {1}`r`n    (fajl je premjesten ovdje - vrati ga nazad da se opet pokrece)`r`n" -f $stamp, $Item.FilePath)
        }
        'task' {
            $safe = ($Item.TaskName -replace '[\\/:*?"<>|]', '_')
            try { Export-ScheduledTask -TaskPath $Item.TaskPath -TaskName $Item.TaskName -ErrorAction Stop | Set-Content -Path (Join-Path $BackupDir "zadatak_$safe.xml") -Encoding Unicode } catch {}
            Unregister-ScheduledTask -TaskPath $Item.TaskPath -TaskName $Item.TaskName -Confirm:$false -ErrorAction Stop
            Add-Content -Path $logf -Encoding UTF8 -Value ("[{0}] ZAKAZANI ZADATAK  {1}{2}`r`n    Vracanje: schtasks /create /xml zadatak_{3}.xml /tn ""{2}""`r`n" -f $stamp, $Item.TaskPath, $Item.TaskName, $safe)
        }
    }
}

function Task-Startup {
    Log 'Citam registry, startup foldere i zakazane zadatke...' 'dim'
    $items = @(Get-StartupItems)
    $on = @($items | Where-Object { $_.Status -eq 'Ukljucen' }).Count
    Log ('Pronadjeno {0} stavki, ukljuceno {1}.' -f $items.Count, $on) 'info'
    $miss = @($items | Where-Object { $_.Fajl -ne 'OK' })
    if ($miss.Count) { Log ('{0} stavki pokazuje na fajl koji ne postoji (ostaci obrisanih programa) - mogu se obrisati.' -f $miss.Count) 'warn' }
    $sync.StartupItems = $items
    $sync.ShowStartup = $true
}

# =====================================================================
#  v3: SNIMAK STANJA (prije / poslije)
# =====================================================================
function Get-BootPerf {
    $r = @{ Sec = $null; At = $null }
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction Stop
        $x  = [xml]$ev.ToXml()
        $bt = @($x.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' })[0].'#text'
        if ($bt) { $r.Sec = [int][math]::Round([double]$bt / 1000); $r.At = $ev.TimeCreated.ToString('o') }
    } catch {}
    return $r
}

function Get-Snapshot {
    param([int]$Crit = 0, [int]$Warn = 0)
    $c  = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive)
    $st = @(Get-StartupItems)
    $pq = @(Get-InstalledPrograms -Quick).Count
    $ps = @(Get-StoreApps).Count
    $b  = Get-BootPerf
    return @{
        Time      = (Get-Date).ToString('o')
        FreeC     = [double]$c.FreeSpace
        StartupOn = @($st | Where-Object { $_.Status -eq 'Ukljucen' }).Count
        Programs  = $pq + $ps
        BootSec   = $b.Sec
        BootAt    = $b.At
        Crit      = $Crit
        Warn      = $Warn
    }
}

# =====================================================================
#  v3: DEBLOAT
# =====================================================================
# P = obrasci imena paketa, N = naziv za prikaz ('' = koristi ime aplikacije), R = preporuceno, G = svaki paket posebno
$BloatStore = @(
    @{ P = @('king.com.*');                                   N = '';                                R = $true;  G = $true }
    @{ P = @('*TikTok*', 'BytedancePte.Ltd.*');               N = 'TikTok';                          R = $true }
    @{ P = @('Disney.*');                                     N = 'Disney+';                         R = $true }
    @{ P = @('AmazonVideo.PrimeVideo');                       N = 'Prime Video';                     R = $true }
    @{ P = @('*Netflix*');                                    N = 'Netflix';                         R = $false }
    @{ P = @('SpotifyAB.SpotifyMusic');                       N = 'Spotify';                         R = $false }
    @{ P = @('*Instagram*', '*Facebook*');                    N = '';                                R = $false; G = $true }
    @{ P = @('Microsoft.MicrosoftSolitaireCollection');       N = 'Solitaire kolekcija';             R = $true }
    @{ P = @('Microsoft.BingNews', 'Microsoft.News');         N = 'Microsoft Vijesti (News)';        R = $true }
    @{ P = @('Microsoft.BingWeather');                        N = 'Vremenska prognoza (Weather)';    R = $false }
    @{ P = @('Microsoft.BingFinance', 'Microsoft.BingSports'); N = '';                               R = $true;  G = $true }
    @{ P = @('Microsoft.GetHelp');                            N = 'Get Help';                        R = $true }
    @{ P = @('Microsoft.Getstarted');                         N = 'Savjeti (Tips)';                  R = $true }
    @{ P = @('Microsoft.WindowsFeedbackHub');                 N = 'Feedback Hub';                    R = $true }
    @{ P = @('Microsoft.MixedReality.Portal');                N = 'Mixed Reality Portal';            R = $true }
    @{ P = @('Microsoft.Microsoft3DViewer', 'Microsoft.3DBuilder', 'Microsoft.Print3D'); N = '';      R = $true;  G = $true }
    @{ P = @('Microsoft.SkypeApp');                           N = 'Skype (servis ugasen)';           R = $true }
    @{ P = @('Microsoft.People');                             N = 'People';                          R = $true }
    @{ P = @('Microsoft.Messaging', 'Microsoft.OneConnect');  N = '';                                R = $true;  G = $true }
    @{ P = @('Microsoft.MicrosoftOfficeHub');                 N = 'Microsoft 365 (Office) reklamna aplikacija'; R = $true }
    @{ P = @('Microsoft.549981C3F5F10');                      N = 'Cortana';                         R = $true }
    @{ P = @('Clipchamp.Clipchamp');                          N = 'Clipchamp';                       R = $true }
    @{ P = @('MicrosoftTeams');                               N = 'Teams (licni chat iz Windows 11)'; R = $true }
    @{ P = @('Microsoft.PowerAutomateDesktop');               N = 'Power Automate';                  R = $true }
    @{ P = @('MicrosoftCorporationII.MicrosoftFamily');       N = 'Microsoft Family';                R = $true }
    @{ P = @('Microsoft.Windows.DevHome');                    N = 'Dev Home';                        R = $true }
    @{ P = @('Microsoft.ZuneVideo');                          N = 'Filmovi i TV';                    R = $false }
    @{ P = @('Microsoft.WindowsMaps');                        N = 'Mape';                            R = $false }
    @{ P = @('Microsoft.YourPhone');                          N = 'Phone Link (veza sa telefonom)';  R = $false }
    @{ P = @('Microsoft.GamingApp', 'Microsoft.XboxApp');     N = 'Xbox aplikacija';                 R = $false }
    @{ P = @('Microsoft.XboxGamingOverlay');                  N = 'Xbox Game Bar';                   R = $false }
    @{ P = @('Microsoft.OutlookForWindows');                  N = 'Novi Outlook';                    R = $false }
    @{ P = @('Microsoft.Copilot');                            N = 'Copilot';                         R = $false }
    @{ P = @('Microsoft.BingSearch');                         N = 'Bing pretraga';                   R = $false }
    @{ P = @('Microsoft.Todos');                              N = 'Microsoft To Do';                 R = $false }
    @{ P = @('*Duolingo*', '*PhotoshopExpress*', '*PicsArt*', '*Twitter*', '*Shazam*', '*Flipboard*', '*PandoraMedia*', '*Hulu*',
             '*CyberLink*', '*WinZipUniversal*', '*Asphalt*', '*MarchofEmpires*', '*HiddenCity*', '*FarmVille*', '*RoyalRevolt*',
             '*SlingTV*', '*EclipseManager*', '*Phototastic*', '*BubbleWitch*', '*ACGMediaPlayer*', '*ActiproSoftware*', '*LinkedIn*'); N = ''; R = $true; G = $true }
)
$BloatWin32 = @(
    @{ P = @('McAfee*');                                N = 'McAfee - najcesce predinstalirani trial';         R = $true }
    @{ P = @('Norton*');                                N = 'Norton - provjeri da li ga klijent placa';        R = $false }
    @{ P = @('WildTangent*');                           N = 'WildTangent igre (predinstalirano)';              R = $true }
    @{ P = @('Booking.com*');                           N = 'Booking.com promo';                               R = $true }
    @{ P = @('ExpressVPN*');                            N = 'ExpressVPN trial';                                R = $false }
    @{ P = @('Dropbox*Promotion*', 'Dropbox 25 GB*');   N = 'Dropbox promo';                                   R = $true }
    @{ P = @('Microsoft 365 - *', 'Microsoft OneNote - *'); N = 'Predinstalirani Office (trial / jezicki paket)'; R = $false }
)
$TweakDefs = @(
    @{ K = 'ads';       N = 'Iskljuci reklame, prijedloge i automatsko instaliranje sponzorisanih aplikacija'; R = $true }
    @{ K = 'bing';      N = 'Iskljuci Bing / web rezultate u Start pretrazi';                                    R = $false }
    @{ K = 'widgets';   N = 'Iskljuci Widgets / Vijesti na taskbaru (vidi se nakon restarta)';                   R = $false }
    @{ K = 'telemetry'; N = 'Smanji slanje podataka Microsoftu (telemetrija) na minimum';                       R = $false }
)

function Task-DebloatScan {
    Log 'Trazim bloatware (Store aplikacije i predinstalirani programi)...' 'dim'
    $found = New-Object System.Collections.Generic.List[object]
    $seen  = @{}
    $store = @(Get-StoreApps)
    foreach ($d in $BloatStore) {
        foreach ($s in $store) {
            if ($seen.ContainsKey($s.Paket)) { continue }
            $nm = ($s.Paket -split '_')[0]
            $hit = $false
            foreach ($pat in $d.P) { if ($nm -like $pat) { $hit = $true; break } }
            if (-not $hit) { continue }
            $seen[$s.Paket] = 1
            $label = $d.N
            if ($d.G -or -not $label) { $label = $s.Naziv }
            $found.Add(@{ Kind = 'store'; Naziv = $label; Opis = ('Store aplikacija - ' + $s.Izdavac); R = [bool]$d.R; Paket = $s.Paket; Name = $nm })
        }
    }
    $progs = @(Get-InstalledPrograms -Quick)
    foreach ($d in $BloatWin32) {
        foreach ($p in $progs) {
            $key = 'w|' + $p.Naziv + '|' + $p.Tip
            if ($seen.ContainsKey($key)) { continue }
            $hit = $false
            foreach ($pat in $d.P) { if ($p.Naziv -like $pat) { $hit = $true; break } }
            if (-not $hit) { continue }
            $seen[$key] = 1
            $found.Add(@{ Kind = 'win32'; Naziv = $p.Naziv; Opis = ('{0} ({1})' -f $d.N, $p.Tip); R = [bool]$d.R; Tip = $p.Tip; Uninstall = $p.Uninstall; QuietUninstall = $p.QuietUninstall; Paket = '' })
        }
    }
    Log ('Pronadjeno {0} stavki.' -f $found.Count) 'info'
    $sync.DebloatFound = $found.ToArray()
    $sync.ShowDebloat = $true
}

function Invoke-Tweak {
    param([string]$Key)
    $hklm = Get-HiveBase 'HKLM'
    $hku  = Get-HiveBase 'HKU'
    try {
        $sids = @(Get-LoadedUserSids)
        switch ($Key) {
            'ads' {
                Set-RegDword $hklm 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
                Set-RegDword $hklm 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 1
                foreach ($sid in $sids) {
                    $cdm = "$sid\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
                    foreach ($n in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'PreInstalledAppsEnabled',
                                   'OemPreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                                   'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-310093Enabled') {
                        Set-RegDword $hku $cdm $n 0
                    }
                    Set-RegDword $hku "$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'Start_IrisRecommendations' 0
                    Set-RegDword $hku "$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'ShowSyncProviderNotifications' 0
                    Set-RegDword $hku "$sid\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" 'ScoobeSystemSettingEnabled' 0
                }
                Log 'Reklame, prijedlozi i automatsko instaliranje sponzorisanih aplikacija iskljuceni.' 'ok'
            }
            'bing' {
                foreach ($sid in $sids) {
                    Set-RegDword $hku "$sid\Software\Microsoft\Windows\CurrentVersion\Search" 'BingSearchEnabled' 0
                    Set-RegDword $hku "$sid\Software\Policies\Microsoft\Windows\Explorer" 'DisableSearchBoxSuggestions' 1
                }
                Log 'Bing / web rezultati u Start pretrazi iskljuceni.' 'ok'
            }
            'widgets' {
                Set-RegDword $hklm 'SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
                Set-RegDword $hklm 'SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
                Log 'Widgets / Vijesti na taskbaru iskljuceni (vidi se nakon restarta).' 'ok'
            }
            'telemetry' {
                Set-RegDword $hklm 'SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 1
                Set-RegDword $hklm 'SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
                Log 'Telemetrija smanjena na minimum.' 'ok'
            }
        }
    } catch { Log ('Podesavanje "{0}" nije uspjelo: {1}' -f $Key, $_.Exception.Message) 'err' }
    finally { $hklm.Close(); $hku.Close() }
}

function Task-Debloat {
    param($Items, [bool]$Restore)
    $all   = @($Items)
    $store = @($all | Where-Object { $_.Kind -eq 'store' })
    $win   = @($all | Where-Object { $_.Kind -eq 'win32' })
    $tw    = @($all | Where-Object { $_.Kind -eq 'tweak' })
    Log ('Oznaceno: {0} Store aplikacija, {1} programa, {2} podesavanja.' -f $store.Count, $win.Count, $tw.Count) 'info'
    if ($Restore) { Section 'Tacka vracanja'; Task-RestorePoint }
    $removed = New-Object System.Collections.Generic.List[string]
    $failed  = New-Object System.Collections.Generic.List[string]
    if ($store.Count) {
        Section 'Store aplikacije'
        $prov = @()
        try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch {}
        foreach ($s in $store) {
            $ok = $false
            try { Remove-AppxPackage -Package $s.Paket -AllUsers -ErrorAction Stop; $ok = $true }
            catch {
                try { Remove-AppxPackage -Package $s.Paket -ErrorAction Stop; $ok = $true }
                catch { Log ('{0}: {1}' -f $s.Naziv, $_.Exception.Message) 'err'; $failed.Add($s.Naziv) }
            }
            # da se ne vrati za nove korisnike
            foreach ($pp in @($prov | Where-Object { $_.DisplayName -eq $s.Name })) {
                try { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null } catch {}
            }
            if ($ok) { Log ('Uklonjeno: ' + $s.Naziv) 'ok'; $removed.Add($s.Naziv) }
        }
    }
    if ($win.Count) {
        Section 'Predinstalirani programi'
        Log 'Otvorice se prozori za deinstalaciju - prati ih do kraja.' 'dim'
        $wr = @(Invoke-UninstallItems -Items $win -Quiet $false | ForEach-Object { $_.Naziv })
        foreach ($x in $wr) { $removed.Add($x) }
        foreach ($x in $win) { if ($wr -notcontains $x.Naziv) { $failed.Add($x.Naziv + ' (otkazano ili greska)') } }
    }
    if ($tw.Count) {
        Section 'Podesavanja Windowsa'
        foreach ($t in $tw) { Invoke-Tweak $t.Key }
        Add-Done ('Podesavanja privatnosti/reklama: ' + (($tw | ForEach-Object { $_.Naziv }) -join '; ')) 'debloat'
    }
    if ($removed.Count) { Add-Done ('Uklonjen bloatware ({0}): {1}' -f $removed.Count, ($removed -join ', ')) 'debloat' }
    Section 'Rezultat'
    Log ('Uklonjeno: {0}   |   Nije uspjelo: {1}   |   Podesavanja: {2}' -f $removed.Count, $failed.Count, $tw.Count) $(if ($failed.Count) { 'warn' } else { 'ok' })
    $r = "Uklanjanje bloatware-a je zavrseno.`n`n"
    if ($removed.Count) { $r += "UKLONJENO ($($removed.Count)):`n" + ((@($removed | Select-Object -First 25 | ForEach-Object { ' - ' + $_ })) -join "`n") + "`n`n" }
    if ($failed.Count)  { $r += "NIJE USPJELO ($($failed.Count)):`n" + ((@($failed | ForEach-Object { ' - ' + $_ })) -join "`n") + "`n`n" }
    if ($tw.Count)      { $r += "Primijenjeno podesavanja: $($tw.Count) (neka se vide tek nakon odjave/restarta)`n" }
    $sync.ResultMsg = $r.Trim()
}

# =====================================================================
#  v3: SENZORI (osnovni Windows senzori ili LibreHardwareMonitor)
# =====================================================================
function New-SensorRow {
    param([string]$Key, [string]$Hardver, [string]$HwType, [string]$Senzor, [string]$Tip, [double]$Value)
    [pscustomobject]@{ Key = $Key; Hardver = $Hardver; HwType = $HwType; Senzor = $Senzor; Tip = $Tip; Value = $Value }
}

function Open-Lhm {
    $dll = Get-ChildItem -Path (Join-Path $Root 'Alati') -Recurse -Filter 'LibreHardwareMonitorLib.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dll) {
        $src = Get-ChildItem -Path (Join-Path $Root 'Alati') -Recurse -Filter 'LibreHardwareMonitor*.sln' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($src) {
            $sync.SensorNote = 'U folderu Alati je IZVORNI KOD LibreHardwareMonitor-a (Code > Download ZIP), a ne gotov program. Sa stranice Releases preuzmi LibreHardwareMonitor.zip iz dijela Assets.'
            Log $sync.SensorNote 'warn'
        } else {
            $sync.SensorNote = 'Osnovni Windows senzori. Za tacne CPU/GPU temperature i ventilatore ubaci LibreHardwareMonitor u folder Alati (uputa dolje).'
        }
        return $null
    }
    if (Test-Path -LiteralPath (Join-Path $dll.DirectoryName 'LibreHardwareMonitor.runtimeconfig.json')) {
        $sync.SensorNote = 'Ovo je LibreHardwareMonitor za .NET 8/9 - PowerShell treba verziju za .NET Framework 4.7.2 (net472). Preuzmi tu verziju sa stranice Releases.'
        Log $sync.SensorNote 'warn'
        return $null
    }
    try {
        Get-ChildItem -LiteralPath $dll.DirectoryName -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
        # PowerShell nema binding redirecte iz LibreHardwareMonitor.exe.config - prateci DLL-ovi se uzimaju iz istog foldera
        if (-not ('KtAsmResolver' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
public static class KtAsmResolver {
    static string dir;
    public static void Init(string d) {
        if (dir != null) return;
        dir = d;
        AppDomain.CurrentDomain.AssemblyResolve += delegate(object s, ResolveEventArgs e) {
            string n = new AssemblyName(e.Name).Name;
            string p = Path.Combine(dir, n + ".dll");
            return File.Exists(p) ? Assembly.LoadFrom(p) : null;
        };
    }
}
'@
        }
        [KtAsmResolver]::Init($dll.DirectoryName)
        if (-not ('LibreHardwareMonitor.Hardware.Computer' -as [type])) { [void][System.Reflection.Assembly]::LoadFrom($dll.FullName) }
        $c = New-Object LibreHardwareMonitor.Hardware.Computer
        foreach ($p in 'IsCpuEnabled', 'IsGpuEnabled', 'IsMemoryEnabled', 'IsMotherboardEnabled', 'IsStorageEnabled', 'IsControllerEnabled', 'IsBatteryEnabled') {
            try { $c.$p = $true } catch {}
        }
        $c.Open()
        $sync.SensorNote = 'Izvor: LibreHardwareMonitor (' + $dll.Directory.Name + ')'
        Log 'Senzori: LibreHardwareMonitor ucitan.' 'ok'
        return $c
    } catch {
        $sync.SensorNote = 'LibreHardwareMonitor nije moguce pokrenuti (' + $_.Exception.GetBaseException().Message + ') - prikazujem osnovne senzore.'
        Log $sync.SensorNote 'warn'
        return $null
    }
}

function Read-LhmRows {
    param($C)
    foreach ($hw in @($C.Hardware)) {
        try { $hw.Update() } catch {}
        foreach ($sh in @($hw.SubHardware)) { try { $sh.Update() } catch {} }
        foreach ($h in (@($hw) + @($hw.SubHardware))) {
            if (-not $h) { continue }
            foreach ($s in @($h.Sensors)) {
                $t = "$($s.SensorType)"
                if ($t -notin 'Temperature', 'Load', 'Fan', 'Power') { continue }
                if ($null -eq $s.Value) { continue }
                # Critical / Warning / TjMax / Limit su GRANICE upisane u hardver, ne trenutna temperatura
                if ($t -eq 'Temperature' -and "$($s.Name)" -match '(?i)critical|warning|limit|threshold|tjmax|distance|alarm|trip|shutdown') { $t = 'TempLimit' }
                New-SensorRow ([string]$s.Identifier) ([string]$h.Name) ([string]$h.HardwareType) ([string]$s.Name) $t ([double]$s.Value)
            }
        }
    }
}

function Start-SensorLoop {
    $lhm = $null; $tried = $false
    $mm = @{}
    $n = 0
    $nv = $null
    foreach ($p in @("$env:windir\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) { if (Test-Path -LiteralPath $p) { $nv = $p; break } }
    $gpuName = 'Graficka (NVIDIA)'; $gpuT = $null; $gpuL = $null
    $diskRows = @()
    $sync.SensorNote = 'Osnovni Windows senzori.'
    try {
        while (-not $sync.StopSensors) {
            if ($sync.WantLhm -and -not $tried) { $tried = $true; $lhm = Open-Lhm }
            $rows = New-Object System.Collections.Generic.List[object]
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            $ramTot = [double]$os.TotalVisibleMemorySize / 1MB
            $ramUse = $ramTot - ([double]$os.FreePhysicalMemory / 1MB)
            $sum = @{ CpuTemp = $null; CpuLoad = $null; GpuTemp = $null; DiskTemp = $null; RamUsed = $ramUse; RamTot = $ramTot; Source = '' }

            if ($lhm) {
                foreach ($r in @(Read-LhmRows $lhm)) { $rows.Add($r) }
                $cpuT = @($rows | Where-Object { $_.HwType -eq 'Cpu' -and $_.Tip -eq 'Temperature' })
                $pick = $null
                foreach ($nm in 'CPU Package', 'Core (Tctl/Tdie)', 'Tctl/Tdie', 'Tdie', 'Tctl', 'Core Average', 'Core Max') {
                    $pick = $cpuT | Where-Object { $_.Senzor -eq $nm } | Select-Object -First 1
                    if ($pick) { break }
                }
                if (-not $pick -and $cpuT.Count) { $pick = $cpuT | Sort-Object Value -Descending | Select-Object -First 1 }
                if ($pick) { $sum.CpuTemp = $pick.Value }
                $cl = $rows | Where-Object { $_.HwType -eq 'Cpu' -and $_.Tip -eq 'Load' -and $_.Senzor -eq 'CPU Total' } | Select-Object -First 1
                if ($cl) { $sum.CpuLoad = $cl.Value }
                $g = @($rows | Where-Object { $_.HwType -like 'Gpu*' -and $_.Tip -eq 'Temperature' })
                $gc = $g | Where-Object { $_.Senzor -eq 'GPU Core' } | Select-Object -First 1
                if ($gc) { $sum.GpuTemp = $gc.Value } elseif ($g.Count) { $sum.GpuTemp = ($g | Measure-Object Value -Maximum).Maximum }
                $perDisk = foreach ($grp in @($rows | Where-Object { $_.HwType -eq 'Storage' -and $_.Tip -eq 'Temperature' } | Group-Object Hardver)) {
                    $pk = $null
                    foreach ($nm in 'Composite Temperature', 'Temperature', 'Temperature #1') {
                        $pk = $grp.Group | Where-Object { $_.Senzor -eq $nm } | Select-Object -First 1
                        if ($pk) { break }
                    }
                    if (-not $pk) { $pk = $grp.Group | Sort-Object Value | Select-Object -First 1 }
                    $pk.Value
                }
                $perDisk = @($perDisk | Where-Object { $null -ne $_ })
                if ($perDisk.Count) { $sum.DiskTemp = ($perDisk | Measure-Object -Maximum).Maximum }
                $sum.Source = 'LibreHardwareMonitor'
            }

            if ($null -eq $sum.CpuLoad) {
                $ld = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Measure-Object LoadPercentage -Average).Average
                if ($null -ne $ld) {
                    $sum.CpuLoad = [double]$ld
                    if (-not $lhm) { $rows.Add((New-SensorRow 'cpu_load' 'Procesor' 'Cpu' 'Ukupno opterecenje' 'Load' ([double]$ld))) }
                }
            }

            if (-not $lhm) {
                foreach ($z in @(Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction SilentlyContinue)) {
                    $t = $null
                    if ($z.HighPrecisionTemperature) { $t = [double]$z.HighPrecisionTemperature / 10 - 273.15 }
                    elseif ($z.Temperature) { $t = [double]$z.Temperature - 273.15 }
                    if ($null -eq $t -or $t -lt 1 -or $t -gt 125) { continue }
                    $zn = ("$($z.Name)" -replace '^.*\\', '')
                    $rows.Add((New-SensorRow ('acpi_' + $z.Name) 'Termalne zone (ACPI)' 'Motherboard' ('Zona ' + $zn) 'Temperature' $t))
                    if ($t -ge 30 -and ($null -eq $sum.CpuTemp -or $t -gt $sum.CpuTemp)) { $sum.CpuTemp = $t }
                }
                if ($nv -and ($n % 2 -eq 0)) {
                    try {
                        $o = @(& $nv --query-gpu=name,temperature.gpu,utilization.gpu --format=csv,noheader,nounits 2>$null) | Select-Object -First 1
                        if ($o) { $f = "$o" -split ',\s*'; $gpuName = $f[0]; $gpuT = [double]$f[1]; $gpuL = [double]$f[2] }
                    } catch {}
                }
                if ($null -ne $gpuT) {
                    $rows.Add((New-SensorRow 'gpu_t' $gpuName 'GpuNvidia' 'GPU temperatura' 'Temperature' $gpuT))
                    if ($null -ne $gpuL) { $rows.Add((New-SensorRow 'gpu_l' $gpuName 'GpuNvidia' 'GPU opterecenje' 'Load' $gpuL)) }
                    $sum.GpuTemp = $gpuT
                }
                if ($n % 10 -eq 0) {
                    $diskRows = @(foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
                        $rc = $null
                        try { $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
                        if ($rc -and $rc.Temperature) { New-SensorRow ('disk_' + $pd.DeviceId) ([string]$pd.FriendlyName) 'Storage' 'Temperatura diska' 'Temperature' ([double]$rc.Temperature) }
                    })
                }
                foreach ($r in $diskRows) { $rows.Add($r) }
                if ($diskRows.Count) { $sum.DiskTemp = ($diskRows | Measure-Object Value -Maximum).Maximum }
                $rows.Add((New-SensorRow 'ram_used' 'Memorija (RAM)' 'Memory' 'Koristeno' 'Data' $ramUse))
                if ($ramTot -gt 0) { $rows.Add((New-SensorRow 'ram_load' 'Memorija (RAM)' 'Memory' 'Opterecenje' 'Load' ($ramUse / $ramTot * 100))) }
                $sum.Source = 'osnovni senzori'
            }

            $final = foreach ($r in $rows) {
                if (-not $mm.ContainsKey($r.Key)) { $mm[$r.Key] = @($r.Value, $r.Value) }
                else {
                    if ($r.Value -lt $mm[$r.Key][0]) { $mm[$r.Key][0] = $r.Value }
                    if ($r.Value -gt $mm[$r.Key][1]) { $mm[$r.Key][1] = $r.Value }
                }
                $r | Add-Member -NotePropertyName Min -NotePropertyValue $mm[$r.Key][0] -Force -PassThru | Add-Member -NotePropertyName Max -NotePropertyValue $mm[$r.Key][1] -Force -PassThru
            }
            $cur = @{ CPU = $sum.CpuTemp; GPU = $sum.GpuTemp; Disk = $sum.DiskTemp }
            foreach ($k in 'CPU', 'GPU', 'Disk') {
                $v = $cur[$k]
                if ($null -eq $v) { continue }
                if (-not $sync.TempMax.ContainsKey($k) -or $v -gt $sync.TempMax[$k]) { $sync.TempMax[$k] = [math]::Round([double]$v, 1) }
            }
            $sync.SensorRows    = @($final)
            $sync.SensorSummary = $sum
            $n++
            $sync.SensorStamp = $n
            for ($w = 0; $w -lt 6 -and -not $sync.StopSensors; $w++) { Start-Sleep -Milliseconds 250 }
        }
    } finally { if ($lhm) { try { $lhm.Close() } catch {} } }
}

# =====================================================================
#  v3: PDF i izvjestaj
# =====================================================================
function Find-Browser {
    $c = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $c) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

function Convert-HtmlToPdf {
    param([string]$Html, [string]$Pdf)
    $b = Find-Browser
    if (-not $b) { Log 'Edge/Chrome nije pronadjen - PDF nije napravljen.' 'warn'; return $false }
    $prof = Join-Path $env:TEMP ('kt_pdf_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $uri  = ([System.Uri]$Html).AbsoluteUri
    $argList = @('--headless', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
                 "--user-data-dir=`"$prof`"", '--no-pdf-header-footer', '--print-to-pdf-no-header', "--print-to-pdf=`"$Pdf`"", "`"$uri`"")
    try {
        $p = Start-Process -FilePath $b -ArgumentList ($argList -join ' ') -PassThru -WindowStyle Hidden -ErrorAction Stop
        if (-not $p.WaitForExit(90000)) { try { $p.Kill() } catch {} }
    } catch { Log ('PDF greska: ' + $_.Exception.Message) 'warn' }
    for ($i = 0; $i -lt 10 -and -not (Test-Path -LiteralPath $Pdf); $i++) { Start-Sleep -Milliseconds 300 }
    Remove-Item -LiteralPath $prof -Recurse -Force -ErrorAction SilentlyContinue
    return [bool](Test-Path -LiteralPath $Pdf)
}

function Format-Signed {
    param([double]$v, [string]$u = '')
    if ($v -gt 0) { return ('+{0}{1}' -f $v, $u) }
    if ($v -lt 0) { return ('{0}{1}' -f $v, $u) }
    return '0'
}
function Format-SignedSize {
    param([double]$v)
    if ([math]::Abs($v) -lt 1MB) { return '0' }
    $s = Format-Size ([math]::Abs($v))
    if ($v -gt 0) { return "+$s" }
    return "-$s"
}
function New-CmpRow {
    param([string]$Label, $Before, $After, [string]$Delta, [bool]$Good, [bool]$Bad)
    $cls = ''
    if ($Good) { $cls = ' good' } elseif ($Bad) { $cls = ' bad' }
    return ("<tr><td>{0}</td><td class='num'>{1}</td><td class='num'>{2}</td><td class='num{3}'>{4}</td></tr>" -f (HtmlEnc $Label), (HtmlEnc $Before), (HtmlEnc $After), $cls, (HtmlEnc $Delta))
}
function Get-LogoDataUri {
    $f = Get-ChildItem -LiteralPath $Root -File -ErrorAction SilentlyContinue |
         Where-Object { $_.BaseName -eq 'logo' -and $_.Extension -match '^\.(png|jpe?g|svg)$' } | Select-Object -First 1
    if (-not $f) {
        if ($sync.LogoB64) { return ('data:image/png;base64,' + (($sync.LogoB64 -replace '\s', ''))) }
        return ''
    }
    $mime = 'image/jpeg'
    if ($f.Extension -eq '.png') { $mime = 'image/png' } elseif ($f.Extension -eq '.svg') { $mime = 'image/svg+xml' }
    return ('data:{0};base64,{1}' -f $mime, [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f.FullName)))
}

function Task-Report {
    Add-DoneKey 'diag'
    Log 'Prikupljam podatke za izvjestaj...' 'dim'
    $sys   = Get-SystemData
    $disks = @(Get-DiskData)
    $vols  = @(Get-VolumeData)
    $net   = @(Get-NetData)
    $devs  = @(Get-ProblemDevices)
    Log 'Citam Event Log...' 'dim'
    $errs  = @(Get-TopErrors -Days 7 -Top 10)
    $bsod  = @(Get-BugChecks -Days 90 | ForEach-Object { $r = Resolve-BugCheck $_; [pscustomobject]@{ 'Datum' = (Format-Date $_.TimeCreated); 'Kod' = $r.Code; 'Naziv' = $r.Name; 'Savjet' = $r.Hint } })
    $find  = @(Get-Findings -Sys $sys -Disks $disks -Vols $vols -Devices $devs)
    Log 'Citam instalirane programe...' 'dim'
    $progs = @(Get-InstalledPrograms)
    $bat   = Get-BatteryInfo
    if ($bat.Present) { Run-Native 'powercfg.exe' @('/batteryreport', '/output', (Join-Path $ReportDir 'baterija.html')) | Out-Null }

    Section 'Nalazi'
    Show-Findings $find
    $critN = @($find | Where-Object { $_.Nivo -eq 'KRITICNO' }).Count
    $warnN = @($find | Where-Object { $_.Nivo -eq 'UPOZORENJE' }).Count

    $client = [string]$sync.Client
    $note   = [string]$sync.Note
    $phone  = [string]$sync.Phone
    $nalog  = [string]$sync.NalogBroj
    $done = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($sync.Done)) { $done.Add([string]$x) }
    $off = @($sync.StartupOff)
    if ($off.Count) { $done.Add(('Iskljuceno sa pokretanja Windowsa ({0}): {1}' -f $off.Count, ($off -join ', '))) }
    $del = @($sync.StartupDel)
    if ($del.Count) { $done.Add(('Obrisano iz pokretanja Windowsa ({0}): {1}' -f $del.Count, ($del -join ', '))) }
    $txt = New-Object System.Collections.Generic.List[string]

    # ---------- Prije / poslije ----------
    $cmpHtml = ''; $bannerHtml = ''
    $b = $sync.Baseline
    if ($b) {
        Log 'Biljezim zavrsno stanje (prije / poslije)...' 'dim'
        $a = Get-Snapshot -Crit $critN -Warn $warnN
        $rows = New-Object System.Collections.Generic.List[string]
        $wins = New-Object System.Collections.Generic.List[string]
        $fd = [double]$a.FreeC - [double]$b.FreeC
        $rows.Add((New-CmpRow 'Slobodan prostor na disku' (Format-Size $b.FreeC) (Format-Size $a.FreeC) (Format-SignedSize $fd) ($fd -ge 100MB) ($fd -le -100MB)))
        if ($fd -ge 100MB) { $wins.Add(('oslobodjeno {0} prostora na disku' -f (Format-Size $fd))) }
        $ds = [int]$a.StartupOn - [int]$b.StartupOn
        $rows.Add((New-CmpRow 'Programi pri pokretanju Windowsa' $b.StartupOn $a.StartupOn (Format-Signed $ds) ($ds -lt 0) ($ds -gt 0)))
        if ($ds -lt 0) { $wins.Add(('{0} programa manje pri pokretanju' -f (-$ds))) }
        $dp = [int]$a.Programs - [int]$b.Programs
        $rows.Add((New-CmpRow 'Instalirani programi i aplikacije' $b.Programs $a.Programs (Format-Signed $dp) ($dp -lt 0) $false))
        if ($dp -lt 0) { $wins.Add(('uklonjeno {0} nepotrebnih programa' -f (-$dp))) }
        if ($b.BootSec) {
            $after = 'mjeri se nakon restarta'; $delta = ''; $good = $false; $bad = $false
            if ($a.BootSec -and $a.BootAt -and $b.BootAt -and ([datetime]$a.BootAt -gt [datetime]$b.BootAt)) {
                $after = '{0} s' -f $a.BootSec
                $dd = [int]$a.BootSec - [int]$b.BootSec
                $delta = Format-Signed $dd ' s'
                $good = ($dd -le -3); $bad = ($dd -ge 3)
                if ($good) { $wins.Add(('sistem se podize {0} s brze' -f (-$dd))) }
            }
            $rows.Add((New-CmpRow 'Vrijeme podizanja sistema' ('{0} s' -f $b.BootSec) $after $delta $good $bad))
        }
        $dc = ([int]$a.Crit + [int]$a.Warn) - ([int]$b.Crit + [int]$b.Warn)
        $rows.Add((New-CmpRow 'Kriticni problemi / upozorenja' ('{0} / {1}' -f $b.Crit, $b.Warn) ('{0} / {1}' -f $a.Crit, $a.Warn) (Format-Signed $dc) ($dc -lt 0) ($dc -gt 0)))
        $cmpHtml = "<h2>Stanje prije i poslije servisa</h2><table><tr><th>Stavka</th><th class='num'>Prije</th><th class='num'>Poslije</th><th class='num'>Razlika</th></tr>" + ($rows -join '') + '</table>'
        if ($wins.Count) {
            $t = ($wins -join ', ')
            $t = $t.Substring(0, 1).ToUpper() + $t.Substring(1)
            $bannerHtml = "<div class='banner'>Rezultat servisa: " + (HtmlEnc $t) + '.</div>'
            Log ('Rezultat: ' + $t) 'ok'
            $txt.Add('REZULTAT: ' + $t)
        }
    }

    # ---------- Radni nalog ----------
    $woHtml = ''
    $items = @($sync.WorkItems | Where-Object { $_ })
    if ($items.Count) {
        $sb = New-Object System.Text.StringBuilder
        $title = 'Radni nalog'
        if ($nalog) { $title += ' br. ' + $nalog }
        [void]$sb.Append('<h2>' + (HtmlEnc $title) + "</h2><table><tr><th style='width:34px'>#</th><th>Usluga / materijal</th><th class='num'>Kol.</th><th class='num'>Cijena</th><th class='num'>Iznos</th></tr>")
        $txt.Add(''); $txt.Add($title.ToUpper())
        $sub = 0.0; $i = 0
        foreach ($it in $items) {
            $i++
            $q = [double]$it.Kolicina; $c = [double]$it.Cijena; $s = $q * $c; $sub += $s
            [void]$sb.Append(("<tr><td>{0}</td><td>{1}</td><td class='num'>{2:0.##}</td><td class='num'>{3:N2}</td><td class='num'>{4:N2}</td></tr>" -f $i, (HtmlEnc $it.Usluga), $q, $c, $s))
            $txt.Add(('{0,3}. {1,-48} {2,5:0.##} x {3,9:N2} = {4,10:N2}' -f $i, $it.Usluga, $q, $c, $s))
        }
        $disc = 0.0
        try { $disc = [double]$sync.Discount } catch {}
        $tot = $sub * (1 - $disc / 100)
        if ($disc -gt 0) {
            [void]$sb.Append(("<tr><td colspan='4'>Osnovica</td><td class='num'>{0:N2}</td></tr><tr><td colspan='4'>Popust {1:0.##}%</td><td class='num'>-{2:N2}</td></tr>" -f $sub, $disc, ($sub - $tot)))
            $txt.Add(('Osnovica {0:N2}, popust {1:0.##}%' -f $sub, $disc))
        }
        [void]$sb.Append(("<tr class='tot'><td colspan='4'>UKUPNO ZA NAPLATU</td><td class='num'>{0:N2} {1}</td></tr></table>" -f $tot, (HtmlEnc $Valuta)))
        $txt.Add(('UKUPNO: {0:N2} {1}' -f $tot, $Valuta))
        $woHtml = $sb.ToString()
        Log ('Radni nalog: {0} stavki, ukupno {1:N2} {2}' -f $items.Count, $tot, $Valuta) 'info'
    }

    # ---------- Temperature ----------
    $tempHtml = ''
    $tm = $sync.TempMax
    if ($tm -and $tm.Count) {
        $deg = [char]0xB0
        $tr = @(foreach ($k in 'CPU', 'GPU', 'Disk') { if ($tm.ContainsKey($k)) { [pscustomobject]@{ 'Komponenta' = $k; 'Najvisa izmjerena temperatura' = ('{0:N0} {1}C' -f $tm[$k], $deg) } } })
        if ($tr.Count) { $tempHtml = '<h2>Temperature (najvise izmjerene tokom servisa)</h2>' + (ConvertTo-HtmlTable $tr) }
    }

    # ---------- Zaglavlje ----------
    $findRows = ($find | ForEach-Object { "<tr class='$($_.Nivo)'><td style='width:130px'><b>$($_.Nivo)</b></td><td>$(HtmlEnc $_.Opis)</td></tr>" }) -join ''
    if ($done.Count) { $doneHtml = '<ul>' + (($done | ForEach-Object { "<li>$(HtmlEnc $_)</li>" }) -join '') + '</ul>' }
    else { $doneHtml = "<p class='muted'>Samo dijagnostika - bez izmjena na sistemu.</p>" }
    $noteHtml = ''
    if ($note) { $noteHtml = "<p><b>Napomena servisera:</b> $(HtmlEnc $note)</p>" }
    $cparts = @()
    if ($client) { $cparts += "Klijent: <b>$(HtmlEnc $client)</b>" }
    if ($phone)  { $cparts += "tel. $(HtmlEnc $phone)" }
    if ($nalog)  { $cparts += "nalog br. $(HtmlEnc $nalog)" }
    $clientHtml = ''
    if ($cparts.Count) { $clientHtml = "<div class='sub'>" + ($cparts -join ' &middot; ') + '</div>' }
    $logoUri = Get-LogoDataUri
    $logoHtml = ''
    if ($logoUri) { $logoHtml = "<img class='logo' src='$logoUri' alt=''>" }
    $contact = (@($sync.FirmaAdresa, $sync.FirmaTelefon, $sync.FirmaEmail) | Where-Object { $_ } | ForEach-Object { HtmlEnc $_ }) -join ' &middot; '
    $contactHtml = ''
    if ($contact) { $contactHtml = "<span class='contact'>$contact</span>" }

    $css = @"
<style>
*{box-sizing:border-box}
body{font-family:"Segoe UI",Arial,sans-serif;margin:0;background:#f3f5f8;color:#1b2430}
.wrap{max-width:1000px;margin:24px auto;background:#fff;padding:32px 36px;border-radius:12px;box-shadow:0 2px 14px rgba(0,0,0,.07)}
.head{display:flex;justify-content:space-between;align-items:flex-start;border-bottom:3px solid #2f81f7;padding-bottom:16px;margin-bottom:6px}
h1{margin:0;font-size:24px}
.sub{color:#5b6573;margin-top:6px;font-size:14px}
.brand{text-align:right;font-weight:700;color:#2f81f7;font-size:19px}
.brand span{display:block;font-weight:400;color:#5b6573;font-size:13px;margin-top:4px}
.brand span.contact{font-size:12px;margin-top:2px}
.logo{max-height:56px;max-width:200px;display:block;margin:0 0 6px auto}
h2{font-size:14px;margin:28px 0 10px;color:#2f81f7;text-transform:uppercase;letter-spacing:.05em}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{border:1px solid #e1e5eb;padding:6px 9px;text-align:left;vertical-align:top}
th{background:#f1f4f8;font-weight:600}
td.num,th.num{text-align:right;white-space:nowrap}
td.good{color:#15803d;font-weight:700} td.bad{color:#b91c1c;font-weight:700}
tr.tot td{font-weight:700;font-size:15px;background:#f1f4f8}
tr.KRITICNO td{background:#fde4e2} tr.UPOZORENJE td{background:#fff3d6} tr.INFO td{background:#e9f2ff} tr.OK td{background:#e3f6e8}
.banner{background:#e3f6e8;border:1px solid #b7e4c4;color:#14532d;border-radius:10px;padding:14px 18px;margin:20px 0 0;font-size:15px;font-weight:600}
.muted{color:#8a93a0}
ul{margin:6px 0;padding-left:20px} li{margin:3px 0}
.sign{display:flex;justify-content:space-between;gap:60px;margin-top:56px}
.sign div{flex:1;border-top:1px solid #9aa3ad;padding-top:6px;text-align:center;color:#5b6573;font-size:12px}
.pb{break-before:page;page-break-before:always;height:1px}
details{margin-top:26px} summary{cursor:pointer;font-weight:600;color:#2f81f7}
.foot{margin-top:34px;color:#8a93a0;font-size:12px;text-align:center}
@page{size:A4;margin:12mm}
@media print{body{background:#fff}.wrap{box-shadow:none;margin:0;max-width:none;padding:0}details{display:none}}
</style>
"@

    $page = @"
<!DOCTYPE html>
<html lang="bs"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Servisni izvjestaj - $(HtmlEnc $sys.Racunar)</title>
$css
</head><body><div class="wrap">
<div class="head">
  <div><h1>Servisni izvjestaj</h1>
  $clientHtml
  <div class="sub">$(HtmlEnc "$($sys.Proizvodjac) $($sys.Model)") &middot; S/N $(HtmlEnc $sys.'Serijski broj')</div></div>
  <div class="brand">$logoHtml$(HtmlEnc $Firma)$contactHtml<span>$(Get-Date -Format 'dd.MM.yyyy HH:mm')</span></div>
</div>
$bannerHtml
$cmpHtml
<h2>Uradjeni servisni koraci</h2>$doneHtml$noteHtml
$woHtml
<h2>Nalazi</h2><table>$findRows</table>
$tempHtml
<div class="sign"><div>Serviser</div><div>Klijent</div></div>
<div class="pb"></div>
<h2>Tehnicki detalji - sistem</h2>$(ConvertTo-KVTable $sys)
<h2>Diskovi</h2>$(ConvertTo-HtmlTable $disks)
<h2>Particije</h2>$(ConvertTo-HtmlTable $vols)
<h2>Mreza</h2>$(ConvertTo-HtmlTable $net)
<h2>Uredjaji sa problemom</h2>$(ConvertTo-HtmlTable $devs)
<h2>Plavi ekrani (90 dana)</h2>$(ConvertTo-HtmlTable $bsod)
<h2>Najcesce greske u sistemu (7 dana)</h2>$(ConvertTo-HtmlTable $errs)
<details><summary>Instalirani programi ($($progs.Count))</summary>$(ConvertTo-HtmlTable ($progs | Select-Object Naziv, Verzija, Izdavac, Instalirano, Tip))</details>
<div class="foot">Izvjestaj generisan alatom $(HtmlEnc $Firma) Servis Toolkit v$Verzija</div>
</div></body></html>
"@

    $baseName = 'Izvjestaj_{0}_{1}' -f $PC, (Get-Date -Format 'yyyy-MM-dd_HH-mm')
    $htmlPath = Join-Path $ReportDir ($baseName + '.html')
    [System.IO.File]::WriteAllText($htmlPath, $page, (New-Object System.Text.UTF8Encoding($true)))

    $txt.Insert(0, "SERVISNI IZVJESTAJ - $Firma - $(Get-Date -Format 'dd.MM.yyyy HH:mm')")
    if ($client) { $txt.Insert(1, "Klijent: $client  $phone") }
    $txt.Add('')
    $txt.Add(($sys | Format-List | Out-String).Trim())
    $txt.Add('')
    $txt.Add('NALAZI')
    foreach ($x in $find) { $txt.Add(('[{0}] {1}' -f $x.Nivo, $x.Opis)) }
    $txt.Add('')
    $txt.Add('URADJENO')
    foreach ($x in $done) { $txt.Add($x) }
    if ($note) { $txt.Add("Napomena: $note") }
    $txt | Set-Content -Path (Join-Path $ReportDir ($baseName + '.txt')) -Encoding UTF8

    $pdfPath = $null
    if ($sync.GenerisiPDF) {
        Log 'Pravim PDF (preko Edge-a)...' 'dim'
        $pp = Join-Path $ReportDir ($baseName + '.pdf')
        if (Convert-HtmlToPdf $htmlPath $pp) { $pdfPath = $pp; Log "PDF: $pp" 'ok' }
        else { Log 'PDF nije napravljen - otvori HTML i stampaj u PDF (Ctrl+P).' 'warn' }
    }
    if ($sync.SessionDir) {
        try {
            New-Item -ItemType Directory -Path $sync.SessionDir -Force | Out-Null
            Copy-Item -LiteralPath $htmlPath -Destination $sync.SessionDir -Force
            if ($pdfPath) { Copy-Item -LiteralPath $pdfPath -Destination $sync.SessionDir -Force }
        } catch {}
    }
    Log "Izvjestaj: $htmlPath" 'ok'
    if ($pdfPath) { Start-Process $pdfPath } else { Start-Process $htmlPath }
}

# =====================================================================
#  v3.1: DOMENA (Active Directory)
# =====================================================================
function Get-DomainDCs {
    param([string]$Domain)
    if (-not $Domain) { return @() }
    try {
        $srv = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$Domain" -Type SRV -DnsOnly -ErrorAction Stop
        return @($srv | Where-Object { "$($_.Type)" -eq 'SRV' } | Sort-Object Priority, Weight | ForEach-Object { $_.NameTarget } | Select-Object -Unique)
    } catch { return @() }
}

function Measure-DcTime {
    param([string]$Dc, [switch]$Fix)
    $o = (& w32tm.exe /stripchart "/computer:$Dc" /samples:1 /dataonly 2>&1 | Out-String)
    $off = $null
    if ($o -match ',\s*([+-]?\d+[.,]\d+)s') { $off = [double]($Matches[1] -replace ',', '.') }
    if ($null -eq $off) { Log 'Razliku u vremenu sa domain controllerom nije moguce izmjeriti.' 'dim'; return }
    $abs = [math]::Abs($off)
    $lvl = 'ok'
    if ($abs -gt 300) { $lvl = 'err' } elseif ($abs -gt 60) { $lvl = 'warn' }
    Log ('Razlika u vremenu sa {0}: {1:N1} s (dozvoljeno do 300 s)' -f $Dc, $off) $lvl
    if ($Fix -and $abs -gt 120) {
        & net.exe time "\\$Dc" /set /y 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Log 'Sat je uskladjen sa domain controllerom.' 'ok' }
        else { Log 'Sat nije moguce uskladiti automatski - podesi datum i vrijeme rucno.' 'warn' }
    }
}

function Set-DnsForDomain {
    param([string]$Dns)
    $ips = @($Dns -split '[,;\s]+' | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
    if ($ips.Count -eq 0) { Log "DNS adresa '$Dns' nije ispravna IP adresa - preskacem." 'warn'; return }
    $cfg = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and "$($_.NetAdapter.Status)" -eq 'Up' })
    if ($cfg.Count -eq 0) { $cfg = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { "$($_.NetAdapter.Status)" -eq 'Up' }) }
    foreach ($c in $cfg) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $c.InterfaceIndex -ServerAddresses $ips -ErrorAction Stop
            Log ('DNS na adapteru "{0}" postavljen na {1}' -f $c.InterfaceAlias, ($ips -join ', ')) 'ok'
        } catch { Log ('DNS na "{0}" nije postavljen: {1}' -f $c.InterfaceAlias, $_.Exception.Message) 'err' }
    }
    try { Clear-DnsClientCache } catch {}
    Log 'Vracanje na automatski DNS: Mreza > adapter > IPv4 > "Obtain DNS automatically".' 'dim'
    Add-DoneKey 'domain'
}

function Write-DomainErrorHint {
    param([string]$Msg)
    if ($Msg -match '(?i)password|credential|lozink|korisnick|logon failure|access is denied|pristup') { Log 'Savjet: provjeri korisnicko ime i lozinku domenskog admina (format admin@firma.local ili FIRMA\admin).' 'info' }
    if ($Msg -match '(?i)already exists|vec postoji|account already') { Log 'Savjet: racunar sa ovim imenom vec postoji u AD-u, a tvoj nalog ga ne moze preuzeti. Resetuj/obrisi taj racunar u "Active Directory Users and Computers" ili upisi novo ime.' 'info' }
    if ($Msg -match '(?i)could not be contacted|cannot be contacted|ne moze se kontaktirati|not found|nije pronadj|RPC server') { Log 'Savjet: racunar ne vidi domain controller - upisi IP adresu DC-a u polje DNS i provjeri mrezu.' 'info' }
    if ($Msg -match '(?i)time|clock|vrijeme|skew') { Log 'Savjet: uskladi sat racunara sa domain controllerom.' 'info' }
}

function Task-DomainDiag {
    param([string]$Domain)
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    Section 'Status racunara'
    if ($cs.PartOfDomain) { Log ('Racunar {0} je clan domene: {1}' -f $cs.Name, $cs.Domain) 'info' }
    else { Log ('Racunar {0} NIJE u domeni (radna grupa: {1})' -f $cs.Name, $cs.Workgroup) 'warn' }
    if ($cs.DomainRole -ge 4) { Log 'Ovo je domain controller - domenske operacije ovdje nisu namijenjene.' 'warn' }
    if ($os.Caption -match '(?i)home') { Log ('{0} NE MOZE u domenu - potreban je Windows Pro/Enterprise/Education.' -f $os.Caption) 'err' }
    if (-not $Domain -and $cs.PartOfDomain) { $Domain = $cs.Domain }
    if (-not $Domain) { Log 'Nije upisana domena - preskacem provjeru DNS-a i domain controllera.' 'dim'; return }

    Section 'DNS'
    foreach ($c in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { "$($_.NetAdapter.Status)" -eq 'Up' })) {
        $d = @($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses })
        Log ('{0}: IP {1}, DNS {2}' -f $c.InterfaceAlias, (@($c.IPv4Address | ForEach-Object { $_.IPAddress }) -join ', '), ($d -join ', ')) 'out'
    }
    $dcs = @(Get-DomainDCs $Domain)
    if ($dcs.Count) { Log ('Domain controller(i) za {0}: {1}' -f $Domain, ($dcs -join ', ')) 'ok' }
    else {
        Log ('DNS NE PRONALAZI domain controller za "{0}"!' -f $Domain) 'err'
        Log 'Najcesci uzrok: racunar koristi DNS rutera/provajdera umjesto IP adrese domain controllera.' 'warn'
        Log 'Rjesenje: u "Pridruzi" ili "Popravi" upisi IP adresu DC-a u polje DNS.' 'info'
    }

    Section 'Domain controller'
    Run-Native 'nltest.exe' @("/dsgetdc:$Domain") | Out-Null
    $dc = $dcs | Select-Object -First 1
    if ($dc) {
        Test-Step "Ping $dc" { Test-Connection -ComputerName $dc -Count 1 -Quiet }
        foreach ($pp in @(@(53, 'DNS'), @(88, 'Kerberos'), @(389, 'LDAP'), @(445, 'SMB'))) {
            $port = $pp[0]
            Test-Step ('{0} (port {1})' -f $pp[1], $port) { Test-NetConnection -ComputerName $dc -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue }
        }
        Section 'Vrijeme'
        Measure-DcTime -Dc $dc
    }

    if ($cs.PartOfDomain) {
        Section 'Veza sa domenom (secure channel)'
        $ok = $false
        try { $ok = Test-ComputerSecureChannel -ErrorAction Stop } catch { Log $_.Exception.Message 'dim' }
        if ($ok) { Log 'Veza sa domenom je ISPRAVNA.' 'ok' }
        else { Log 'Veza sa domenom je POKVARENA (trust relationship) - koristi "Popravi vezu sa domenom".' 'err' }
    }
    Add-DoneKey 'diag'
}

function Task-DomainRepair {
    param([string]$Server, [System.Management.Automation.PSCredential]$Cred, [string]$Dns)
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.PartOfDomain) { Log 'Racunar nije u domeni - koristi "Pridruzi racunar domeni".' 'err'; return }
    $Domain = $cs.Domain
    Log ('Domena: {0}' -f $Domain) 'info'
    if ($Dns) { Section 'DNS'; Set-DnsForDomain $Dns }
    $dc = $Server
    if (-not $dc) { $dc = @(Get-DomainDCs $Domain) | Select-Object -First 1 }
    if (-not $dc) { Log 'DNS ne pronalazi domain controller - upisi IP DC-a u polje DNS ili naziv DC-a u polje Server.' 'err'; return }
    Section 'Vrijeme'
    Measure-DcTime -Dc $dc -Fix

    Section 'Popravka veze'
    $p = @{ Credential = $Cred; ErrorAction = 'Stop' }
    if ($Server) { $p.Server = $Server }
    $ok = $false
    try { $ok = [bool](Test-ComputerSecureChannel -Repair @p); if ($ok) { Log 'Test-ComputerSecureChannel -Repair: uspjesno.' 'ok' } }
    catch { Log ('Repair: ' + $_.Exception.Message) 'warn'; Write-DomainErrorHint $_.Exception.Message }
    if (-not $ok) {
        Log 'Pokusavam reset lozinke racunara na domeni...' 'dim'
        try { Reset-ComputerMachinePassword @p; Log 'Lozinka racunara resetovana.' 'ok' }
        catch { Log ('Reset: ' + $_.Exception.Message) 'err'; Write-DomainErrorHint $_.Exception.Message }
    }
    $final = $false
    try { $final = Test-ComputerSecureChannel -ErrorAction Stop } catch {}
    Section 'Rezultat'
    if ($final) {
        Log 'Veza sa domenom je POPRAVLJENA. Restart nije potreban - odjavi se i prijavi domenskim nalogom.' 'ok'
        Add-Done ('Popravljena veza racunara sa domenom ' + $Domain) 'domain'
    } else {
        Log 'Veza i dalje ne radi. Sljedeci korak: "Izbaci racunar iz domene", restart, pa "Pridruzi racunar domeni".' 'err'
    }
}

function Task-DomainJoin {
    param([string]$Domain, [System.Management.Automation.PSCredential]$Cred, [string]$OU, [string]$NewName, [string]$Dns)
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.Caption -match '(?i)home') { Log ('{0} ne moze u domenu - potreban je Windows Pro.' -f $os.Caption) 'err'; return }
    if ($cs.PartOfDomain) {
        if ($cs.Domain -ieq $Domain) { Log 'Racunar je vec u ovoj domeni. Ako prijava ne radi, koristi "Popravi vezu sa domenom".' 'warn' }
        else { Log ('Racunar je u drugoj domeni ({0}) - prvo ga izbaci iz nje.' -f $cs.Domain) 'err' }
        return
    }
    if ($Dns) { Section 'DNS'; Set-DnsForDomain $Dns }
    Section 'Provjera'
    $dcs = @(Get-DomainDCs $Domain)
    if ($dcs.Count -eq 0) {
        Log ('DNS ne pronalazi domain controller za "{0}".' -f $Domain) 'err'
        Log 'Upisi IP adresu domain controllera u polje DNS i pokusaj ponovo.' 'info'
        return
    }
    Log ('Domain controller: {0}' -f $dcs[0]) 'ok'
    Measure-DcTime -Dc $dcs[0] -Fix

    Section 'Pridruzivanje'
    $p = @{ DomainName = $Domain; Credential = $Cred; Force = $true; ErrorAction = 'Stop' }
    if ($OU) { $p.OUPath = $OU }
    if ($NewName -and $NewName -ne $env:COMPUTERNAME) { $p.NewName = $NewName; Log ('Racunar ce dobiti novo ime: {0}' -f $NewName) 'info' }
    try {
        Add-Computer @p
        Log ('Racunar je pridruzen domeni {0}.' -f $Domain) 'ok'
        Log 'RESTARTUJ racunar da bi pridruzivanje bilo zavrseno. Domenski korisnici zadrzavaju svoje stare profile.' 'warn'
        Add-Done ('Racunar pridruzen domeni ' + $Domain) 'domain'
        $sync.AskRestart = $true
    } catch {
        Log ('Pridruzivanje nije uspjelo: ' + $_.Exception.Message) 'err'
        Write-DomainErrorHint $_.Exception.Message
    }
}

function Task-DomainLeave {
    param([System.Management.Automation.PSCredential]$Cred)
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.PartOfDomain) { Log 'Racunar nije u domeni.' 'info'; return }
    $Domain = $cs.Domain
    $done = $false
    try {
        Remove-Computer -UnjoinDomainCredential $Cred -WorkgroupName 'WORKGROUP' -Force -ErrorAction Stop
        Log ('Racunar je izbacen iz domene {0} (racun u AD-u je onemogucen).' -f $Domain) 'ok'
        $done = $true
    } catch {
        Log ('Izlazak preko domene nije uspio: ' + $_.Exception.Message) 'warn'
        Log 'Pokusavam lokalni izlazak (bez kontakta sa domenom)...' 'dim'
        try {
            $r = Invoke-CimMethod -InputObject $cs -MethodName UnjoinDomainOrWorkgroup -Arguments @{ FUnjoinOptions = [uint32]0 } -ErrorAction Stop
            if ($r.ReturnValue -eq 0) { Log 'Racunar je lokalno izbacen iz domene (zapis u AD-u ostaje - ponovno pridruzivanje ce ga iskoristiti).' 'ok'; $done = $true }
            else { Log ('Lokalni izlazak nije uspio (kod {0}).' -f $r.ReturnValue) 'err' }
        } catch { Log ('Lokalni izlazak nije uspio: ' + $_.Exception.Message) 'err' }
    }
    if ($done) {
        Log 'RESTARTUJ racunar i prijavi se LOKALNIM admin nalogom, pa pokreni "Pridruzi racunar domeni".' 'warn'
        Add-Done ('Racunar izbacen iz domene ' + $Domain) 'domain'
        $sync.AskRestart = $true
    }
}

# =====================================================================
#  v3.2: AZURIRANJE i PAKET ZA DIJELJENJE
# =====================================================================
function Get-JsonFromUrl {
    param([string]$Url)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $sep = '?'
    if ($Url.Contains('?')) { $sep = '&' }
    $r = Invoke-RestMethod -Uri ($Url + $sep + 'nocache=' + [DateTime]::Now.Ticks) -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    if ($r -is [string]) { $r = $r.Trim([char]0xFEFF) | ConvertFrom-Json }
    return $r
}

function Task-CheckUpdate {
    param([bool]$Silent)
    $url = [string]$sync.UpdateUrl
    if (-not $url) {
        if (-not $Silent) {
            Log 'Adresa za azuriranje nije podesena.' 'warn'
            Log 'Na vrhu servis.ps1 upisi $UpdateUrl (link do verzija.json) - uputa je u UPUTSTVO.txt.' 'info'
        }
        return
    }
    if (-not $Silent) { Log "Provjeravam: $url" 'dim' }
    $j = $null
    try { $j = Get-JsonFromUrl $url }
    catch { if (-not $Silent) { Log ('Provjera nije uspjela: ' + $_.Exception.Message) 'err' }; return }
    $cur = [version]$sync.Verzija
    $new = $null
    try { $new = [version]([string]$j.verzija) } catch {}
    if (-not $new) { if (-not $Silent) { Log 'verzija.json nema ispravno polje "verzija".' 'err' }; return }
    if ($new -gt $cur) {
        Log ('Dostupna je NOVA VERZIJA alata: {0} (ti imas {1}).' -f $new, $cur) 'ok'
        if ($j.novosti) { foreach ($l in (@($j.novosti) -join "`n") -split "`r?`n") { if ($l.Trim()) { Log ('  ' + $l.Trim()) 'info' } } }
        $sync.UpdateInfo = @{ Verzija = [string]$new; Novosti = (@($j.novosti) -join "`n"); Skripta = [string]$j.skripta; Sha256 = [string]$j.sha256; Stranica = [string]$j.stranica }
        $sync.ShowUpdate = $true
    } elseif (-not $Silent) {
        Log ('Imas najnoviju verziju ({0}).' -f $cur) 'ok'
    }
}

function Task-ApplyUpdate {
    $u = $sync.UpdateInfo
    if (-not $u) { return }
    if (-not $u.Skripta) {
        if ($u.Stranica) { Log 'Nova verzija se preuzima rucno - otvaram stranicu.' 'info'; Start-Process $u.Stranica }
        else { Log 'verzija.json nema link do nove skripte (polje "skripta").' 'err' }
        return
    }
    $cur = [string]$sync.ScriptPath
    $new = $cur + '.new'
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
        Log ('Preuzimam verziju {0}...' -f $u.Verzija) 'info'
        Invoke-WebRequest -Uri $u.Skripta -OutFile $new -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    } catch { Log ('Preuzimanje nije uspjelo: ' + $_.Exception.Message) 'err'; return }

    if ($u.Sha256) {
        $h = (Get-FileHash -LiteralPath $new -Algorithm SHA256).Hash
        if ($h -ne $u.Sha256.Trim().ToUpper()) {
            Log 'SHA256 se NE POKLAPA - fajl je ostecen ili podmetnut. Azuriranje prekinuto.' 'err'
            Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue
            return
        }
        Log 'SHA256 provjera: OK' 'ok'
    } else { Log 'verzija.json nema sha256 - preskacem provjeru integriteta (preporuka: dodaj ga).' 'warn' }

    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($new, [ref]$null, [ref]$errs)
    $txt = Get-Content -LiteralPath $new -Raw
    if (@($errs).Count -or $txt -notmatch 'Servis Toolkit' -or $txt -notmatch '\$Verzija') {
        Log 'Preuzeti fajl nije ispravna skripta alata - azuriranje prekinuto.' 'err'
        Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue
        return
    }
    try {
        Copy-Item -LiteralPath $cur -Destination ($cur + '.bak') -Force -ErrorAction Stop
        Move-Item -LiteralPath $new -Destination $cur -Force -ErrorAction Stop
        Log ('Alat azuriran na verziju {0}. Stara verzija je sacuvana kao servis.ps1.bak.' -f $u.Verzija) 'ok'
        $sync.AskRelaunch = $true
    } catch { Log ('Zamjena fajla nije uspjela: ' + $_.Exception.Message) 'err' }
}

function Task-SharePackage {
    $desk = [Environment]::GetFolderPath('Desktop')
    $out  = Join-Path $desk ('Kestrel-Objava_v' + $Verzija)
    $tmp  = Join-Path $env:TEMP ('kt_pkg_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $pkg  = Join-Path $tmp 'Kestrel-Servis'
    New-Item -ItemType Directory -Path $pkg -Force | Out-Null
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $skip = '^(Izvjestaji|Servisi|Backup|Drajveri|Programi|BugReports)$'
    Log 'Kopiram alat BEZ podataka klijenata (izvjestaji, sesije, backup, lozinke, postavke)...' 'dim'
    foreach ($it in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)) {
        if ($it.PSIsContainer) {
            if ($it.Name -match $skip -or $it.Name -like '_*') { Log ('  preskacem folder: ' + $it.Name) 'dim'; continue }
            Copy-Item -LiteralPath $it.FullName -Destination $pkg -Recurse -Force
        } else {
            if ($it.Name -match '(?i)^(postavke\.json|cjenovnik\.csv)$|\.(bak|new|log)$') { Log ('  preskacem fajl: ' + $it.Name) 'dim'; continue }
            Copy-Item -LiteralPath $it.FullName -Destination $pkg -Force
        }
    }
    # izvorni kod LibreHardwareMonitora nije potreban
    Get-ChildItem -LiteralPath (Join-Path $pkg 'Alati') -Directory -Recurse -Filter '*-master' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $zip = Join-Path $out ('Kestrel-Servis_v{0}.zip' -f $Verzija)
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Log 'Pakujem ZIP...' 'dim'
    Compress-Archive -Path $pkg -DestinationPath $zip -CompressionLevel Optimal
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Log ('Paket za testere: {0} ({1})' -f $zip, (Format-Size (Get-Item -LiteralPath $zip).Length)) 'ok'

    # fajlovi za objavu azuriranja
    Copy-Item -LiteralPath $sync.ScriptPath -Destination (Join-Path $out 'servis.ps1') -Force
    $sha = (Get-FileHash -LiteralPath (Join-Path $out 'servis.ps1') -Algorithm SHA256).Hash
    $base = ''
    if ($sync.UpdateUrl) { $base = ([string]$sync.UpdateUrl -replace '/[^/]*$', '') }
    $skr = 'https://TVOJ-LINK/servis.ps1'
    if ($base) { $skr = $base + '/servis.ps1' }
    $json = [ordered]@{
        verzija  = $Verzija
        datum    = (Get-Date -Format 'yyyy-MM-dd')
        novosti  = @('Upisi ovdje sta je novo u ovoj verziji')
        skripta  = $skr
        sha256   = $sha
        stranica = ''
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $out 'verzija.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
    Log ('Za objavu azuriranja: servis.ps1 + verzija.json u {0}' -f $out) 'ok'
    Log 'U verzija.json upisi novosti, pa oba fajla postavi na adresu iz $UpdateUrl.' 'info'
    Start-Process explorer.exe -ArgumentList "`"$out`""
}

function Task-Auto {
    param([string[]]$Steps)
    Log ('Automatski servis - koraci: ' + ($Steps -join ', ')) 'head'
    $order = @(
        @{ K = 'restore'; N = 'Tacka vracanja';     B = { Task-RestorePoint } },
        @{ K = 'cleanup'; N = 'Ciscenje sistema';   B = { Task-Cleanup -Items @('usertemp', 'wintemp', 'wucache', 'wer', 'do') } },
        @{ K = 'repair';  N = 'DISM + SFC';         B = { Task-Repair } },
        @{ K = 'winget';  N = 'Azuriranje programa'; B = { Task-WingetUpgrade } },
        @{ K = 'report';  N = 'Izvjestaj';          B = { Task-Report } }
    )
    $i = 0
    foreach ($s in $order) {
        if ($Steps -notcontains $s.K) { continue }
        $i++
        Log '' 'info'
        Log ('==== KORAK {0}/{1}: {2} ====' -f $i, $Steps.Count, $s.N) 'head'
        try { & $s.B } catch { Log ('Korak nije uspio: ' + $_.Exception.Message) 'err' }
    }
    Log '' 'info'
    Log 'Automatski servis zavrsen. Preporuka: restartuj racunar.' 'ok'
}

}   # kraj WorkerBlock

# Iste funkcije (startup, sesija...) su dostupne i interfejsu
. $WorkerBlock


# =====================================================================
#  GRAFICKI INTERFEJS (WPF)
# =====================================================================
$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Servis Toolkit" Width="1220" Height="790" MinWidth="1020" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#060A12"
        FontFamily="Segoe UI" FontSize="13" Foreground="#E6F4FA" UseLayoutRounding="True">
  <Window.Resources>
    <LinearGradientBrush x:Key="AccentGrad" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#00E5FF" Offset="0"/>
      <GradientStop Color="#7C4DFF" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="CardBorder" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#6600E5FF" Offset="0"/>
      <GradientStop Color="#1400E5FF" Offset="0.45"/>
      <GradientStop Color="#557C4DFF" Offset="1"/>
    </LinearGradientBrush>

    <Style x:Key="ActionBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#BFDCEB"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
              </Border>
              <Border x:Name="bar" Width="3" HorizontalAlignment="Left" CornerRadius="2" Margin="0,7" Background="Transparent"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#0E2236"/>
                <Setter TargetName="bar" Property="Background" Value="#00E5FF"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="#123050"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Padding" Value="14,12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background">
        <Setter.Value>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#00B8D4" Offset="0"/>
            <GradientStop Color="#7C4DFF" Offset="1"/>
          </LinearGradientBrush>
        </Setter.Value>
      </Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <Border.Effect><DropShadowEffect Color="#00E5FF" BlurRadius="18" ShadowDepth="0" Opacity="0.45"/></Border.Effect>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#BFE9F5"/>
      <Setter Property="Background" Value="#0C1828"/>
      <Setter Property="BorderBrush" Value="#1C3550"/>
      <Setter Property="Padding" Value="11,5"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#10243A"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#00E5FF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#04070D"/>
      <Setter Property="Foreground" Value="#E6F4FA"/>
      <Setter Property="BorderBrush" Value="#1C3550"/>
      <Setter Property="CaretBrush" Value="#00E5FF"/>
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#E60A1220"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="15,12"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#4FD1F0"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="CardValue" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#EAF6FF"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="CardSub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6F8BA6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,5,0,0"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.Background>
      <DrawingBrush TileMode="Tile" Viewport="0,0,26,26" ViewportUnits="Absolute">
        <DrawingBrush.Drawing>
          <GeometryDrawing Brush="#060A12">
            <GeometryDrawing.Pen><Pen Brush="#0B1727" Thickness="1"/></GeometryDrawing.Pen>
            <GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,26,26"/></GeometryDrawing.Geometry>
          </GeometryDrawing>
        </DrawingBrush.Drawing>
      </DrawingBrush>
    </Grid.Background>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="285"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- LIJEVI MENI -->
    <Border Grid.Column="0" BorderBrush="#12304A" BorderThickness="0,0,1,0">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#0A1324" Offset="0"/>
          <GradientStop Color="#05080F" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Margin="20,22,20,8">
          <StackPanel Orientation="Horizontal">
            <Viewbox Width="48" Height="48" Margin="0,0,12,0">
              <Canvas Width="100" Height="100">
                <Path Data="M50,3 L91,26.5 L91,73.5 L50,97 L9,73.5 L9,26.5 Z" Fill="#070D19" Stroke="{StaticResource AccentGrad}" StrokeThickness="3.5" StrokeLineJoin="Round">
                  <Path.Effect><DropShadowEffect Color="#00E5FF" BlurRadius="14" ShadowDepth="0" Opacity="0.8"/></Path.Effect>
                </Path>
                <Path Data="M50,10 L85,30 L85,70 L50,90 L15,70 L15,30 Z" Stroke="#2E00E5FF" StrokeThickness="1"/>
                <Canvas>
                  <Canvas.RenderTransform><TranslateTransform X="-4" Y="1"/></Canvas.RenderTransform>
                  <Canvas>
                    <Canvas.Effect><DropShadowEffect Color="#00E5FF" BlurRadius="10" ShadowDepth="0" Opacity="0.7"/></Canvas.Effect>
                    <Path Data="M31,42 L13,36 L27,49 Z M28,52 L11,55 L27,60 Z M29,62 L16,72 L33,67 Z" Fill="{StaticResource AccentGrad}"/>
                    <Path Data="M26,72 L30,42 L40,29 L58,23 L71,27 L77,34 L74,47 L72,52 L66,52 L62,60 L54,70 L44,77 Z">
                      <Path.Fill>
                        <LinearGradientBrush StartPoint="0.2,0" EndPoint="0.8,1">
                          <GradientStop Color="#7CF3FF" Offset="0"/>
                          <GradientStop Color="#00C8EE" Offset="0.45"/>
                          <GradientStop Color="#6A3DF0" Offset="1"/>
                        </LinearGradientBrush>
                      </Path.Fill>
                    </Path>
                    <Path Data="M75,32 L83,34 L88,39 L89.5,46 L86,55 L84.5,48 L81.5,46 L75,47.5 L73,40 Z">
                      <Path.Fill>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                          <GradientStop Color="#FFFFFF" Offset="0"/>
                          <GradientStop Color="#9FEFFF" Offset="1"/>
                        </LinearGradientBrush>
                      </Path.Fill>
                    </Path>
                  </Canvas>
                  <Path Data="M40,29 L48,44 L30,42 M48,44 L44,77 M48,44 L62,60 M58,23 L60,32" Stroke="#7306101E" StrokeThickness="1.3"/>
                  <Path Data="M54,30 L76,31.5 L73,36 L57,35 Z" Fill="#06101E"/>
                  <Path Data="M59,36 L71,36.5 L68,41.5 L61,40.5 Z" Fill="#FFFFFF"/>
                  <Path Data="M64.5,37 L68.5,37.2 L67,40.6 L64.5,40.2 Z" Fill="#06101E"/>
                  <Path Data="M62,41 L66,41.3 L59.5,59 L56,57.5 Z" Fill="#E606101E"/>
                  <Path Data="M75,32 L73,40 L75,47.5 M81.5,46 L84,41" Stroke="#9906101E" StrokeThickness="1.2"/>
                </Canvas>
              </Canvas>
            </Viewbox>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="BrandName" FontSize="17" FontWeight="Black" Foreground="#EAF6FF"/>
              <TextBlock x:Name="BrandSub" Foreground="#4FD1F0" FontFamily="Consolas" FontSize="11"/>
            </StackPanel>
          </StackPanel>
          <Border Height="1" Margin="0,16,0,0" Background="{StaticResource AccentGrad}" Opacity="0.5"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" Margin="14,10,14,16">
          <Button x:Name="AutoBtn" Style="{StaticResource PrimaryBtn}"/>
          <TextBlock x:Name="AdminText" Foreground="#2EE6A6" FontFamily="Consolas" FontSize="11" Margin="3,10,0,0"/>
        </StackPanel>
        <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="8,0,6,0">
          <StackPanel x:Name="NavPanel" Margin="0,0,4,0"/>
        </ScrollViewer>
      </DockPanel>
    </Border>

    <!-- DESNI DIO -->
    <Grid Grid.Column="1" Margin="18,18,18,14">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Style="{StaticResource Card}">
          <StackPanel>
            <Border Height="2" Width="34" CornerRadius="1" HorizontalAlignment="Left" Background="{StaticResource AccentGrad}" Margin="0,0,0,9"/>
            <TextBlock Text="// RACUNAR" Style="{StaticResource CardTitle}"/>
            <TextBlock x:Name="SysVal" Text="Ucitavam..." Style="{StaticResource CardValue}"/>
            <TextBlock x:Name="SysSub" Style="{StaticResource CardSub}"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="1" Style="{StaticResource Card}">
          <StackPanel>
            <Border Height="2" Width="34" CornerRadius="1" HorizontalAlignment="Left" Background="{StaticResource AccentGrad}" Margin="0,0,0,9"/>
            <TextBlock Text="// HARDVER" Style="{StaticResource CardTitle}"/>
            <TextBlock x:Name="HwVal" Text="-" Style="{StaticResource CardValue}"/>
            <TextBlock x:Name="HwSub" Style="{StaticResource CardSub}"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="2" Style="{StaticResource Card}">
          <StackPanel>
            <Border Height="2" Width="34" CornerRadius="1" HorizontalAlignment="Left" Background="{StaticResource AccentGrad}" Margin="0,0,0,9"/>
            <TextBlock x:Name="DiskTitle" Text="SISTEMSKI DISK" Style="{StaticResource CardTitle}"/>
            <TextBlock x:Name="DiskVal" Text="-" Style="{StaticResource CardValue}"/>
            <ProgressBar x:Name="DiskBar" Height="5" Margin="0,8,0,0" Minimum="0" Maximum="100" Value="0" Background="#122236" Foreground="#00E5FF" BorderThickness="0"/>
            <TextBlock x:Name="DiskSub" Style="{StaticResource CardSub}"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="3" Style="{StaticResource Card}" Margin="0">
          <StackPanel>
            <Border Height="2" Width="34" CornerRadius="1" HorizontalAlignment="Left" Background="{StaticResource AccentGrad}" Margin="0,0,0,9"/>
            <TextBlock Text="// STANJE" Style="{StaticResource CardTitle}"/>
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="StateDot" Width="11" Height="11" Fill="#4F6A85" Margin="0,0,8,0" VerticalAlignment="Center">
                <Ellipse.Effect><DropShadowEffect Color="#2EE6A6" BlurRadius="10" ShadowDepth="0" Opacity="0.7"/></Ellipse.Effect>
              </Ellipse>
              <TextBlock x:Name="StateVal" Text="Provjeravam..." Style="{StaticResource CardValue}"/>
            </StackPanel>
            <TextBlock x:Name="StateSub" Style="{StaticResource CardSub}"/>
          </StackPanel>
        </Border>
      </Grid>

      <Border Grid.Row="1" Background="#E60A1220" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="12" Padding="16,10" Margin="0,10,0,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center" Margin="12,0,0,0">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,0,0,6">
              <Ellipse Width="7" Height="7" Fill="#2EE6A6" VerticalAlignment="Center" Margin="0,0,6,0">
                <Ellipse.Effect><DropShadowEffect Color="#2EE6A6" BlurRadius="8" ShadowDepth="0" Opacity="0.9"/></Ellipse.Effect>
                <Ellipse.Triggers>
                  <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                    <BeginStoryboard>
                      <Storyboard>
                        <DoubleAnimation Storyboard.TargetProperty="Opacity" From="1" To="0.2" Duration="0:0:0.9" AutoReverse="True" RepeatBehavior="Forever"/>
                      </Storyboard>
                    </BeginStoryboard>
                  </EventTrigger>
                </Ellipse.Triggers>
              </Ellipse>
              <TextBlock Text="LIVE TELEMETRIJA" FontFamily="Consolas" FontSize="11" FontWeight="Bold" Foreground="#2EE6A6"/>
            </StackPanel>
            <Button x:Name="SensorBtn" Content="SENZORI  &#x203A;" Style="{StaticResource GhostBtn}" Margin="0" HorizontalAlignment="Right"/>
            <TextBlock x:Name="LiveSrc" FontSize="10" Foreground="#4F6A85" HorizontalAlignment="Right" Margin="0,5,0,0"/>
          </StackPanel>
          <UniformGrid Rows="1" Columns="5">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
            <Grid Width="50" Height="50">
              <Ellipse Stroke="#13263C" StrokeThickness="5"/>
              <Path x:Name="GCpuArc" Stroke="#00E5FF" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round">
                <Path.Effect><DropShadowEffect Color="#00E5FF" BlurRadius="12" ShadowDepth="0" Opacity="0.85"/></Path.Effect>
              </Path>
              <TextBlock x:Name="GCpuVal" Text="--" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Consolas" FontWeight="Bold" FontSize="12.5" Foreground="#EAF6FF"/>
            </Grid>
            <StackPanel VerticalAlignment="Center" Margin="9,0,0,0">
              <TextBlock Text="CPU" FontFamily="Consolas" FontSize="11" FontWeight="Bold" Foreground="#4FD1F0"/>
              <TextBlock Text="opterecenje" FontSize="11" Foreground="#5F7D9A"/>
            </StackPanel>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
            <Grid Width="50" Height="50">
              <Ellipse Stroke="#13263C" StrokeThickness="5"/>
              <Path x:Name="GTmpArc" Stroke="#00E5FF" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round">
                <Path.Effect><DropShadowEffect Color="#00E5FF" BlurRadius="12" ShadowDepth="0" Opacity="0.85"/></Path.Effect>
              </Path>
              <TextBlock x:Name="GTmpVal" Text="--" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Consolas" FontWeight="Bold" FontSize="12.5" Foreground="#EAF6FF"/>
            </Grid>
            <StackPanel VerticalAlignment="Center" Margin="9,0,0,0">
              <TextBlock Text="CPU TEMP" FontFamily="Consolas" FontSize="11" FontWeight="Bold" Foreground="#4FD1F0"/>
              <TextBlock Text="procesor" FontSize="11" Foreground="#5F7D9A"/>
            </StackPanel>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
            <Grid Width="50" Height="50">
              <Ellipse Stroke="#13263C" StrokeThickness="5"/>
              <Path x:Name="GRamArc" Stroke="#00E5FF" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round">
                <Path.Effect><DropShadowEffect Color="#00E5FF" BlurRadius="12" ShadowDepth="0" Opacity="0.85"/></Path.Effect>
              </Path>
              <TextBlock x:Name="GRamVal" Text="--" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Consolas" FontWeight="Bold" FontSize="12.5" Foreground="#EAF6FF"/>
            </Grid>
            <StackPanel VerticalAlignment="Center" Margin="9,0,0,0">
              <TextBlock Text="RAM" FontFamily="Consolas" FontSize="11" FontWeight="Bold" Foreground="#4FD1F0"/>
              <TextBlock x:Name="GRamSub" Text="memorija" FontSize="11" Foreground="#5F7D9A"/>
            </StackPanel>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
            <Grid Width="50" Height="50">
              <Ellipse Stroke="#13263C" StrokeThickness="5"/>
              <Path x:Name="GGpuArc" Stroke="#00E5FF" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round">
                <Path.Effect><DropShadowEffect Color="#00E5FF" BlurRadius="12" ShadowDepth="0" Opacity="0.85"/></Path.Effect>
              </Path>
              <TextBlock x:Name="GGpuVal" Text="--" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Consolas" FontWeight="Bold" FontSize="12.5" Foreground="#EAF6FF"/>
            </Grid>
            <StackPanel VerticalAlignment="Center" Margin="9,0,0,0">
              <TextBlock Text="GPU TEMP" FontFamily="Consolas" FontSize="11" FontWeight="Bold" Foreground="#4FD1F0"/>
              <TextBlock Text="grafika" FontSize="11" Foreground="#5F7D9A"/>
            </StackPanel>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
            <Grid Width="50" Height="50">
              <Ellipse Stroke="#13263C" StrokeThickness="5"/>
              <Path x:Name="GDskArc" Stroke="#00E5FF" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round">
                <Path.Effect><DropShadowEffect Color="#00E5FF" BlurRadius="12" ShadowDepth="0" Opacity="0.85"/></Path.Effect>
              </Path>
              <TextBlock x:Name="GDskVal" Text="--" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Consolas" FontWeight="Bold" FontSize="12.5" Foreground="#EAF6FF"/>
            </Grid>
            <StackPanel VerticalAlignment="Center" Margin="9,0,0,0">
              <TextBlock Text="DISK TEMP" FontFamily="Consolas" FontSize="11" FontWeight="Bold" Foreground="#4FD1F0"/>
              <TextBlock Text="SSD / HDD" FontSize="11" Foreground="#5F7D9A"/>
            </StackPanel>
          </StackPanel>
          </UniformGrid>
        </DockPanel>
      </Border>

      <Grid Grid.Row="2" Margin="0,12,0,12">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/><ColumnDefinition Width="230"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="KLIJENT" FontFamily="Consolas" FontSize="11" FontWeight="Bold" VerticalAlignment="Center" Foreground="#4FD1F0" Margin="0,0,10,0"/>
        <TextBox x:Name="ClientBox" Grid.Column="1"/>
        <TextBlock Grid.Column="2" Text="NAPOMENA" FontFamily="Consolas" FontSize="11" FontWeight="Bold" VerticalAlignment="Center" Foreground="#4FD1F0" Margin="16,0,10,0"/>
        <TextBox x:Name="NoteBox" Grid.Column="3"/>
        <Button x:Name="RefreshBtn" Grid.Column="4" Content="Osvjezi stanje" Style="{StaticResource GhostBtn}" Margin="8,0,0,0"/>
      </Grid>

      <Border Grid.Row="3" Background="#F003060B" BorderBrush="#12304A" BorderThickness="1" CornerRadius="12">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border BorderBrush="#12304A" BorderThickness="0,0,0,1" Padding="14,8">
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="CopyBtn" Content="Kopiraj" Style="{StaticResource GhostBtn}"/>
                <Button x:Name="ClearBtn" Content="Ocisti" Style="{StaticResource GhostBtn}"/>
                <Button x:Name="FolderBtn" Content="Folder izvjestaja" Style="{StaticResource GhostBtn}"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse Width="8" Height="8" Fill="#FF4D6D" Margin="0,0,5,0"/>
                <Ellipse Width="8" Height="8" Fill="#FFB020" Margin="0,0,5,0"/>
                <Ellipse Width="8" Height="8" Fill="#2EE6A6" Margin="0,0,12,0"/>
                <TextBlock Text="&gt; TERMINAL" FontFamily="Consolas" FontSize="12" FontWeight="Bold" Foreground="#00E5FF"/>
              </StackPanel>
            </DockPanel>
          </Border>
          <ListBox x:Name="LogList" Grid.Row="1" Background="Transparent" BorderThickness="0" Padding="12,8"
                   FontFamily="Consolas" FontSize="12.5"
                   VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling"
                   ScrollViewer.HorizontalScrollBarVisibility="Auto">
            <ListBox.ItemContainerStyle>
              <Style TargetType="ListBoxItem">
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                      <ContentPresenter Margin="0,1"/>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>
            </ListBox.ItemContainerStyle>
            <ListBox.ItemTemplate>
              <DataTemplate>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="{Binding T}" Foreground="#2B4A66" Margin="0,0,12,0"/>
                  <TextBlock Text="{Binding M}" Foreground="{Binding B}"/>
                </StackPanel>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
        </Grid>
      </Border>

      <Grid Grid.Row="4" Margin="0,12,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Ellipse x:Name="BusyDot" Grid.Column="0" Width="9" Height="9" Fill="#2EE6A6" VerticalAlignment="Center" Margin="2,0,10,0">
          <Ellipse.Effect><DropShadowEffect Color="#00E5FF" BlurRadius="9" ShadowDepth="0" Opacity="0.8"/></Ellipse.Effect>
        </Ellipse>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock x:Name="StatusText" Text="Spreman" FontFamily="Consolas" Foreground="#9FD8EA"/>
          <ProgressBar x:Name="BusyBar" Height="3" IsIndeterminate="True" Margin="0,5,20,0" Visibility="Collapsed" Background="#122236" Foreground="#00E5FF" BorderThickness="0"/>
        </StackPanel>
        <Button x:Name="StopBtn" Grid.Column="2" Content="Prekini" Style="{StaticResource GhostBtn}" IsEnabled="False"/>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

$DialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="540" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" ShowInTaskbar="False"
        Background="#0B1422" Foreground="#E6F4FA" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources><!--COMMON--></Window.Resources>
  <StackPanel Margin="22">
    <TextBlock x:Name="Msg" TextWrapping="Wrap" FontSize="14" Margin="0,0,0,14"/>
    <ListBox x:Name="List" MaxHeight="360" Background="#070B14" Foreground="#E6F4FA" BorderBrush="#1C3550" Padding="4"/>
    <StackPanel x:Name="Checks"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="Cancel" Content="Odustani" MinWidth="100" Style="{StaticResource Btn}" IsCancel="True"/>
      <Button x:Name="Ok" Content="U redu" MinWidth="100" Style="{StaticResource Primary}" IsDefault="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

$ProgramsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Instalirani programi" Width="1180" Height="720" MinWidth="900" MinHeight="480"
        WindowStartupLocation="CenterOwner" Background="#070B14" Foreground="#E6F4FA"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources><!--COMMON--></Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <DockPanel Grid.Row="0" Margin="0,0,0,12">
      <TextBlock DockPanel.Dock="Left" Text="Pretraga" VerticalAlignment="Center" Foreground="#7A9AB8" Margin="0,0,8,0"/>
      <TextBox x:Name="Search" DockPanel.Dock="Left" Width="280"/>
      <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" Margin="22,0,0,0" VerticalAlignment="Center">
        <RadioButton x:Name="RbAll" Content="Svi" GroupName="T" IsChecked="True"/>
        <RadioButton x:Name="RbDesktop" Content="Za sve korisnike" GroupName="T"/>
        <RadioButton x:Name="RbUser" Content="Samo za korisnika" GroupName="T"/>
        <RadioButton x:Name="RbStore" Content="Store aplikacije" GroupName="T"/>
      </StackPanel>
      <TextBlock x:Name="CountText" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#7A9AB8"/>
    </DockPanel>
    <DataGrid x:Name="ProgGrid" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True"
              SelectionMode="Extended" SelectionUnit="FullRow" CanUserAddRows="False" CanUserDeleteRows="False"
              CanUserResizeRows="False" HeadersVisibility="Column" GridLinesVisibility="None"
              Background="#070B14" RowBackground="#070B14" AlternatingRowBackground="#0A111C" Foreground="#E6F4FA"
              BorderBrush="#122236" BorderThickness="1"
              EnableRowVirtualization="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Naziv" Binding="{Binding Naziv}" Width="2.4*"/>
        <DataGridTextColumn Header="Verzija" Binding="{Binding Verzija}" Width="*"/>
        <DataGridTextColumn Header="Izdavac" Binding="{Binding Izdavac}" Width="1.5*"/>
        <DataGridTextColumn Header="Instalirano" Binding="{Binding Instalirano}" Width="100"/>
        <DataGridTextColumn Header="Velicina (MB)" Binding="{Binding VelicinaMB}" Width="105"/>
        <DataGridTextColumn Header="Izvor" Binding="{Binding Tip}" Width="1.3*"/>
      </DataGrid.Columns>
    </DataGrid>
    <DockPanel Grid.Row="2" Margin="0,12,0,0">
      <CheckBox x:Name="QuietBox" DockPanel.Dock="Left" Content="Tiha deinstalacija (bez pitanja, gdje je moguce)"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="WebBtn" Content="Provjeri na webu" Style="{StaticResource Btn}" ToolTip="Google pretraga - korisno za nepoznate/sumnjive programe"/>
        <Button x:Name="LocBtn" Content="Otvori lokaciju" Style="{StaticResource Btn}"/>
        <Button x:Name="CsvBtn" Content="Izvezi CSV" Style="{StaticResource Btn}"/>
        <Button x:Name="RefBtn" Content="Osvjezi" Style="{StaticResource Btn}"/>
        <Button x:Name="UninstBtn" Content="Deinstaliraj" Style="{StaticResource DangerBtn}" ToolTip="Ctrl + klik za vise programa odjednom"/>
      </StackPanel>
    </DockPanel>
  </Grid>
</Window>
'@

# Logo (vjetruska u heksagonu) - ikona prozora i zaglavlje izvjestaja ako nema logo.png
$LogoB64 = @'
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
'@
$script:AppIcon = $null
$sync.LogoB64 = $LogoB64
try {
    $ms = New-Object System.IO.MemoryStream(, [Convert]::FromBase64String($LogoB64))
    $script:AppIcon = [System.Windows.Media.Imaging.BitmapFrame]::Create($ms, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
} catch {}

# Zajednicki stilovi za sporedne prozore (ubacuju se umjesto <!--COMMON-->)
$CommonStyles = @'
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#CFE8F3"/>
      <Setter Property="Background" Value="#122236"/>
      <Setter Property="BorderBrush" Value="#1C3550"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#3A1020"/>
      <Setter Property="BorderBrush" Value="#7A2440"/>
      <Setter Property="Foreground" Value="#FF8FA3"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#0097B2"/>
      <Setter Property="BorderBrush" Value="#00C8E8"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#04070D"/>
      <Setter Property="Foreground" Value="#E6F4FA"/>
      <Setter Property="BorderBrush" Value="#1C3550"/>
      <Setter Property="CaretBrush" Value="#E6F4FA"/>
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#CFE8F3"/>
      <Setter Property="Margin" Value="0,0,16,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#CFE8F3"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#0B1422"/>
      <Setter Property="Foreground" Value="#7A9AB8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="8,7"/>
      <Setter Property="BorderBrush" Value="#16304A"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#0F3A55"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
'@

$StartupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Programi pri pokretanju" Width="1220" Height="700" MinWidth="900" MinHeight="460"
        WindowStartupLocation="CenterOwner" Background="#070B14" Foreground="#E6F4FA"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources><!--COMMON--></Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <DockPanel Grid.Row="0" Margin="0,0,0,12">
      <TextBlock DockPanel.Dock="Left" Text="Pretraga" VerticalAlignment="Center" Foreground="#7A9AB8" Margin="0,0,8,0"/>
      <TextBox x:Name="Search" DockPanel.Dock="Left" Width="260"/>
      <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" Margin="22,0,0,0" VerticalAlignment="Center">
        <RadioButton x:Name="RbAll" Content="Sve" GroupName="S" IsChecked="True"/>
        <RadioButton x:Name="RbOn" Content="Ukljuceno" GroupName="S"/>
        <RadioButton x:Name="RbOff" Content="Iskljuceno" GroupName="S"/>
        <RadioButton x:Name="RbBad" Content="Nema fajla" GroupName="S"/>
      </StackPanel>
      <TextBlock x:Name="CountText" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#7A9AB8"/>
    </DockPanel>
    <DataGrid x:Name="StGrid" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True"
              SelectionMode="Extended" SelectionUnit="FullRow" CanUserAddRows="False" CanUserDeleteRows="False"
              CanUserResizeRows="False" HeadersVisibility="Column" GridLinesVisibility="None"
              Background="#070B14" RowBackground="#070B14" AlternatingRowBackground="#0A111C" Foreground="#E6F4FA"
              BorderBrush="#122236" BorderThickness="1">
      <DataGrid.RowStyle>
        <Style TargetType="DataGridRow">
          <Style.Triggers>
            <DataTrigger Binding="{Binding Status}" Value="Iskljucen"><Setter Property="Foreground" Value="#4F6A85"/></DataTrigger>
            <DataTrigger Binding="{Binding Fajl}" Value="NEMA FAJLA"><Setter Property="Foreground" Value="#FF4D6D"/></DataTrigger>
          </Style.Triggers>
        </Style>
      </DataGrid.RowStyle>
      <DataGrid.Columns>
        <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="90"/>
        <DataGridTextColumn Header="Naziv" Binding="{Binding Naziv}" Width="1.4*"/>
        <DataGridTextColumn Header="Izdavac" Binding="{Binding Izdavac}" Width="1.2*"/>
        <DataGridTextColumn Header="Izvor" Binding="{Binding Izvor}" Width="1.3*"/>
        <DataGridTextColumn Header="Komanda" Binding="{Binding Komanda}" Width="2.4*"/>
        <DataGridTextColumn Header="Fajl" Binding="{Binding Fajl}" Width="95"/>
      </DataGrid.Columns>
    </DataGrid>
    <DockPanel Grid.Row="2" Margin="0,12,0,0">
      <TextBlock DockPanel.Dock="Left" Foreground="#4F6A85" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap" MaxWidth="380"
                 Text="Iskljucivanje radi isto kao u Task Manageru i moze se vratiti. Obrisane stavke idu u backup u folderu izvjestaja."/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="WebBtn" Content="Provjeri na webu" Style="{StaticResource Btn}"/>
        <Button x:Name="LocBtn" Content="Otvori lokaciju" Style="{StaticResource Btn}"/>
        <Button x:Name="RefBtn" Content="Osvjezi" Style="{StaticResource Btn}"/>
        <Button x:Name="DelBtn" Content="Obrisi" Style="{StaticResource DangerBtn}"/>
        <Button x:Name="OnBtn" Content="Ukljuci" Style="{StaticResource Btn}"/>
        <Button x:Name="OffBtn" Content="Iskljuci" Style="{StaticResource Primary}" ToolTip="Ctrl + klik za vise stavki odjednom"/>
      </StackPanel>
    </DockPanel>
  </Grid>
</Window>
'@

$DebloatXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Uklanjanje bloatware-a" Width="680" Height="760" MinHeight="420"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Background="#0B1422" Foreground="#E6F4FA"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources><!--COMMON--></Window.Resources>
  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" TextWrapping="Wrap" Foreground="#CFE8F3"
               Text="Prikazano je samo ono sto je pronadjeno na ovom racunaru. Preporucene stavke su vec oznacene - provjeri sa klijentom ono sto mozda koristi."/>
    <Border Grid.Row="1" Background="#070B14" BorderBrush="#1C3550" BorderThickness="1" CornerRadius="8" Margin="0,12,0,12">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="Items" Margin="14,4,14,12"/>
      </ScrollViewer>
    </Border>
    <CheckBox x:Name="RestoreBox" Grid.Row="2" Content="Prije uklanjanja kreiraj tacku vracanja sistema" IsChecked="True"/>
    <DockPanel Grid.Row="3" Margin="0,16,0,0">
      <StackPanel DockPanel.Dock="Left" Orientation="Horizontal">
        <Button x:Name="RecBtn" Content="Oznaci preporuceno" Style="{StaticResource Btn}" Margin="0"/>
        <Button x:Name="NoneBtn" Content="Ponisti sve" Style="{StaticResource Btn}"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="CancelBtn" Content="Odustani" Style="{StaticResource Btn}" IsCancel="True"/>
        <Button x:Name="OkBtn" Content="Ukloni oznaceno" Style="{StaticResource DangerBtn}"/>
      </StackPanel>
    </DockPanel>
  </Grid>
</Window>
'@

$SensorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Temperature i senzori" Width="960" Height="680" MinWidth="700" MinHeight="400"
        WindowStartupLocation="CenterOwner" Background="#070B14" Foreground="#E6F4FA"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources><!--COMMON--></Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <DockPanel Grid.Row="0" Margin="0,0,0,12">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <TextBlock x:Name="StressText" VerticalAlignment="Center" Foreground="#FFB020" FontWeight="SemiBold" Margin="0,0,6,0"/>
        <Button x:Name="StressBtn" Content="Stres test CPU (5 min)" Style="{StaticResource DangerBtn}"/>
      </StackPanel>
      <TextBlock x:Name="SrcText" VerticalAlignment="Center" Foreground="#7A9AB8" TextWrapping="Wrap"/>
    </DockPanel>
    <DataGrid x:Name="SensGrid" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True"
              SelectionMode="Single" SelectionUnit="FullRow" CanUserAddRows="False" CanUserDeleteRows="False"
              CanUserResizeRows="False" HeadersVisibility="Column" GridLinesVisibility="None"
              Background="#070B14" RowBackground="#070B14" AlternatingRowBackground="#0A111C" Foreground="#E6F4FA"
              BorderBrush="#122236" BorderThickness="1">
      <DataGrid.RowStyle>
        <Style TargetType="DataGridRow">
          <Style.Triggers>
            <DataTrigger Binding="{Binding Nivo}" Value="warn"><Setter Property="Foreground" Value="#FFB020"/></DataTrigger>
            <DataTrigger Binding="{Binding Nivo}" Value="hot"><Setter Property="Foreground" Value="#FF4D6D"/></DataTrigger>
            <DataTrigger Binding="{Binding Nivo}" Value="limit"><Setter Property="Foreground" Value="#4F6A85"/></DataTrigger>
          </Style.Triggers>
        </Style>
      </DataGrid.RowStyle>
      <DataGrid.Columns>
        <DataGridTextColumn Header="Hardver" Binding="{Binding Hardver}" Width="1.5*"/>
        <DataGridTextColumn Header="Senzor" Binding="{Binding Senzor}" Width="1.4*"/>
        <DataGridTextColumn Header="Tip" Binding="{Binding Tip}" Width="110"/>
        <DataGridTextColumn Header="Trenutno" Binding="{Binding Trenutno}" Width="110"/>
        <DataGridTextColumn Header="Min" Binding="{Binding Min}" Width="100"/>
        <DataGridTextColumn Header="Max" Binding="{Binding Max}" Width="100"/>
      </DataGrid.Columns>
    </DataGrid>
    <TextBlock x:Name="HelpText" Grid.Row="2" Margin="0,10,0,0" TextWrapping="Wrap" Foreground="#4F6A85" FontSize="12"
               Text="Za tacne temperature procesora i grafike, ventilatore i potrosnju: preuzmi LibreHardwareMonitor (github.com/LibreHardwareMonitor/LibreHardwareMonitor) i raspakuj ga u folder Alati\LibreHardwareMonitor. Ako i dalje ne vidi CPU temperaturu, pokreni jednom LibreHardwareMonitor.exe i prihvati instalaciju drajvera koji nudi."/>
  </Grid>
</Window>
'@

$WorkOrderXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Radni nalog" Width="1040" Height="700" MinWidth="860" MinHeight="480"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Background="#070B14" Foreground="#E6F4FA"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources><!--COMMON--></Window.Resources>
  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="0,0,0,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="240"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="170"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="Klijent" VerticalAlignment="Center" Foreground="#7A9AB8" Margin="0,0,8,0"/>
      <TextBox x:Name="ClientTb" Grid.Column="1"/>
      <TextBlock Grid.Column="2" Text="Telefon" VerticalAlignment="Center" Foreground="#7A9AB8" Margin="16,0,8,0"/>
      <TextBox x:Name="PhoneTb" Grid.Column="3"/>
      <TextBlock x:Name="NalogText" Grid.Column="5" VerticalAlignment="Center" Foreground="#7A9AB8"/>
    </Grid>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="320"/>
        <ColumnDefinition Width="16"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <DockPanel Grid.Column="0">
        <TextBlock DockPanel.Dock="Top" Text="CJENOVNIK (dupli klik = dodaj)" Foreground="#4FA3C7" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,6"/>
        <StackPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
          <Button x:Name="AddBtn" Content="Dodaj na nalog  &#8594;" Style="{StaticResource Primary}" Margin="0,0,0,6"/>
          <Button x:Name="SuggestBtn" Content="Predlozi iz uradjenih koraka" Style="{StaticResource Btn}" Margin="0,0,0,6"/>
          <Button x:Name="EditPriceBtn" Content="Uredi cjenovnik (Excel)" Style="{StaticResource Btn}" Margin="0,0,0,6"/>
          <Button x:Name="ReloadBtn" Content="Ucitaj cjenovnik ponovo" Style="{StaticResource Btn}" Margin="0"/>
        </StackPanel>
        <ListBox x:Name="PriceList" Background="#04070D" Foreground="#E6F4FA" BorderBrush="#1C3550" Padding="4"/>
      </DockPanel>
      <DockPanel Grid.Column="2">
        <TextBlock DockPanel.Dock="Top" Text="STAVKE NALOGA (dupli klik na polje za izmjenu)" Foreground="#4FA3C7" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,6"/>
        <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
          <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="CustomBtn" Content="+ Nova stavka" Style="{StaticResource Btn}" Margin="0"/>
            <Button x:Name="RemoveBtn" Content="Ukloni stavku" Style="{StaticResource Btn}"/>
            <TextBlock Text="Popust %" Margin="18,0,6,0" VerticalAlignment="Center" Foreground="#7A9AB8"/>
            <TextBox x:Name="DiscountTb" Width="60"/>
          </StackPanel>
          <TextBlock x:Name="TotalText" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="18" FontWeight="Bold" Foreground="#2EE6A6"/>
        </DockPanel>
        <DataGrid x:Name="ItemsGrid" AutoGenerateColumns="False" SelectionMode="Single" SelectionUnit="FullRow"
                  CanUserAddRows="False" CanUserDeleteRows="False" CanUserResizeRows="False" HeadersVisibility="Column"
                  GridLinesVisibility="None" Background="#070B14" RowBackground="#070B14" AlternatingRowBackground="#0A111C"
                  Foreground="#E6F4FA" BorderBrush="#122236" BorderThickness="1">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Usluga / materijal" Binding="{Binding Usluga}" Width="*"/>
            <DataGridTextColumn Header="Kol." Binding="{Binding Kolicina}" Width="70"/>
            <DataGridTextColumn Header="Cijena" Binding="{Binding Cijena, StringFormat=N2}" Width="100"/>
            <DataGridTextColumn Header="Iznos" Binding="{Binding Ukupno, StringFormat=N2}" Width="110" IsReadOnly="True"/>
          </DataGrid.Columns>
        </DataGrid>
      </DockPanel>
    </Grid>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="CancelBtn" Content="Odustani" Style="{StaticResource Btn}" IsCancel="True"/>
      <Button x:Name="SaveBtn" Content="Sacuvaj nalog" Style="{StaticResource Primary}"/>
    </StackPanel>
  </Grid>
</Window>
'@

$DomainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Domena" Width="600" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" Background="#0B1422" Foreground="#E6F4FA" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources><!--COMMON--></Window.Resources>
  <StackPanel Margin="22">
    <TextBlock x:Name="Msg" TextWrapping="Wrap" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,16"/>
    <Grid x:Name="RowDomain" Margin="0,0,0,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <TextBlock Text="Domena (npr. firma.local)" VerticalAlignment="Center" Foreground="#7A9AB8"/>
      <TextBox x:Name="DomainTb" Grid.Column="1"/>
    </Grid>
    <Grid x:Name="RowUser" Margin="0,0,0,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <TextBlock Text="Domenski admin" VerticalAlignment="Center" Foreground="#7A9AB8"/>
      <TextBox x:Name="UserTb" Grid.Column="1" ToolTip="administrator@firma.local ili FIRMA\administrator"/>
    </Grid>
    <Grid x:Name="RowPass" Margin="0,0,0,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <TextBlock Text="Lozinka" VerticalAlignment="Center" Foreground="#7A9AB8"/>
      <PasswordBox x:Name="PassBox" Grid.Column="1" Background="#04070D" Foreground="#E6F4FA" BorderBrush="#1C3550" CaretBrush="#E6F4FA" Padding="6,5"/>
    </Grid>
    <Grid x:Name="RowServer" Margin="0,0,0,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <TextBlock Text="Domain controller (opciono)" VerticalAlignment="Center" Foreground="#7A9AB8"/>
      <TextBox x:Name="ServerTb" Grid.Column="1" ToolTip="Naziv DC-a, npr. dc01.firma.local - prazno = automatski"/>
    </Grid>
    <Grid x:Name="RowOu" Margin="0,0,0,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <TextBlock Text="OU (opciono)" VerticalAlignment="Center" Foreground="#7A9AB8"/>
      <TextBox x:Name="OuTb" Grid.Column="1" ToolTip="npr. OU=Racunari,DC=firma,DC=local - prazno = podrazumijevani folder Computers"/>
    </Grid>
    <Grid x:Name="RowName" Margin="0,0,0,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <TextBlock Text="Novo ime racunara (opciono)" VerticalAlignment="Center" Foreground="#7A9AB8"/>
      <TextBox x:Name="NameTb" Grid.Column="1"/>
    </Grid>
    <Grid x:Name="RowDns" Margin="0,0,0,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <TextBlock Text="DNS = IP DC-a (opciono)" VerticalAlignment="Center" Foreground="#7A9AB8"/>
      <TextBox x:Name="DnsTb" Grid.Column="1" ToolTip="Popuni ako racunar ne vidi domenu (npr. 192.168.1.10) - postavlja DNS na mreznom adapteru"/>
    </Grid>
    <TextBlock x:Name="Hint" TextWrapping="Wrap" Foreground="#7A9AB8" FontSize="12" Margin="0,6,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="CancelBtn" Content="Odustani" Style="{StaticResource Btn}" IsCancel="True"/>
      <Button x:Name="OkBtn" Content="Nastavi" Style="{StaticResource Primary}" IsDefault="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

function New-Window {
    param([string]$Xaml)
    $Xaml = $Xaml.Replace('<!--COMMON-->', $CommonStyles)
    [xml]$x = $Xaml
    $reader = New-Object System.Xml.XmlNodeReader $x
    $w = [Windows.Markup.XamlReader]::Load($reader)
    $w.Add_SourceInitialized({ Set-DarkTitleBar $this })
    if ($script:AppIcon) { try { $w.Icon = $script:AppIcon } catch {} }
    # Prilagodi prozor ekranu (laptopi sa 125-150% skaliranja imaju malo mjesta po visini)
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $maxH = $wa.Height - 12
        $maxW = $wa.Width - 12
        if ($w.MinHeight -gt $maxH) { $w.MinHeight = [math]::Max(300, $maxH - 60) }
        if ($w.MinWidth -gt $maxW) { $w.MinWidth = [math]::Max(500, $maxW - 60) }
        if (-not [double]::IsNaN($w.Height) -and $w.Height -gt $maxH) { $w.Height = $maxH }
        if (-not [double]::IsNaN($w.Width) -and $w.Width -gt $maxW) { $w.Width = $maxW }
        $w.MaxHeight = $wa.Height
    } catch {}
    return $w
}
function Set-DarkTitleBar {
    param($w)
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($w)).Handle
        $v = [int]1;          [void][KT.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)   # tamni rezim
        $v = [int]0x00140B07; [void][KT.Dwm]::DwmSetWindowAttribute($h, 35, [ref]$v, 4)   # boja naslovne trake (Win11)
        $v = [int]0x00D4B800; [void][KT.Dwm]::DwmSetWindowAttribute($h, 34, [ref]$v, 4)   # cyan okvir (Win11)
        $v = [int]0x00F3E8CF; [void][KT.Dwm]::DwmSetWindowAttribute($h, 36, [ref]$v, 4)   # boja teksta (Win11)
    } catch {}
}
function Get-Brush {
    param([string]$Hex)
    $b = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
    $b.Freeze()
    return $b
}
function Format-Size {
    param($Bytes)
    if (-not $Bytes) { return '0 MB' }
    $b = [double]$Bytes
    if ($b -ge 1TB) { return ('{0:N2} TB' -f ($b / 1TB)) }
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    return ('{0:N0} MB' -f ($b / 1MB))
}

$Brushes = @{
    info = Get-Brush '#CFE8F3'
    ok   = Get-Brush '#2EE6A6'
    warn = Get-Brush '#FFB020'
    err  = Get-Brush '#FF4D6D'
    head = Get-Brush '#00E5FF'
    out  = Get-Brush '#7A9AB8'
    cmd  = Get-Brush '#BC8CFF'
    dim  = Get-Brush '#4F6A85'
}
$AccentBrush = Get-Brush '#00E5FF'

try {
    $window = New-Window $MainXaml
} catch {
    Write-Host 'Greska pri ucitavanju interfejsa:' -ForegroundColor Red
    Write-Host $_.Exception.Message
    Read-Host 'ENTER za izlaz' | Out-Null
    exit
}

foreach ($n in 'NavPanel', 'AutoBtn', 'AdminText', 'BrandName', 'BrandSub', 'SysVal', 'SysSub', 'HwVal', 'HwSub',
               'DiskTitle', 'DiskVal', 'DiskBar', 'DiskSub', 'StateDot', 'StateVal', 'StateSub', 'ClientBox', 'NoteBox', 'RefreshBtn',
               'CopyBtn', 'ClearBtn', 'FolderBtn', 'LogList', 'BusyDot', 'StatusText', 'BusyBar', 'StopBtn',
               'SensorBtn', 'LiveSrc', 'GCpuArc', 'GCpuVal', 'GTmpArc', 'GTmpVal', 'GRamArc', 'GRamVal', 'GRamSub', 'GGpuArc', 'GGpuVal', 'GDskArc', 'GDskVal') {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}

$window.Title    = '{0} Servis Toolkit v{1}  -  {2}' -f $Firma, $Verzija, $env:COMPUTERNAME
$BrandName.Text  = $Firma.ToUpper()
$BrandSub.Text   = "Servis Toolkit v$Verzija"
$AdminText.Text  = "Administrator: DA   |   $env:COMPUTERNAME"
$DiskTitle.Text  = "SISTEMSKI DISK ($env:SystemDrive)"

$Lines = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$LogList.ItemsSource = $Lines

try {
    $cs0 = Get-CimInstance Win32_ComputerSystem
    $script:ModelText = '{0} {1}' -f $cs0.Manufacturer, $cs0.Model
} catch { $script:ModelText = $env:COMPUTERNAME }

# ---------------------------------------------------------------------
#  Meni (dugmad)
# ---------------------------------------------------------------------
$Actions = @(
    @{ G = 'DIJAGNOSTIKA'; Id = 'quick';      T = 'Brzi pregled sistema';         I = 0xE946; Tip = 'Hardver, Windows, aktivacija, diskovi, mreza i nalazi. Nista ne mijenja.' },
    @{ G = 'DIJAGNOSTIKA'; Id = 'disk';       T = 'Zdravlje diskova';             I = 0xEDA2; Tip = 'SMART, temperatura, istrosenost SSD-a, greske citanja, slobodan prostor.' },
    @{ G = 'DIJAGNOSTIKA'; Id = 'sensors';    T = 'Temperature i stres test';     I = 0xE9D9; Tip = 'Temperature, opterecenje, ventilatori uzivo + CPU stres test 5 min.' },
    @{ G = 'DIJAGNOSTIKA'; Id = 'crash';      T = 'Plavi ekrani i greske';        I = 0xE7BA; Tip = 'BSOD kodovi sa savjetima, neocekivana gasenja, minidump, Event Log.' },
    @{ G = 'DIJAGNOSTIKA'; Id = 'battery';    T = 'Baterija';                     I = 0xE850; Tip = 'Istrosenost baterije + powercfg izvjestaj.' },
    @{ G = 'DIJAGNOSTIKA'; Id = 'security';   T = 'Sigurnosna provjera';          I = 0xEA18; Tip = 'Antivirus, remote programi, startup, zakazani zadaci, hosts, proxy, admini, Defender scan.' },
    @{ G = 'OPTIMIZACIJA'; Id = 'startup';    T = 'Programi pri pokretanju';      I = 0xE7E8; Tip = 'Ukljuci / iskljuci / obrisi programe koji se pale sa Windowsom (kao Task Manager, ali za sve korisnike).' },
    @{ G = 'OPTIMIZACIJA'; Id = 'debloat';    T = 'Uklanjanje bloatware-a';       I = 0xE894; Tip = 'Candy Crush, TikTok, trial antivirusi, reklame u Windowsu... prikazuje samo ono sto je pronadjeno.' },
    @{ G = 'POPRAVKE';     Id = 'repair';     T = 'Popravka sistema (DISM+SFC)';  I = 0xE90F; Tip = 'Popravka Windows image-a i sistemskih fajlova. 10-40 min.' },
    @{ G = 'POPRAVKE';     Id = 'chkdsk';     T = 'Provjera diska (CHKDSK)';      I = 0xE74E; Tip = 'Online provjera fajl sistema, po zelji zakazana popravka.' },
    @{ G = 'POPRAVKE';     Id = 'wureset';    T = 'Reset Windows Update';         I = 0xE777; Tip = 'Kad se update zaglavi ili javlja greske.' },
    @{ G = 'POPRAVKE';     Id = 'network';    T = 'Mreza';                        I = 0xE968; Tip = 'Dijagnostika, flush DNS, Winsock/TCP-IP reset, Wi-Fi detalji.' },
    @{ G = 'POPRAVKE';     Id = 'domain';     T = 'Domena (Active Directory)';    I = 0xE716; Tip = 'Provjera domene, popravka veze (trust relationship), pridruzivanje i izbacivanje iz domene.' },
    @{ G = 'POPRAVKE';     Id = 'cleanup';    T = 'Ciscenje sistema';             I = 0xE74D; Tip = 'Temp, Windows Update cache, WER, Delivery Optimization, WinSxS.' },
    @{ G = 'BACKUP';       Id = 'drvbackup';  T = 'Backup drajvera';              I = 0xE896; Tip = 'Izvoz svih drajvera u folder Drajveri na USB-u.' },
    @{ G = 'BACKUP';       Id = 'drvrestore'; T = 'Vracanje drajvera';            I = 0xE898; Tip = 'Instalacija drajvera iz backup-a (pnputil).' },
    @{ G = 'BACKUP';       Id = 'userbackup'; T = 'Backup korisnickih podataka';  I = 0xE77B; Tip = 'Desktop, Dokumenti, Slike..., bookmarks, Outlook PST.' },
    @{ G = 'BACKUP';       Id = 'wifi';       T = 'Wi-Fi lozinke i licenca';      I = 0xE701; Tip = 'Izvoz sacuvanih Wi-Fi lozinki i OEM Windows kljuca.' },
    @{ G = 'BACKUP';       Id = 'bitlocker';  T = 'BitLocker';                    I = 0xE72E; Tip = 'Status, recovery kljucevi, pauza za BIOS update.' },
    @{ G = 'BACKUP';       Id = 'restore';    T = 'Tacka vracanja';               I = 0xE81C; Tip = 'Kreira System Restore tacku.' },
    @{ G = 'PROGRAMI';     Id = 'wgupdate';   T = 'Azuriraj sve programe';        I = 0xE895; Tip = 'winget upgrade --all' },
    @{ G = 'PROGRAMI';     Id = 'wgstd';      T = 'Instaliraj standardni paket';  I = 0xE710; Tip = 'Chrome, 7-Zip, VLC... (lista na vrhu skripte).' },
    @{ G = 'PROGRAMI';     Id = 'wgexport';   T = 'Izvezi listu programa';        I = 0xE8C8; Tip = 'Sacuva listu programa sa ovog racunara (za novi racunar).' },
    @{ G = 'PROGRAMI';     Id = 'wgimport';   T = 'Uvezi listu programa';         I = 0xE8E5; Tip = 'Instalira programe iz sacuvane liste.' },
    @{ G = 'PROGRAMI';     Id = 'programs';   T = 'Instalirani programi';         I = 0xE8FD; Tip = 'Svi programi (64/32-bit, svi korisnici, Store) - pretraga, deinstalacija, CSV.' },
    @{ G = 'KLIJENT';      Id = 'workorder';  T = 'Radni nalog';                  I = 0xE8C7; Tip = 'Usluge i cijene iz cjenovnika (u KM), popust, ukupno za naplatu - ulazi u izvjestaj.' },
    @{ G = 'KLIJENT';      Id = 'report';     T = 'Izvjestaj za klijenta (PDF)';  I = 0xE8A5; Tip = 'Prije/poslije, uradjeni koraci, radni nalog, nalazi i tehnicki detalji - HTML + PDF.' },
    @{ G = 'ALATI';        Id = 'tools';      T = 'Pokreni alat sa USB-a';        I = 0xE768; Tip = 'Portable alati iz foldera Alati.' },
    @{ G = 'ALATI';        Id = 'sysapps';    T = 'Windows alati';                I = 0xE713; Tip = 'Device Manager, Disk Management, Event Viewer, servisi...' },
    @{ G = 'O ALATU';      Id = 'update';     T = 'Provjeri azuriranje';          I = 0xE895; Tip = 'Provjerava da li postoji nova verzija alata i instalira je.' },
    @{ G = 'O ALATU';      Id = 'bugreport';  T = 'Prijavi gresku';               I = 0xEBE8; Tip = 'Spakuje opis, verziju, podatke o sistemu i log u ZIP (bez lozinki i podataka klijenta).' },
    @{ G = 'O ALATU';      Id = 'package';    T = 'Paket za testere / objavu';    I = 0xE7B8; Tip = 'Cist ZIP alata bez podataka klijenata + fajlovi za objavu azuriranja (verzija.json).' }
)

$NavButtons = New-Object System.Collections.Generic.List[object]
$lastGroup = ''
foreach ($a in $Actions) {
    if ($a.G -ne $lastGroup) {
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Text = '// ' + $a.G
        $h.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
        $h.Foreground = Get-Brush '#3E8DB5'
        $h.FontSize = 11
        $h.FontWeight = [System.Windows.FontWeights]::SemiBold
        $h.Margin = New-Object System.Windows.Thickness(12, 16, 0, 5)
        [void]$NavPanel.Children.Add($h)
        $lastGroup = $a.G
    }
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $ic = New-Object System.Windows.Controls.TextBlock
    $ic.Text = [string][char]$a.I
    $ic.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets')
    $ic.FontSize = 15
    $ic.Width = 28
    $ic.Foreground = $AccentBrush
    $ic.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $tx = New-Object System.Windows.Controls.TextBlock
    $tx.Text = $a.T
    $tx.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$sp.Children.Add($ic)
    [void]$sp.Children.Add($tx)

    $b = New-Object System.Windows.Controls.Button
    $b.Style = $window.FindResource('ActionBtn')
    $b.Content = $sp
    $b.Tag = $a.Id
    $b.ToolTip = $a.Tip
    $b.Add_Click({ Invoke-Action ([string]$this.Tag) })
    [void]$NavPanel.Children.Add($b)
    $NavButtons.Add($b)
}

$asp = New-Object System.Windows.Controls.StackPanel
$asp.Orientation = [System.Windows.Controls.Orientation]::Horizontal
$aic = New-Object System.Windows.Controls.TextBlock
$aic.Text = [string][char]0xE945
$aic.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets')
$aic.Margin = New-Object System.Windows.Thickness(0, 0, 9, 0)
$aic.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$atx = New-Object System.Windows.Controls.TextBlock
$atx.Text = 'AUTOMATSKI SERVIS'
[void]$asp.Children.Add($aic)
[void]$asp.Children.Add($atx)
$AutoBtn.Content = $asp
$AutoBtn.ToolTip = 'Tacka vracanja + ciscenje + DISM/SFC + update programa + izvjestaj, jednim klikom.'

# ---------------------------------------------------------------------
#  Pozadinski zadaci
# ---------------------------------------------------------------------
$script:Job     = $null
$script:DashJob = $null

function Add-UiLog {
    param([string]$Text, [string]$Level = 'info')
    $sync.Queue.Enqueue([pscustomobject]@{ T = (Get-Date -Format 'HH:mm:ss'); M = $Text; L = $Level })
    try { Add-Content -Path $sync.LogFile -Value ('[{0}] {1,-4} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper(), $Text) -Encoding UTF8 -ErrorAction Stop } catch {}
}

function New-Runner {
    param([string]$Call, [hashtable]$P = @{})
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch {}
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('P', $P)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($WorkerBlock.ToString() + "`r`n" + $Call)
    return [pscustomobject]@{ PS = $ps; RS = $rs; Async = $ps.BeginInvoke(); Start = Get-Date; Title = '' }
}

function Set-Busy {
    param([bool]$Busy, [string]$Title = '')
    foreach ($b in $NavButtons) { $b.IsEnabled = -not $Busy }
    $AutoBtn.IsEnabled = -not $Busy
    $StopBtn.IsEnabled = $Busy
    try {
        if ($Busy) {
            $an = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.15, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(600))))
            $an.AutoReverse = $true
            $an.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $BusyDot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $an)
        } else {
            $BusyDot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $BusyDot.Opacity = 1
        }
    } catch {}
    if ($Busy) {
        $BusyBar.Visibility = 'Visible'
        $BusyDot.Fill = $Brushes.warn
        $StatusText.Text = "U toku: $Title"
    } else {
        $BusyBar.Visibility = 'Collapsed'
        $BusyDot.Fill = $Brushes.ok
        $StatusText.Text = 'Spreman'
    }
}

function Start-Task {
    param([string]$Title, [string]$Call, [hashtable]$P = @{})
    if ($script:Job) { return }
    $sync.Client = $ClientBox.Text.Trim()
    $sync.Note   = $NoteBox.Text.Trim()
    Add-UiLog '' 'info'
    Add-UiLog ('==== {0} ====' -f $Title.ToUpper()) 'head'
    $script:Job = New-Runner $Call $P
    $script:Job.Title = $Title
    Set-Busy $true $Title
}

function Close-Runner {
    param($J, [bool]$Report)
    $failed = $false
    try { [void]$J.PS.EndInvoke($J.Async) }
    catch { $failed = $true; if ($Report) { Add-UiLog ('Greska: ' + $_.Exception.GetBaseException().Message) 'err' } }
    if ($Report) {
        $errs = @($J.PS.Streams.Error)
        foreach ($e in ($errs | Select-Object -First 5)) { Add-UiLog ('(upozorenje) ' + $e.ToString()) 'dim' }
    }
    try { $J.PS.Dispose(); $J.RS.Close(); $J.RS.Dispose() } catch {}
    return (-not $failed)
}

function Update-Dashboard {
    param($d)
    if (-not $d) { return }
    $SysVal.Text = $d.Model
    $SysSub.Text = "S/N: $($d.Serial)`n$($d.Windows)"
    $cpu = ($d.Cpu -replace '\((R|TM)\)', '' -replace '\s+CPU', '' -replace '\s+@.*$', '' -replace '\s{2,}', ' ').Trim()
    $HwVal.Text = $cpu
    $HwSub.Text = "RAM: $($d.Ram)`nGPU: $($d.Gpu)"
    if ($d.DiskTotal -gt 0) {
        $freePct = [math]::Round($d.DiskFree / $d.DiskTotal * 100)
        $DiskVal.Text = '{0} slobodno' -f (Format-Size $d.DiskFree)
        $DiskBar.Value = 100 - $freePct
        $DiskSub.Text = 'od {0} ukupno ({1}% slobodno)' -f (Format-Size $d.DiskTotal), $freePct
        if ($null -ne $d.BaseFree) {
            $delta = $d.DiskFree - $d.BaseFree
            if ($delta -ge 100MB) { $DiskSub.Text += "`n+{0} od pocetka servisa" -f (Format-Size $delta) }
        }
        if ($freePct -lt 10) { $DiskBar.Foreground = $Brushes.err } elseif ($freePct -lt 20) { $DiskBar.Foreground = $Brushes.warn } else { $DiskBar.Foreground = Get-Brush '#00B8D4' }
    }
    if ($d.Crit -gt 0) { $StateDot.Fill = $Brushes.err; $StateVal.Text = ('Kriticno ({0})' -f $d.Crit) }
    elseif ($d.Warn -gt 0) { $StateDot.Fill = $Brushes.warn; $StateVal.Text = ('{0} upozorenja' -f $d.Warn) }
    else { $StateDot.Fill = $Brushes.ok; $StateVal.Text = 'Sve u redu' }
    $StateSub.Text = "Uptime: $($d.Uptime)`n$($d.Act)"
}

function Start-Dashboard {
    if ($script:DashJob) { return }
    $SysVal.Text = 'Ucitavam...'
    $StateVal.Text = 'Provjeravam...'
    $StateDot.Fill = $Brushes.dim
    $script:DashJob = New-Runner 'Task-Dashboard'
}

function Update-UI {
    try {
        $item = $null
        $n = 0
        while ($n -lt 500 -and $sync.Queue.TryDequeue([ref]$item)) {
            $b = $Brushes[$item.L]
            if (-not $b) { $b = $Brushes.info }
            $Lines.Add([pscustomobject]@{ T = $item.T; M = $item.M; B = $b })
            $n++
        }
        if ($n -gt 0) {
            while ($Lines.Count -gt 8000) { $Lines.RemoveAt(0) }
            $LogList.ScrollIntoView($Lines[$Lines.Count - 1])
        }
        if ($sync.DashReady) { $sync.DashReady = $false; Update-Dashboard $sync.Dash }

        if ($script:DashJob -and $script:DashJob.Async.IsCompleted) {
            [void](Close-Runner $script:DashJob $false)
            $script:DashJob = $null
        }
        if ($script:Job -and $script:Job.Async.IsCompleted) {
            $j = $script:Job
            $script:Job = $null
            $ok = Close-Runner $j $true
            $el = (Get-Date) - $j.Start
            Add-UiLog ('Zavrseno: {0}  ({1:mm\:ss})' -f $j.Title, $el) $(if ($ok) { 'ok' } else { 'err' })
            Set-Busy $false
            Save-Session
            if ($sync.OfferLocation) {
                $sync.OfferLocation = $false
                if (Ask "Za jacinu signala, kanal i band Windows 11 trazi ukljucenu lokaciju`n(Postavke > Privatnost > Lokacija > 'Location services' i 'Let desktop apps access your location').`n`nOtvoriti te postavke sada? Nakon ukljucivanja ponovo pokreni Mreza > Detalji Wi-Fi konekcije." 'Wi-Fi') {
                    try { Start-Process 'ms-settings:privacy-location' } catch {}
                }
            }
            if ($sync.AskRelaunch) {
                $sync.AskRelaunch = $false
                if (Ask 'Alat je azuriran. Pokrenuti novu verziju sada?' 'Azuriranje') {
                    Save-Session
                    Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
                    $script:Relaunching = $true
                    $window.Close()
                    return
                }
            }
            if ($sync.ResultMsg) {
                $rm = [string]$sync.ResultMsg
                $sync.ResultMsg = ''
                Show-Info $rm 'Rezultat'
            }
            if ($sync.AskRestart) {
                $sync.AskRestart = $false
                if (Ask "Za zavrsetak je potreban restart racunara.`n`nRestartovati sada? (servis se nastavlja nakon ponovnog pokretanja alata)" 'Restart') {
                    Save-Session
                    Restart-Computer -Force
                }
            }
        }
        if ($sync.ShowPrograms -and -not $script:Job) {
            $sync.ShowPrograms = $false
            try { Show-ProgramsWindow $sync.Programs }
            catch { Add-UiLog ('Prozor sa programima nije moguce otvoriti: ' + $_.Exception.Message) 'err' }
        }
        if ($sync.ShowStartup -and -not $script:Job) {
            $sync.ShowStartup = $false
            try { Show-StartupWindow $sync.StartupItems }
            catch { Add-UiLog ('Prozor za pokretanje nije moguce otvoriti: ' + $_.Exception.Message) 'err' }
        }
        if ($sync.SaveSession) { $sync.SaveSession = $false; Save-Session }
        if ($sync.SensorStamp -ne $script:LastSensorStamp) {
            $script:LastSensorStamp = $sync.SensorStamp
            try { Update-LiveStrip } catch {}
            try { Update-SensorWindow } catch {}
        }
        if ($script:Stress) { try { Update-Stress } catch {} }
        if ($script:UpdJob -and $script:UpdJob.Async.IsCompleted) { [void](Close-Runner $script:UpdJob $false); $script:UpdJob = $null }
        if ($sync.ShowUpdate -and -not $script:Job) {
            $sync.ShowUpdate = $false
            $u = $sync.UpdateInfo
            $msg = "Dostupna je nova verzija alata: $($u.Verzija)  (trenutna: $Verzija)"
            if ($u.Novosti) { $msg += "`n`nNovosti:`n$($u.Novosti)" }
            $msg += "`n`nPreuzeti i instalirati sada?"
            if (Ask $msg 'Azuriranje') { Start-Task 'Azuriranje alata' 'Task-ApplyUpdate' }
        }
        if ($sync.ShowDebloat -and -not $script:Job) {
            $sync.ShowDebloat = $false
            try { Show-DebloatWindow $sync.DebloatFound }
            catch { Add-UiLog ('Debloat prozor nije moguce otvoriti: ' + $_.Exception.Message) 'err' }
        }
    } catch {}
}

# ---------------------------------------------------------------------
#  Dijalozi
# ---------------------------------------------------------------------
function Ask {
    param([string]$Text, [string]$Title = $Firma, $Owner = $window)
    return ("$([System.Windows.MessageBox]::Show($Owner, $Text, $Title, 'YesNo', 'Question'))" -eq 'Yes')
}
function Show-Info {
    param([string]$Text, [string]$Title = $Firma, $Owner = $window)
    [void][System.Windows.MessageBox]::Show($Owner, $Text, $Title, 'OK', 'Information')
}

# ---------------------------------------------------------------------
#  Prozor "Instalirani programi"
# ---------------------------------------------------------------------
$script:PW = $null

function Escape-Like {
    param([string]$s)
    $o = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ('[]*%'.IndexOf($ch) -ge 0) { [void]$o.Append('[' + $ch + ']') }
        elseif ($ch -eq [char]39) { [void]$o.Append("''") }
        else { [void]$o.Append($ch) }
    }
    return $o.ToString()
}

function Update-ProgramFilter {
    $w = $script:PW
    if (-not $w -or -not $w.View) { return }
    $parts = New-Object System.Collections.Generic.List[string]
    $t = $w.Search.Text.Trim()
    if ($t) { $e = Escape-Like $t; $parts.Add("(Naziv LIKE '%$e%' OR Izdavac LIKE '%$e%')") }
    if ($w.RbDesktop.IsChecked)  { $parts.Add("Tip LIKE 'Svi korisnici*'") }
    elseif ($w.RbUser.IsChecked) { $parts.Add("Tip LIKE 'Korisnik:*'") }
    elseif ($w.RbStore.IsChecked) { $parts.Add("Tip = 'Store aplikacija'") }
    try { $w.View.RowFilter = ($parts -join ' AND ') } catch {}
    $w.CountText.Text = '{0} od {1} programa' -f $w.View.Count, $w.Table.Rows.Count
}

function Set-ProgramData {
    param($Items)
    $w = $script:PW
    $dt = New-Object System.Data.DataTable
    $cols = 'Naziv', 'Verzija', 'Izdavac', 'Instalirano', 'Tip', 'Uninstall', 'QuietUninstall', 'Lokacija', 'Paket'
    foreach ($c in $cols) { [void]$dt.Columns.Add($c, [string]) }
    [void]$dt.Columns.Add('VelicinaMB', [double])
    foreach ($i in @($Items)) {
        if (-not $i) { continue }
        $r = $dt.NewRow()
        foreach ($c in $cols) { $r[$c] = [string]$i.$c }
        $mb = 0.0
        try { $mb = [double]$i.VelicinaMB } catch {}
        if ($mb -gt 0) { $r['VelicinaMB'] = $mb } else { $r['VelicinaMB'] = [DBNull]::Value }
        [void]$dt.Rows.Add($r)
    }
    $w.Table = $dt
    $w.View  = $dt.DefaultView
    $w.View.Sort = 'Naziv ASC'
    $w.ProgGrid.ItemsSource = $w.View
    Update-ProgramFilter
}

function Get-SelectedProgramRows {
    if (-not $script:PW) { return @() }
    return @($script:PW.ProgGrid.SelectedItems | ForEach-Object { $_.Row })
}

function Invoke-ProgramUninstall {
    $w = $script:PW
    if (-not $w) { return }
    if ($script:Job) { Show-Info 'Zadatak je vec u toku. Sacekaj da zavrsi.' $Firma $w.Win; return }
    $rows = Get-SelectedProgramRows
    if ($rows.Count -eq 0) { Show-Info 'Izaberi program u listi (Ctrl + klik za vise).' 'Deinstalacija' $w.Win; return }
    $items = @(foreach ($r in $rows) {
        @{ Naziv = [string]$r['Naziv']; Tip = [string]$r['Tip']; Uninstall = [string]$r['Uninstall']; QuietUninstall = [string]$r['QuietUninstall']; Paket = [string]$r['Paket'] }
    })
    $names = (@($items | Select-Object -First 15 | ForEach-Object { ' - {0}   [{1}]' -f $_.Naziv, $_.Tip })) -join "`n"
    if ($items.Count -gt 15) { $names += "`n ... i jos $($items.Count - 15)" }
    $me = [Environment]::UserName
    $extra = ''
    if (@($items | Where-Object { $_.Tip -like 'Korisnik:*' -and $_.Tip -ne "Korisnik: $me" }).Count) {
        $extra = "`n`nNeki programi su instalirani samo za drugog korisnika. Deinstalacija iz ovog naloga mozda nece potpuno raditi - najsigurnije je kad je taj korisnik prijavljen."
    }
    $quiet = [bool]$w.QuietBox.IsChecked
    $mode = 'sa prozorom deinstalacije'
    if ($quiet) { $mode = 'TIHO, bez pitanja' }
    $ans = [System.Windows.MessageBox]::Show($w.Win, "Deinstalirati ($mode):`n`n$names$extra", 'Deinstalacija', 'YesNo', 'Warning')
    if ("$ans" -ne 'Yes') { return }
    Start-Task ('Deinstalacija ({0})' -f $items.Count) 'Task-Uninstall -Items $P.Items -Quiet $P.Quiet' @{ Items = $items; Quiet = $quiet }
}

function Open-ProgramLocation {
    $w = $script:PW
    $r = Get-SelectedProgramRows | Select-Object -First 1
    if (-not $r) { return }
    if ([string]$r['Paket']) { Show-Info 'Store aplikacije su u zasticenom folderu WindowsApps - ne moze se otvoriti.' $Firma $w.Win; return }
    $loc = [string]$r['Lokacija']
    if (-not $loc -or -not (Test-Path -LiteralPath $loc)) {
        $loc = ''
        $u = [string]$r['Uninstall']
        if ($u -match '^\s*"([^"]+)"') { $loc = Split-Path $Matches[1] -Parent }
        elseif ($u -match '^\s*(.+?\.exe)') { $loc = Split-Path $Matches[1] -Parent }
    }
    if ($loc -and $loc -notmatch '(?i)\\Windows\\(System32|SysWOW64)' -and (Test-Path -LiteralPath $loc)) { Start-Process explorer.exe -ArgumentList "`"$loc`"" }
    else { Show-Info 'Lokacija instalacije nije poznata za ovaj program.' $Firma $w.Win }
}

function Search-ProgramWeb {
    $r = Get-SelectedProgramRows | Select-Object -First 1
    if (-not $r) { return }
    $q = [uri]::EscapeDataString(('"{0}" {1}' -f $r['Naziv'], $r['Izdavac']).Trim())
    Start-Process explorer.exe -ArgumentList ('"https://www.google.com/search?q=' + $q + '"')
}

function Export-ProgramList {
    $w = $script:PW
    if (-not $w) { return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'CSV za Excel (*.csv)|*.csv'
    $dlg.FileName = "programi_$($env:COMPUTERNAME).csv"
    if (Test-Path $ReportDir) { $dlg.InitialDirectory = $ReportDir }
    if (-not $dlg.ShowDialog($w.Win)) { return }
    $out = foreach ($v in $w.View) {
        $r = $v.Row
        $mb = ''
        if ($r['VelicinaMB'] -isnot [DBNull]) { $mb = $r['VelicinaMB'] }
        [pscustomobject]@{ Naziv = $r['Naziv']; Verzija = $r['Verzija']; Izdavac = $r['Izdavac']; Instalirano = $r['Instalirano']; 'Velicina MB' = $mb; Izvor = $r['Tip']; Lokacija = $r['Lokacija'] }
    }
    @($out) | Export-Csv -Path $dlg.FileName -NoTypeInformation -UseCulture -Encoding UTF8
    Add-UiLog ('Lista programa izvezena ({0} kom): {1}' -f @($out).Count, $dlg.FileName) 'ok'
}

function Show-ProgramsWindow {
    param($Items)
    if ($script:PW -and $script:PW.Win.IsVisible) {
        Set-ProgramData $Items
        [void]$script:PW.Win.Activate()
        return
    }
    $pw = New-Window $ProgramsXaml
    $pw.Owner = $window
    $pw.Title = 'Instalirani programi  -  ' + $env:COMPUTERNAME
    $script:PW = @{ Win = $pw; Table = $null; View = $null }
    foreach ($n in 'Search', 'RbAll', 'RbDesktop', 'RbUser', 'RbStore', 'CountText', 'ProgGrid', 'QuietBox', 'WebBtn', 'LocBtn', 'CsvBtn', 'RefBtn', 'UninstBtn') {
        $script:PW[$n] = $pw.FindName($n)
    }
    $script:PW.Search.Add_TextChanged({ Update-ProgramFilter })
    foreach ($rb in 'RbAll', 'RbDesktop', 'RbUser', 'RbStore') { $script:PW[$rb].Add_Checked({ Update-ProgramFilter }) }
    $script:PW.UninstBtn.Add_Click({ Invoke-ProgramUninstall })
    $script:PW.RefBtn.Add_Click({ Invoke-Action 'programs' })
    $script:PW.CsvBtn.Add_Click({ Export-ProgramList })
    $script:PW.LocBtn.Add_Click({ Open-ProgramLocation })
    $script:PW.WebBtn.Add_Click({ Search-ProgramWeb })
    $pw.Add_Closed({ $script:PW = $null })
    Set-ProgramData $Items
    $pw.Show()
    [void]$script:PW.Search.Focus()
}

function Show-Choice {
    param([string]$Title, [string]$Message, [object[]]$Options)
    $d = New-Window $DialogXaml
    $d.Owner = $window
    $d.Title = $Title
    $d.FindName('Msg').Text = $Message
    $list = $d.FindName('List')
    foreach ($o in $Options) { [void]$list.Items.Add([string]$o) }
    if ($list.Items.Count) { $list.SelectedIndex = 0 }
    $d.FindName('Checks').Visibility = 'Collapsed'
    $d.FindName('Ok').Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
    $list.Add_MouseDoubleClick({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
    if ($d.ShowDialog()) { return $list.SelectedIndex }
    return -1
}

function Show-Checklist {
    param([string]$Title, [string]$Message, [object[]]$Items)
    $d = New-Window $DialogXaml
    $d.Owner = $window
    $d.Title = $Title
    $d.FindName('Msg').Text = $Message
    $d.FindName('List').Visibility = 'Collapsed'
    $panel = $d.FindName('Checks')
    $boxes = New-Object System.Collections.Generic.List[object]
    foreach ($it in $Items) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $it.T
        $cb.IsChecked = [bool]$it.C
        $cb.Tag = $it.K
        $cb.Foreground = $Brushes.info
        $cb.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)
        [void]$panel.Children.Add($cb)
        $boxes.Add($cb)
    }
    $d.FindName('Ok').Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
    if ($d.ShowDialog()) { return @($boxes | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag }) }
    return $null
}

# ---------------------------------------------------------------------
#  Sesija servisa (nastavak nakon restarta, prije/poslije, radni nalog)
# ---------------------------------------------------------------------
function Save-Session {
    try {
        $o = [ordered]@{
            Verzija    = $Verzija
            Racunar    = $env:COMPUTERNAME
            Started    = [string]$sync.SessionStarted
            Client     = $ClientBox.Text.Trim()
            Note       = $NoteBox.Text.Trim()
            Phone      = [string]$sync.Phone
            NalogBroj  = [string]$sync.NalogBroj
            Discount   = [double]$sync.Discount
            Done       = @($sync.Done)
            DoneKeys   = @($sync.DoneKeys)
            StartupOff = @($sync.StartupOff)
            StartupDel = @($sync.StartupDel)
            WorkItems  = @($sync.WorkItems)
            Baseline   = $sync.Baseline
        }
        New-Item -ItemType Directory -Path $SessionDir -Force -ErrorAction Stop | Out-Null
        [System.IO.File]::WriteAllText($SessionFile, ($o | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

function Import-Session {
    param($o)
    $sync.SessionStarted = [string]$o.Started
    $sync.NalogBroj = [string]$o.NalogBroj
    $sync.Phone = [string]$o.Phone
    $sync.Discount = 0.0
    try { $sync.Discount = [double]$o.Discount } catch {}
    foreach ($x in @($o.Done))       { if ($x) { [void]$sync.Done.Add([string]$x) } }
    foreach ($x in @($o.DoneKeys))   { if ($x -and -not $sync.DoneKeys.Contains([string]$x)) { [void]$sync.DoneKeys.Add([string]$x) } }
    foreach ($x in @($o.StartupOff)) { if ($x) { [void]$sync.StartupOff.Add([string]$x) } }
    foreach ($x in @($o.StartupDel)) { if ($x) { [void]$sync.StartupDel.Add([string]$x) } }
    $sync.WorkItems = @(@($o.WorkItems) | Where-Object { $_ } | ForEach-Object { @{ Usluga = [string]$_.Usluga; Kolicina = [double]$_.Kolicina; Cijena = [double]$_.Cijena } })
    if ($o.Baseline) {
        $b = @{}
        foreach ($p in $o.Baseline.PSObject.Properties) { $b[$p.Name] = $p.Value }
        $sync.Baseline = $b
    }
    if ($o.Client) { $ClientBox.Text = [string]$o.Client }
    if ($o.Note) { $NoteBox.Text = [string]$o.Note }
}

function Initialize-Session {
    $resume = $false
    if (Test-Path -LiteralPath $SessionFile) {
        try {
            $o = Get-Content -LiteralPath $SessionFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $st = [datetime]$o.Started
            if (((Get-Date) - $st).TotalDays -le 30) {
                $cl = ''
                if ($o.Client) { $cl = "Klijent: $($o.Client)`n" }
                $nDone = @($o.Done | Where-Object { $_ }).Count
                $nWo = @($o.WorkItems | Where-Object { $_ }).Count
                $msg = "Pronadjen je zapocet servis ovog racunara.`n`n{0}Zapocet: {1}`nUradjenih koraka: {2}`nStavki na radnom nalogu: {3}`n`nNastaviti taj servis?`n(poredjenje prije/poslije ide od pocetka tog servisa)`n`nNe = pocni novi servis" -f $cl, $st.ToString('dd.MM.yyyy HH:mm'), $nDone, $nWo
                $resume = Ask $msg 'Nastavak servisa'
            }
            if ($resume) {
                Import-Session $o
                Add-UiLog ('Nastavljen servis od {0} ({1} koraka).' -f $st.ToString('dd.MM.yyyy HH:mm'), $sync.Done.Count) 'head'
            } else {
                $arch = Join-Path $SessionDir ('sesija_{0}.json' -f $st.ToString('yyyy-MM-dd_HH-mm'))
                Move-Item -LiteralPath $SessionFile -Destination $arch -Force -ErrorAction SilentlyContinue
            }
        } catch { Add-UiLog ('Prethodna sesija nije ucitana: ' + $_.Exception.Message) 'warn' }
    }
    if (-not $resume) {
        $sync.SessionStarted = (Get-Date).ToString('o')
        $sync.NalogBroj = Get-Date -Format 'yyyyMMdd-HHmm'
        Save-Session
    }
}

# ---------------------------------------------------------------------
#  Cjenovnik i radni nalog
# ---------------------------------------------------------------------
$PriceFile = Join-Path $Root 'cjenovnik.csv'
$DefaultPrices = @'
Usluga;Cijena;Kljuc
Dijagnostika racunara;20;diag
Popravka sistema (greske Windowsa);30;repair,chkdsk,wureset
Ciscenje i optimizacija sistema;30;cleanup
Optimizacija pokretanja Windowsa;15;startup
Uklanjanje nepotrebnih aplikacija (bloatware);15;debloat,uninstall
Antivirusna provjera i uklanjanje malvera;40;security
Backup korisnickih podataka;25;userbackup
Backup / instalacija drajvera;15;drvbackup,drvrestore
Azuriranje programa;10;wgupdate
Instalacija programa;15;wgstd
Popravka mreze i interneta;20;network
Stres test i provjera hladjenja;10;stress
Reinstalacija Windowsa sa drajverima;60;
Ciscenje od prasine i zamjena termalne paste;40;
Domena - pridruzivanje / popravka veze;20;domain
Ugradnja / zamjena dijela (rad);15;
'@

function ConvertTo-Number {
    param($v)
    $s = ("$v" -replace '[^\d,.\-]', '')
    if (-not $s) { return 0.0 }
    if ($s.Contains(',') -and $s.Contains('.')) {
        if ($s.LastIndexOf(',') -gt $s.LastIndexOf('.')) { $s = $s.Replace('.', '').Replace(',', '.') } else { $s = $s.Replace(',', '') }
    } else { $s = $s.Replace(',', '.') }
    $d = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return 0.0
}

function Get-PriceList {
    try {
        if (-not (Test-Path -LiteralPath $PriceFile)) {
            [System.IO.File]::WriteAllText($PriceFile, ($DefaultPrices -replace "`r?`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
        }
        $bytes = [System.IO.File]::ReadAllBytes($PriceFile)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) }
        else {
            try { $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
            catch { $text = [System.Text.Encoding]::Default.GetString($bytes) }
        }
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
        if ($lines.Count -lt 2) { return @() }
        $delim = ';'
        if ($lines[0] -notmatch ';' -and $lines[0] -match ',') { $delim = ',' }
        $out = foreach ($r in ($lines | ConvertFrom-Csv -Delimiter $delim)) {
            $n = "$($r.Usluga)".Trim()
            if (-not $n) { continue }
            [pscustomobject]@{ Usluga = $n; Cijena = (ConvertTo-Number $r.Cijena); Kljuc = "$($r.Kljuc)".Trim() }
        }
        return @($out)
    } catch {
        Add-UiLog ('Cjenovnik nije moguce ucitati: ' + $_.Exception.Message) 'err'
        return @()
    }
}

$script:WO = $null

function Add-WorkRow {
    param([string]$Usluga, [double]$Kol, [double]$Cijena)
    $t = $script:WO.Table
    $r = $t.NewRow()
    $r['Usluga'] = $Usluga
    $r['Kolicina'] = $Kol
    $r['Cijena'] = $Cijena
    [void]$t.Rows.Add($r)
}

function Get-WorkDiscount {
    $d = ConvertTo-Number $script:WO.DiscountTb.Text
    if ($d -lt 0) { return 0.0 }
    if ($d -gt 100) { return 100.0 }
    return $d
}

function Get-WorkSubtotal {
    $sub = 0.0
    foreach ($r in $script:WO.Table.Rows) {
        if ("$($r.RowState)" -eq 'Deleted') { continue }
        $v = $r['Ukupno']
        if ($v -isnot [DBNull]) { $sub += [double]$v }
    }
    return $sub
}

function Update-WorkTotal {
    $w = $script:WO
    if (-not $w -or -not $w.TotalText) { return }
    $sub  = Get-WorkSubtotal
    $disc = Get-WorkDiscount
    $tot  = $sub * (1 - $disc / 100)
    if ($disc -gt 0) { $w.TotalText.Text = ('{0:N2} - {1:0.##}% =  UKUPNO {2:N2} {3}' -f $sub, $disc, $tot, $Valuta) }
    else { $w.TotalText.Text = ('UKUPNO {0:N2} {1}' -f $tot, $Valuta) }
}

function Import-PriceListUI {
    $w = $script:WO
    $w.Prices = @(Get-PriceList)
    $w.PriceList.Items.Clear()
    foreach ($p in $w.Prices) { [void]$w.PriceList.Items.Add(('{0}   -   {1:N2} {2}' -f $p.Usluga, $p.Cijena, $Valuta)) }
}

function Add-SelectedPrice {
    $w = $script:WO
    $i = $w.PriceList.SelectedIndex
    if ($i -lt 0 -or $i -ge @($w.Prices).Count) { return }
    $p = @($w.Prices)[$i]
    Add-WorkRow $p.Usluga 1 $p.Cijena
}

function Add-SuggestedPrices {
    $w = $script:WO
    $keys = @($sync.DoneKeys)
    $added = 0
    foreach ($p in @($w.Prices)) {
        if (-not $p.Kljuc) { continue }
        $ks = @($p.Kljuc -split '[,\s]+' | Where-Object { $_ })
        if (@($ks | Where-Object { $keys -contains $_ }).Count -eq 0) { continue }
        if ($w.Table.Select("Usluga = '" + ($p.Usluga -replace "'", "''") + "'").Count) { continue }
        Add-WorkRow $p.Usluga 1 $p.Cijena
        $added++
    }
    if ($added -eq 0) { Show-Info 'Nema novih stavki za predlog (ili je sve vec na nalogu, ili jos nista nije uradjeno).' 'Radni nalog' $w.Win }
}

function Remove-WorkRow {
    $w = $script:WO
    try { [void]$w.ItemsGrid.CancelEdit() } catch {}
    $sel = $w.ItemsGrid.SelectedItem
    if (-not $sel) { return }
    $sel.Row.Delete()
    $w.Table.AcceptChanges()
    Update-WorkTotal
}

function Save-WorkOrder {
    $w = $script:WO
    try { [void]$w.ItemsGrid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) } catch {}
    $items = @(foreach ($r in $w.Table.Rows) {
        if ("$($r.RowState)" -eq 'Deleted') { continue }
        $u = "$($r['Usluga'])".Trim()
        if (-not $u) { continue }
        $k = $r['Kolicina']; if ($k -is [DBNull]) { $k = 1 }
        $c = $r['Cijena'];   if ($c -is [DBNull]) { $c = 0 }
        @{ Usluga = $u; Kolicina = [double]$k; Cijena = [double]$c }
    })
    $sync.WorkItems = $items
    $sync.Discount  = Get-WorkDiscount
    $sync.Phone     = $w.PhoneTb.Text.Trim()
    $ClientBox.Text = $w.ClientTb.Text.Trim()
    Save-Session
    $tot = (Get-WorkSubtotal) * (1 - $sync.Discount / 100)
    Add-UiLog ('Radni nalog sacuvan: {0} stavki, ukupno {1:N2} {2}. Ulazi u izvjestaj za klijenta.' -f $items.Count, $tot, $Valuta) 'ok'
    $w.Win.DialogResult = $true
}

function Show-WorkOrder {
    $d = New-Window $WorkOrderXaml
    $d.Owner = $window
    try { $d.Language = [System.Windows.Markup.XmlLanguage]::GetLanguage([System.Globalization.CultureInfo]::CurrentCulture.IetfLanguageTag) } catch {}
    $script:WO = @{ Win = $d }
    foreach ($n in 'ClientTb', 'PhoneTb', 'NalogText', 'PriceList', 'AddBtn', 'SuggestBtn', 'EditPriceBtn', 'ReloadBtn', 'ItemsGrid', 'CustomBtn', 'RemoveBtn', 'DiscountTb', 'TotalText', 'SaveBtn') {
        $script:WO[$n] = $d.FindName($n)
    }
    $dt = New-Object System.Data.DataTable
    [void]$dt.Columns.Add('Usluga', [string])
    $ck = $dt.Columns.Add('Kolicina', [double]); $ck.DefaultValue = 1.0
    $cc = $dt.Columns.Add('Cijena', [double]);   $cc.DefaultValue = 0.0
    $cu = $dt.Columns.Add('Ukupno', [double]);   $cu.Expression = 'Kolicina * Cijena'
    $script:WO.Table = $dt
    foreach ($it in @($sync.WorkItems)) { if ($it) { Add-WorkRow ([string]$it.Usluga) ([double]$it.Kolicina) ([double]$it.Cijena) } }
    $script:WO.ItemsGrid.ItemsSource = $dt.DefaultView
    $script:WO.ClientTb.Text = $ClientBox.Text
    $script:WO.PhoneTb.Text = [string]$sync.Phone
    if ([double]$sync.Discount -gt 0) { $script:WO.DiscountTb.Text = [string]$sync.Discount }
    $script:WO.NalogText.Text = 'Nalog br. ' + $sync.NalogBroj
    Import-PriceListUI

    $dt.Add_ColumnChanged({ Update-WorkTotal })
    $dt.Add_RowChanged({ Update-WorkTotal })
    $script:WO.DiscountTb.Add_TextChanged({ Update-WorkTotal })
    $script:WO.AddBtn.Add_Click({ Add-SelectedPrice })
    $script:WO.PriceList.Add_MouseDoubleClick({ Add-SelectedPrice })
    $script:WO.SuggestBtn.Add_Click({ Add-SuggestedPrices })
    $script:WO.EditPriceBtn.Add_Click({
        try { Start-Process -FilePath $PriceFile }
        catch { Show-Info ("Ne mogu otvoriti cjenovnik:`n$PriceFile") $Firma $script:WO.Win }
    })
    $script:WO.ReloadBtn.Add_Click({ Import-PriceListUI })
    $script:WO.CustomBtn.Add_Click({
        Add-WorkRow 'Nova stavka' 1 0
        try {
            $g = $script:WO.ItemsGrid
            $g.SelectedIndex = $g.Items.Count - 1
            $g.ScrollIntoView($g.SelectedItem)
            $g.CurrentCell = New-Object System.Windows.Controls.DataGridCellInfo($g.SelectedItem, $g.Columns[0])
            [void]$g.BeginEdit()
        } catch {}
    })
    $script:WO.RemoveBtn.Add_Click({ Remove-WorkRow })
    $script:WO.SaveBtn.Add_Click({ Save-WorkOrder })
    Update-WorkTotal
    [void]$d.ShowDialog()
    $script:WO = $null
}

# ---------------------------------------------------------------------
#  Programi pri pokretanju - prozor
# ---------------------------------------------------------------------
$script:SW = $null
$StartupCols = 'Status', 'Naziv', 'Izdavac', 'Izvor', 'Komanda', 'Fajl', 'Kind', 'Hive', 'Prefix', 'RunPath', 'ApprovedSub', 'ValueName', 'FilePath', 'TaskPath', 'TaskName', 'Exe'

function Update-StartupFilter {
    $w = $script:SW
    if (-not $w -or -not $w.View) { return }
    $parts = New-Object System.Collections.Generic.List[string]
    $t = $w.Search.Text.Trim()
    if ($t) { $e = Escape-Like $t; $parts.Add("(Naziv LIKE '%$e%' OR Izdavac LIKE '%$e%' OR Komanda LIKE '%$e%')") }
    if ($w.RbOn.IsChecked)      { $parts.Add("Status = 'Ukljucen'") }
    elseif ($w.RbOff.IsChecked) { $parts.Add("Status = 'Iskljucen'") }
    elseif ($w.RbBad.IsChecked) { $parts.Add("Fajl = 'NEMA FAJLA'") }
    try { $w.View.RowFilter = ($parts -join ' AND ') } catch {}
    $on = $w.Table.Select("Status = 'Ukljucen'").Count
    $w.CountText.Text = 'Prikazano {0}   |   ukljuceno {1} od {2}' -f $w.View.Count, $on, $w.Table.Rows.Count
}

function Set-StartupData {
    param($Items)
    $w = $script:SW
    $dt = New-Object System.Data.DataTable
    foreach ($c in $StartupCols) { [void]$dt.Columns.Add($c, [string]) }
    foreach ($i in @($Items)) {
        if (-not $i) { continue }
        $r = $dt.NewRow()
        foreach ($c in $StartupCols) { $r[$c] = [string]$i.$c }
        [void]$dt.Rows.Add($r)
    }
    $w.Table = $dt
    $w.View  = $dt.DefaultView
    $w.View.Sort = 'Status DESC, Naziv ASC'
    $w.StGrid.ItemsSource = $w.View
    Update-StartupFilter
}

function Get-SelectedStartupRows {
    if (-not $script:SW) { return @() }
    return @($script:SW.StGrid.SelectedItems | ForEach-Object { $_.Row })
}

function ConvertFrom-StartupRow {
    param($r)
    $o = [ordered]@{}
    foreach ($c in $StartupCols) { $o[$c] = [string]$r[$c] }
    return [pscustomobject]$o
}

function Invoke-StartupChange {
    param([string]$Mode)
    $w = $script:SW
    if (-not $w) { return }
    $rows = @(Get-SelectedStartupRows)
    if ($rows.Count -eq 0) { Show-Info 'Izaberi stavku u listi (Ctrl + klik za vise).' 'Pokretanje' $w.Win; return }
    if ($Mode -eq 'del') {
        $names = (@($rows | Select-Object -First 15 | ForEach-Object { ' - ' + $_['Naziv'] })) -join "`n"
        $ans = [System.Windows.MessageBox]::Show($w.Win, "Obrisati iz pokretanja Windowsa?`n`n$names`n`nProgram ostaje instaliran - samo se vise nece sam pokretati.`nBackup ide u folder izvjestaja (Startup_backup).", 'Brisanje', 'YesNo', 'Warning')
        if ("$ans" -ne 'Yes') { return }
    }
    $bk = Join-Path $ReportDir 'Startup_backup'
    $changed = 0
    foreach ($r in $rows) {
        $it = ConvertFrom-StartupRow $r
        try {
            if ($Mode -eq 'on') {
                Set-StartupItemState $it $true
                $r['Status'] = 'Ukljucen'
                $sync.StartupOff.Remove($it.Naziv)
                Add-UiLog ('Ukljuceno pri pokretanju: ' + $it.Naziv) 'ok'
            } elseif ($Mode -eq 'off') {
                Set-StartupItemState $it $false
                $r['Status'] = 'Iskljucen'
                if (-not $sync.StartupOff.Contains($it.Naziv)) { [void]$sync.StartupOff.Add($it.Naziv) }
                Add-UiLog ('Iskljuceno pri pokretanju: ' + $it.Naziv) 'ok'
            } else {
                Remove-StartupItem $it $bk
                $sync.StartupOff.Remove($it.Naziv)
                if (-not $sync.StartupDel.Contains($it.Naziv)) { [void]$sync.StartupDel.Add($it.Naziv) }
                $r.Delete()
                Add-UiLog ('Obrisano iz pokretanja: ' + $it.Naziv) 'ok'
            }
            $changed++
        } catch { Add-UiLog ('{0}: {1}' -f $it.Naziv, $_.Exception.Message) 'err' }
    }
    if ($Mode -eq 'del') { $w.Table.AcceptChanges() }
    if ($changed) { Add-DoneKey 'startup'; Save-Session }
    Update-StartupFilter
}

function Open-StartupLocation {
    $r = Get-SelectedStartupRows | Select-Object -First 1
    if (-not $r) { return }
    $p = [string]$r['Exe']
    if ([string]$r['Kind'] -eq 'folder') { $p = [string]$r['FilePath'] }
    $ok = $false
    try { $ok = ($p -and (Test-Path -LiteralPath $p)) } catch {}
    if ($ok) { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $p) }
    elseif ([string]$r['Kind'] -eq 'task') { Start-Process 'taskschd.msc' }
    else { Show-Info 'Fajl ne postoji - stavka je ostatak obrisanog programa i moze se obrisati.' $Firma $script:SW.Win }
}

function Search-StartupWeb {
    $r = Get-SelectedStartupRows | Select-Object -First 1
    if (-not $r) { return }
    $exe = ''
    if ([string]$r['Exe']) { $exe = Split-Path ([string]$r['Exe']) -Leaf }
    $q = [uri]::EscapeDataString(('{0} {1} startup' -f $r['Naziv'], $exe).Trim())
    Start-Process explorer.exe -ArgumentList ('"https://www.google.com/search?q=' + $q + '"')
}

function Show-StartupWindow {
    param($Items)
    if ($script:SW -and $script:SW.Win.IsVisible) {
        Set-StartupData $Items
        [void]$script:SW.Win.Activate()
        return
    }
    $sw = New-Window $StartupXaml
    $sw.Owner = $window
    $sw.Title = 'Programi pri pokretanju  -  ' + $env:COMPUTERNAME
    $script:SW = @{ Win = $sw; Table = $null; View = $null }
    foreach ($n in 'Search', 'RbAll', 'RbOn', 'RbOff', 'RbBad', 'CountText', 'StGrid', 'WebBtn', 'LocBtn', 'RefBtn', 'DelBtn', 'OnBtn', 'OffBtn') {
        $script:SW[$n] = $sw.FindName($n)
    }
    $script:SW.Search.Add_TextChanged({ Update-StartupFilter })
    foreach ($rb in 'RbAll', 'RbOn', 'RbOff', 'RbBad') { $script:SW[$rb].Add_Checked({ Update-StartupFilter }) }
    $script:SW.OffBtn.Add_Click({ Invoke-StartupChange 'off' })
    $script:SW.OnBtn.Add_Click({ Invoke-StartupChange 'on' })
    $script:SW.DelBtn.Add_Click({ Invoke-StartupChange 'del' })
    $script:SW.LocBtn.Add_Click({ Open-StartupLocation })
    $script:SW.WebBtn.Add_Click({ Search-StartupWeb })
    $script:SW.RefBtn.Add_Click({ Invoke-Action 'startup' })
    $sw.Add_Closed({ $script:SW = $null })
    Set-StartupData $Items
    $sw.Show()
}

# ---------------------------------------------------------------------
#  Debloat - prozor
# ---------------------------------------------------------------------
$script:DebloatBoxes = $null

function Show-DebloatWindow {
    param($Found)
    $d = New-Window $DebloatXaml
    $d.Owner = $window
    $panel = $d.FindName('Items')
    $boxes = New-Object System.Collections.Generic.List[object]
    $all = @($Found | Where-Object { $_ })
    $groups = @(
        @{ T = 'STORE APLIKACIJE';                   I = @($all | Where-Object { $_.Kind -eq 'store' }) },
        @{ T = 'PREDINSTALIRANI PROGRAMI (TRIAL)';   I = @($all | Where-Object { $_.Kind -eq 'win32' }) },
        @{ T = 'PODESAVANJA WINDOWSA';               I = @($TweakDefs | ForEach-Object { @{ Kind = 'tweak'; Naziv = $_.N; Opis = ''; R = $_.R; Key = $_.K } }) }
    )
    if ($all.Count -eq 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = 'Na ovom racunaru nije pronadjen poznati bloatware. Mozes primijeniti podesavanja ispod.'
        $tb.Foreground = $Brushes.ok
        $tb.TextWrapping = 'Wrap'
        $tb.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
        [void]$panel.Children.Add($tb)
    }
    foreach ($g in $groups) {
        if ($g.I.Count -eq 0) { continue }
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Text = '{0}  ({1})' -f $g.T, $g.I.Count
        $h.Foreground = Get-Brush '#4FA3C7'
        $h.FontSize = 11
        $h.FontWeight = [System.Windows.FontWeights]::SemiBold
        $h.Margin = New-Object System.Windows.Thickness(0, 14, 0, 6)
        [void]$panel.Children.Add($h)
        foreach ($it in $g.I) {
            $sp = New-Object System.Windows.Controls.StackPanel
            $t1 = New-Object System.Windows.Controls.TextBlock
            $t1.Text = [string]$it.Naziv
            $t1.TextWrapping = 'Wrap'
            [void]$sp.Children.Add($t1)
            if ($it.Opis) {
                $t2 = New-Object System.Windows.Controls.TextBlock
                $t2.Text = [string]$it.Opis
                $t2.FontSize = 11
                $t2.Foreground = Get-Brush '#4F6A85'
                $t2.TextWrapping = 'Wrap'
                [void]$sp.Children.Add($t2)
            }
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $sp
            $cb.IsChecked = [bool]$it.R
            $cb.Tag = $it
            $cb.Foreground = $Brushes.info
            $cb.Margin = New-Object System.Windows.Thickness(0, 4, 0, 4)
            [void]$panel.Children.Add($cb)
            $boxes.Add($cb)
        }
    }
    $script:DebloatBoxes = $boxes
    $script:DebloatOk = $d.FindName('OkBtn')
    foreach ($c in $boxes) { $c.Add_Click({ Update-DebloatCount }) }
    $d.FindName('RecBtn').Add_Click({ foreach ($c in $script:DebloatBoxes) { $c.IsChecked = [bool]$c.Tag.R }; Update-DebloatCount })
    $d.FindName('NoneBtn').Add_Click({ foreach ($c in $script:DebloatBoxes) { $c.IsChecked = $false }; Update-DebloatCount })
    $script:DebloatOk.Add_Click({
        if (@($script:DebloatBoxes | Where-Object { $_.IsChecked }).Count -eq 0) { Show-Info 'Nista nije oznaceno.' 'Debloat' ([System.Windows.Window]::GetWindow($this)); return }
        [System.Windows.Window]::GetWindow($this).DialogResult = $true
    })
    Update-DebloatCount
    $ok = $d.ShowDialog()
    $restore = [bool]$d.FindName('RestoreBox').IsChecked
    $script:DebloatBoxes = $null
    if (-not $ok) { Add-UiLog 'Debloat otkazan - nista nije uklonjeno.' 'dim'; return }
    $sel = @($boxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    if ($sel.Count -eq 0) { return }
    $apps = @($sel | Where-Object { $_.Kind -ne 'tweak' })
    $tws  = @($sel | Where-Object { $_.Kind -eq 'tweak' })
    $list = (@($apps | Select-Object -First 20 | ForEach-Object { ' - ' + $_.Naziv })) -join "`n"
    if ($apps.Count -gt 20) { $list += "`n ... i jos $($apps.Count - 20)" }
    $msg = "Potvrdi uklanjanje:`n`n"
    if ($apps.Count) { $msg += "APLIKACIJE / PROGRAMI ($($apps.Count)):`n$list`n`n" }
    if ($tws.Count)  { $msg += "PODESAVANJA ($($tws.Count)):`n" + ((@($tws | ForEach-Object { ' - ' + $_.Naziv })) -join "`n") + "`n`n" }
    if ($restore) { $msg += 'Prije toga se pravi tacka vracanja sistema.' }
    if (-not (Ask $msg 'Debloat - potvrda')) { Add-UiLog 'Debloat otkazan - nista nije uklonjeno.' 'dim'; return }
    Start-Task 'Uklanjanje bloatware-a' 'Task-Debloat -Items $P.Items -Restore $P.Restore' @{ Items = $sel; Restore = $restore }
}

function Update-DebloatCount {
    if (-not $script:DebloatBoxes -or -not $script:DebloatOk) { return }
    $n = @($script:DebloatBoxes | Where-Object { $_.IsChecked }).Count
    $script:DebloatOk.Content = 'Ukloni oznaceno ({0})' -f $n
}

# ---------------------------------------------------------------------
#  Senzori, traka uzivo i stres test
# ---------------------------------------------------------------------
$script:SNW = $null
$script:Stress = $null
$script:LastSensorStamp = -1

function Format-SensorValue {
    param($v, [string]$Tip)
    if ($null -eq $v) { return '-' }
    switch ($Tip) {
        'Temperature' { return ('{0:N1} {1}C' -f [double]$v, [char]0xB0) }
        'TempLimit'   { return ('{0:N0} {1}C' -f [double]$v, [char]0xB0) }
        'Load'        { return ('{0:N0} %' -f [double]$v) }
        'Fan'         { return ('{0:N0} RPM' -f [double]$v) }
        'Power'       { return ('{0:N1} W' -f [double]$v) }
        'Data'        { return ('{0:N1} GB' -f [double]$v) }
    }
    return ('{0:N1}' -f [double]$v)
}
function Get-SensorTipName {
    param([string]$Tip)
    switch ($Tip) {
        'Temperature' { return 'Temperatura' }
        'TempLimit'   { return 'Granica (fiksno)' }
        'Load'        { return 'Opterecenje' }
        'Fan'         { return 'Ventilator' }
        'Power'       { return 'Potrosnja' }
        'Data'        { return 'Memorija' }
    }
    return $Tip
}
function Get-TempBrush {
    param($t)
    if ($null -eq $t) { return $Brushes.info }
    if ($t -ge 85) { return $Brushes.err }
    if ($t -ge 75) { return $Brushes.warn }
    return $Brushes.ok
}

function Set-Gauge {
    param($Arc, $ValText, $Pct, [string]$Text, [string]$Kind)
    $ValText.Text = $Text
    if ($null -eq $Pct) { $Arc.Data = $null; return }
    $p = [math]::Max(0.5, [math]::Min(99.9, [double]$Pct))
    $c = 25.0; $r = 22.5
    $ang = $p * 3.6 * [math]::PI / 180
    $x = $c + $r * [math]::Sin($ang)
    $y = $c - $r * [math]::Cos($ang)
    $large = 0
    if ($p -gt 50) { $large = 1 }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $d = [string]::Format($inv, 'M {0},{1} A {2},{2} 0 {3} 1 {4:0.###},{5:0.###}', $c, ($c - $r), $r, $large, $x, $y)
    $Arc.Data = [System.Windows.Media.Geometry]::Parse($d)
    $v = [double]$Pct
    $b = $Brushes.head
    if ($Kind -eq 'temp') { if ($v -ge 85) { $b = $Brushes.err } elseif ($v -ge 75) { $b = $Brushes.warn } }
    else { if ($v -ge 90) { $b = $Brushes.err } elseif ($v -ge 70) { $b = $Brushes.warn } }
    $Arc.Stroke = $b
    try { if ($Arc.Effect) { $Arc.Effect.Color = $b.Color } } catch {}
}

function Update-LiveStrip {
    $s = $sync.SensorSummary
    if (-not $s) { return }
    $deg = [string][char]0xB0
    $t = '--'; if ($null -ne $s.CpuLoad) { $t = '{0:N0}%' -f [double]$s.CpuLoad }
    Set-Gauge $GCpuArc $GCpuVal $s.CpuLoad $t 'load'
    $t = '--'; if ($null -ne $s.CpuTemp) { $t = '{0:N0}{1}' -f [double]$s.CpuTemp, $deg }
    Set-Gauge $GTmpArc $GTmpVal $s.CpuTemp $t 'temp'
    $rp = $null
    if ($s.RamTot -gt 0) { $rp = $s.RamUsed / $s.RamTot * 100; $GRamSub.Text = '{0:N1} / {1:N0} GB' -f $s.RamUsed, $s.RamTot }
    $t = '--'; if ($null -ne $rp) { $t = '{0:N0}%' -f $rp }
    Set-Gauge $GRamArc $GRamVal $rp $t 'load'
    $t = '--'; if ($null -ne $s.GpuTemp) { $t = '{0:N0}{1}' -f [double]$s.GpuTemp, $deg }
    Set-Gauge $GGpuArc $GGpuVal $s.GpuTemp $t 'temp'
    $t = '--'; if ($null -ne $s.DiskTemp) { $t = '{0:N0}{1}' -f [double]$s.DiskTemp, $deg }
    Set-Gauge $GDskArc $GDskVal $s.DiskTemp $t 'temp'
    $LiveSrc.Text = '(' + $s.Source + ')'
    $LiveSrc.Foreground = $Brushes.dim
    if ($s.Source -ne 'LibreHardwareMonitor' -and $sync.WantLhm -and $sync.SensorNote -notmatch '^Osnovni') {
        $LiveSrc.Text = '(osnovni senzori - LibreHardwareMonitor nije ucitan, preci misem)'
        $LiveSrc.Foreground = $Brushes.warn
    }
    $LiveSrc.ToolTip = [string]$sync.SensorNote
}

function Update-SensorWindow {
    $w = $script:SNW
    if (-not $w) { return }
    $note = [string]$sync.SensorNote
    if ($w.SrcText.Text -ne $note) { $w.SrcText.Text = $note }
    if ($sync.SensorSummary -and $sync.SensorSummary.Source -eq 'LibreHardwareMonitor') { $w.HelpText.Visibility = 'Collapsed' }
    foreach ($r in @($sync.SensorRows)) {
        if (-not $r) { continue }
        $cur = Format-SensorValue $r.Value $r.Tip
        $mn  = Format-SensorValue $r.Min $r.Tip
        $mx  = Format-SensorValue $r.Max $r.Tip
        $lvl = ''
        if ($r.Tip -eq 'Temperature') { if ($r.Value -ge 85) { $lvl = 'hot' } elseif ($r.Value -ge 75) { $lvl = 'warn' } }
        elseif ($r.Tip -eq 'TempLimit') { $lvl = 'limit' }
        $row = $w.Table.Rows.Find([string]$r.Key)
        if ($row) {
            if ([string]$row['Trenutno'] -ne $cur) { $row['Trenutno'] = $cur }
            if ([string]$row['Min'] -ne $mn) { $row['Min'] = $mn }
            if ([string]$row['Max'] -ne $mx) { $row['Max'] = $mx }
            if ([string]$row['Nivo'] -ne $lvl) { $row['Nivo'] = $lvl }
        } else {
            [void]$w.Table.Rows.Add([string]$r.Key, [string]$r.Hardver, [string]$r.Senzor, (Get-SensorTipName $r.Tip), $cur, $mn, $mx, $lvl)
        }
    }
}

function Show-SensorWindow {
    if ($script:SNW) { [void]$script:SNW.Win.Activate(); return }
    $sync.WantLhm = $true
    $sw = New-Window $SensorXaml
    $sw.Owner = $window
    $sw.Title = 'Temperature i senzori  -  ' + $env:COMPUTERNAME
    $script:SNW = @{ Win = $sw }
    foreach ($n in 'SrcText', 'StressText', 'StressBtn', 'SensGrid', 'HelpText') { $script:SNW[$n] = $sw.FindName($n) }
    $dt = New-Object System.Data.DataTable
    foreach ($c in 'Key', 'Hardver', 'Senzor', 'Tip', 'Trenutno', 'Min', 'Max', 'Nivo') { [void]$dt.Columns.Add($c, [string]) }
    $dt.PrimaryKey = [System.Data.DataColumn[]]@($dt.Columns['Key'])
    $script:SNW.Table = $dt
    $script:SNW.View = $dt.DefaultView
    $script:SNW.View.Sort = 'Hardver ASC, Tip ASC, Senzor ASC'
    $script:SNW.SensGrid.ItemsSource = $script:SNW.View
    if ($script:Stress) { $script:SNW.StressBtn.Content = 'Zaustavi stres test' }
    $script:SNW.StressBtn.Add_Click({ Switch-Stress })
    $sw.Add_Closed({
        if ($script:Stress) { $sync.StopStress = $true; Add-UiLog 'Prozor senzora zatvoren - stres test se zaustavlja.' 'warn' }
        $script:SNW = $null
    })
    Update-SensorWindow
    $sw.Show()
}

function Start-CpuStress {
    param([int]$Minutes = 5)
    if ($script:Stress) { return }
    $sync.StopStress = $false
    $n = [Environment]::ProcessorCount
    $pool = [runspacefactory]::CreateRunspacePool(1, $n)
    $pool.Open()
    $burn = {
        param($s, $min)
        $end = [DateTime]::Now.AddMinutes($min)
        while ([DateTime]::Now -lt $end -and -not $s.StopStress) {
            $x = 0.0
            for ($i = 1; $i -lt 200000; $i++) { $x += [Math]::Sqrt($i) }
        }
    }
    $jobs = New-Object System.Collections.Generic.List[object]
    for ($k = 0; $k -lt $n; $k++) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($burn.ToString()).AddArgument($sync).AddArgument($Minutes)
        $jobs.Add(@{ PS = $ps; A = $ps.BeginInvoke() })
    }
    $script:Stress = @{ Pool = $pool; Jobs = $jobs; Start = Get-Date; Min = $Minutes; MaxCpu = $null }
    if ($script:SNW) { $script:SNW.StressBtn.Content = 'Zaustavi stres test' }
    Add-UiLog ('Stres test CPU pokrenut ({0} niti, {1} min). Prati temperature.' -f $n, $Minutes) 'warn'
}

function Switch-Stress {
    if ($script:Stress) { $sync.StopStress = $true; Add-UiLog 'Zaustavljam stres test...' 'warn'; return }
    $o = $window
    if ($script:SNW) { $o = $script:SNW.Win }
    $msg = "CPU ce 5 minuta raditi na 100%.`n`nNormalno je do oko 85-90 C. Ako ide preko toga, hladjenje ne radi kako treba (prasina, termalna pasta, ventilator).`nTest se sam zaustavlja ako CPU dostigne 97 C.`n`nBez LibreHardwareMonitor-a CPU temperatura cesto nije dostupna - tada je prati drugim alatom (npr. HWiNFO).`n`nPokrenuti?"
    $ans = [System.Windows.MessageBox]::Show($o, $msg, 'Stres test', 'YesNo', 'Warning')
    if ("$ans" -ne 'Yes') { return }
    Start-CpuStress 5
}

function Update-Stress {
    $st = $script:Stress
    if (-not $st) { return }
    $s = $sync.SensorSummary
    if ($s -and $null -ne $s.CpuTemp) {
        if ($null -eq $st.MaxCpu -or $s.CpuTemp -gt $st.MaxCpu) { $st.MaxCpu = [double]$s.CpuTemp }
        if ($s.CpuTemp -ge 97 -and -not $sync.StopStress) {
            $sync.StopStress = $true
            Add-UiLog ('CPU je dostigao {0:N0} C - stres test automatski zaustavljen! Provjeri hladjenje.' -f $s.CpuTemp) 'err'
        }
    }
    $el = (Get-Date) - $st.Start
    $deg = [char]0xB0
    $mx = '-'
    if ($null -ne $st.MaxCpu) { $mx = '{0:N0} {1}C' -f $st.MaxCpu, $deg }
    $running = @($st.Jobs | Where-Object { -not $_.A.IsCompleted }).Count
    if ($script:SNW) { $script:SNW.StressText.Text = ('Stres test {0:mm\:ss} / {1:00}:00   max CPU {2}' -f $el, $st.Min, $mx) }
    if ($running -eq 0) {
        foreach ($j in $st.Jobs) { try { [void]$j.PS.EndInvoke($j.A) } catch {}; try { $j.PS.Dispose() } catch {} }
        try { $st.Pool.Close(); $st.Pool.Dispose() } catch {}
        $script:Stress = $null
        Add-UiLog ('Stres test zavrsen nakon {0:mm\:ss}. Najvisa CPU temperatura: {1}' -f $el, $mx) 'ok'
        Add-Done ('Stres test CPU ({0:mm\:ss}) - najvisa temperatura procesora {1}' -f $el, $mx) 'stress'
        Save-Session
        if ($script:SNW) {
            $script:SNW.StressBtn.Content = 'Stres test CPU (5 min)'
            $script:SNW.StressText.Text = ('Zavrseno - max CPU {0}' -f $mx)
        }
    }
}

# ---------------------------------------------------------------------
#  Domena - dijalog i akcije
# ---------------------------------------------------------------------
$PrefsFile = Join-Path $Root 'postavke.json'
function Get-ToolPrefs {
    try { if (Test-Path -LiteralPath $PrefsFile) { return (Get-Content -LiteralPath $PrefsFile -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch {}
    return [pscustomobject]@{}
}
function Set-ToolPref {
    param([hashtable]$Values)
    $h = @{}
    $cur = Get-ToolPrefs
    foreach ($p in $cur.PSObject.Properties) { $h[$p.Name] = $p.Value }
    foreach ($k in $Values.Keys) { $h[$k] = $Values[$k] }
    try { [System.IO.File]::WriteAllText($PrefsFile, ($h | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false))) } catch {}
}

$script:DD = $null
function Show-DomainDialog {
    param([string]$Mode, [string]$Domain)
    $prefs = Get-ToolPrefs
    $d = New-Window $DomainXaml
    $d.Owner = $window
    $script:DD = @{ Win = $d; Mode = $Mode; Result = $null }
    foreach ($n in 'Msg', 'RowDomain', 'RowUser', 'RowPass', 'RowServer', 'RowOu', 'RowName', 'RowDns', 'DomainTb', 'UserTb', 'PassBox', 'ServerTb', 'OuTb', 'NameTb', 'DnsTb', 'Hint', 'OkBtn') {
        $script:DD[$n] = $d.FindName($n)
    }
    $vis = @{
        diag   = @('RowDomain')
        repair = @('RowDomain', 'RowUser', 'RowPass', 'RowServer', 'RowDns')
        join   = @('RowDomain', 'RowUser', 'RowPass', 'RowOu', 'RowName', 'RowDns')
        leave  = @('RowDomain', 'RowUser', 'RowPass')
    }
    foreach ($r in 'RowDomain', 'RowUser', 'RowPass', 'RowServer', 'RowOu', 'RowName', 'RowDns') {
        if ($vis[$Mode] -contains $r) { $script:DD[$r].Visibility = 'Visible' } else { $script:DD[$r].Visibility = 'Collapsed' }
    }
    $script:DD.DomainTb.Text = $Domain
    $sameDomain = ($Domain -and [string]$prefs.LastDomain -ieq $Domain)
    if ($sameDomain -and $prefs.LastUser) { $script:DD.UserTb.Text = [string]$prefs.LastUser }
    elseif ($Domain) { $script:DD.UserTb.Text = "administrator@$Domain" }
    if ($sameDomain -and $prefs.LastOU) { $script:DD.OuTb.Text = [string]$prefs.LastOU }
    if ($sameDomain -and $prefs.LastDns) { $script:DD.DnsTb.Text = [string]$prefs.LastDns }

    switch ($Mode) {
        'diag' {
            $d.Title = 'Provjera domene'
            $script:DD.Msg.Text = 'Racunar nije u domeni. Upisi domenu koju treba provjeriti.'
            $script:DD.Hint.Text = 'Provjerava DNS, domain controller, portove i razliku u vremenu. Nista ne mijenja.'
        }
        'repair' {
            $d.Title = 'Popravi vezu sa domenom'
            $script:DD.Msg.Text = 'Popravka veze sa domenom (trust relationship)'
            $script:DD.DomainTb.IsReadOnly = $true
            $script:DD.Hint.Text = "Rjesava gresku 'The trust relationship between this workstation and the primary domain failed' bez izlaska iz domene i bez restarta - profili ostaju netaknuti.`nAko ne mozes uci: prijavi se lokalnim adminom, ili domenskim nalogom sa izvucenim mreznim kablom, pa vrati kabl prije pokretanja."
        }
        'join' {
            $d.Title = 'Pridruzi racunar domeni'
            $script:DD.Msg.Text = 'Pridruzivanje racunara domeni'
            $script:DD.NameTb.Text = $env:COMPUTERNAME
            $script:DD.Hint.Text = "Ako racunar sa istim imenom vec postoji u AD-u, bice ponovo iskoristen - domenski korisnici zadrzavaju svoje profile.`nNakon pridruzivanja potreban je restart."
        }
        'leave' {
            $d.Title = 'Izbaci racunar iz domene'
            $script:DD.Msg.Text = 'Izbacivanje racunara iz domene (u WORKGROUP)'
            $script:DD.DomainTb.IsReadOnly = $true
            $loc = ''
            try { $loc = (@(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled } | ForEach-Object { $_.Name }) -join ', ') } catch {}
            if (-not $loc) { $loc = '(nije moguce procitati)' }
            $script:DD.Hint.Text = "PAZNJA: nakon izlaska prijava je moguca samo LOKALNIM nalogom. Provjeri da znas lozinku lokalnog administratora!`nAktivni lokalni nalozi: $loc`nAko domenski nalog ne prodje, alat izbacuje racunar lokalno (radi i kad je veza sa domenom pokvarena)."
        }
    }

    $script:DD.OkBtn.Add_Click({
        $w = $script:DD
        $dom = $w.DomainTb.Text.Trim()
        if (-not $dom) { Show-Info 'Upisi naziv domene.' 'Domena' $w.Win; return }
        if ($w.Mode -ne 'diag') {
            if (-not $w.UserTb.Text.Trim() -or $w.PassBox.SecurePassword.Length -eq 0) { Show-Info 'Upisi korisnicko ime i lozinku domenskog administratora.' 'Domena' $w.Win; return }
        }
        $w.Win.DialogResult = $true
    })
    if (-not $d.ShowDialog()) { $script:DD = $null; return $null }

    $w = $script:DD
    $dom = $w.DomainTb.Text.Trim()
    $res = @{ Domain = $dom; Server = $w.ServerTb.Text.Trim(); OU = $w.OuTb.Text.Trim(); Name = $w.NameTb.Text.Trim(); Dns = $w.DnsTb.Text.Trim(); Cred = $null }
    if ($Mode -ne 'diag') {
        $u = $w.UserTb.Text.Trim()
        if ($u -notmatch '[\\@]') { $u = "$u@$dom" }
        $res.Cred = New-Object System.Management.Automation.PSCredential($u, $w.PassBox.SecurePassword)
        $save = @{ LastDomain = $dom; LastUser = $u }
        if ($res.OU)  { $save.LastOU = $res.OU }
        if ($res.Dns) { $save.LastDns = $res.Dns }
        Set-ToolPref $save
    } else { Set-ToolPref @{ LastDomain = $dom } }
    $script:DD = $null
    return $res
}

function Invoke-DomainMenu {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.DomainRole -ge 4) { Show-Info 'Ovo je domain controller - domenske operacije nisu dostupne.' 'Domena'; return }
    if ($cs.PartOfDomain) { $state = "Racunar je u domeni: $($cs.Domain)" } else { $state = "Racunar NIJE u domeni (radna grupa: $($cs.Workgroup))" }
    $m = Show-Choice 'Domena' "$state`n`nSta zelis uraditi?" @(
        'Provjera (DNS, domain controller, portovi, vrijeme, veza sa domenom)',
        'Popravi vezu sa domenom (trust relationship) - bez izlaska iz domene',
        'Pridruzi racunar domeni',
        'Izbaci racunar iz domene (u WORKGROUP)')
    if ($m -lt 0) { return }
    $prefs = Get-ToolPrefs
    $dom = [string]$prefs.LastDomain
    if ($cs.PartOfDomain) { $dom = $cs.Domain }
    switch ($m) {
        0 {
            if ($cs.PartOfDomain) { Start-Task 'Provjera domene' 'Task-DomainDiag -Domain $P.D' @{ D = $cs.Domain }; return }
            $r = Show-DomainDialog 'diag' $dom
            if ($r) { Start-Task 'Provjera domene' 'Task-DomainDiag -Domain $P.D' @{ D = $r.Domain } }
        }
        1 {
            if (-not $cs.PartOfDomain) { Show-Info 'Racunar nije u domeni - izaberi "Pridruzi racunar domeni".' 'Domena'; return }
            $r = Show-DomainDialog 'repair' $dom
            if ($r) { Start-Task 'Popravka veze sa domenom' 'Task-DomainRepair -Server $P.S -Cred $P.C -Dns $P.N' @{ S = $r.Server; C = $r.Cred; N = $r.Dns } }
        }
        2 {
            if ($cs.PartOfDomain) {
                Show-Info ("Racunar je vec u domeni $($cs.Domain).`nAko prijava ne radi, izaberi 'Popravi vezu sa domenom'. Za prelazak u drugu domenu prvo ga izbaci.") 'Domena'
                return
            }
            $r = Show-DomainDialog 'join' $dom
            if ($r) { Start-Task ('Pridruzivanje domeni ' + $r.Domain) 'Task-DomainJoin -Domain $P.D -Cred $P.C -OU $P.O -NewName $P.N -Dns $P.S' @{ D = $r.Domain; C = $r.Cred; O = $r.OU; N = $r.Name; S = $r.Dns } }
        }
        3 {
            if (-not $cs.PartOfDomain) { Show-Info 'Racunar nije u domeni.' 'Domena'; return }
            $r = Show-DomainDialog 'leave' $dom
            if ($r -and (Ask "Sigurno izbaciti racunar iz domene $($cs.Domain)?`n`nNakon restarta prijava je moguca samo lokalnim nalogom." 'Domena')) {
                Start-Task 'Izbacivanje iz domene' 'Task-DomainLeave -Cred $P.C' @{ C = $r.Cred }
            }
        }
    }
}

# ---------------------------------------------------------------------
#  Prijava greske (bug report)
# ---------------------------------------------------------------------
$InputXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Prijava greske" Width="580" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" Background="#0B1422" Foreground="#E6F4FA" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources><!--COMMON--></Window.Resources>
  <StackPanel Margin="22">
    <TextBlock x:Name="Msg" TextWrapping="Wrap" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,12"/>
    <TextBox x:Name="Input" Height="150" AcceptsReturn="True" TextWrapping="Wrap" VerticalContentAlignment="Top" VerticalScrollBarVisibility="Auto"/>
    <TextBlock x:Name="Hint" TextWrapping="Wrap" Foreground="#7A9AB8" FontSize="12" Margin="0,10,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="CancelBtn" Content="Odustani" Style="{StaticResource Btn}" IsCancel="True"/>
      <Button x:Name="OkBtn" Content="Napravi prijavu" Style="{StaticResource Primary}"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

function Protect-Text {
    param([string]$t)
    if (-not $t) { return $t }
    $t = [regex]::Replace($t, '\b\d{6}(-\d{6}){7}\b', '[BITLOCKER KLJUC SKRIVEN]')
    $t = [regex]::Replace($t, '\b[A-Z0-9]{5}(-[A-Z0-9]{5}){4}\b', '[KLJUC SKRIVEN]')
    foreach ($s in @($ClientBox.Text.Trim(), $NoteBox.Text.Trim(), [string]$sync.Phone)) {
        if ($s -and $s.Length -ge 3) { $t = $t.Replace($s, '[SKRIVENO]') }
    }
    return $t
}

function New-BugReport {
    $d = New-Window $InputXaml
    $d.Owner = $window
    $d.FindName('Msg').Text = 'Opisi sta se desilo'
    $d.FindName('Hint').Text = "Napisi sta si kliknuo, sta si ocekivao i sta se desilo umjesto toga.`nAlat ce spakovati: verziju, podatke o Windowsu i ekranu, log rada i konzolu. Lozinke, kljucevi i ime klijenta se uklanjaju."
    $d.FindName('OkBtn').Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
    $box = $d.FindName('Input')
    [void]$box.Focus()
    if (-not $d.ShowDialog()) { return }
    $desc = $box.Text.Trim()

    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
    $dir = Join-Path $Root 'BugReports'
    try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch { $dir = [Environment]::GetFolderPath('Desktop') }
    $tmp = Join-Path $env:TEMP ('kt_bug_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $net = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
        $scale = '?'
        try { $scale = '{0}%' -f [math]::Round([System.Windows.PresentationSource]::FromVisual($window).CompositionTarget.TransformToDevice.M11 * 100) } catch {}
        $wa = [System.Windows.SystemParameters]::WorkArea
        $lhm = [bool](Get-ChildItem -Path (Join-Path $Root 'Alati') -Recurse -Filter 'LibreHardwareMonitorLib.dll' -ErrorAction SilentlyContinue | Select-Object -First 1)
        $info = @(
            "KESTRELTECH SERVIS TOOLKIT - PRIJAVA GRESKE"
            "Verzija alata : $Verzija"
            "Datum         : $(Get-Date -Format 'dd.MM.yyyy HH:mm')"
            ""
            "OPIS:"
            (Protect-Text $desc)
            ""
            "SISTEM"
            "Windows       : $($os.Caption) $($cv.DisplayVersion) build $($os.BuildNumber).$($cv.UBR) ($($os.OSArchitecture))"
            "Jezik         : $((Get-Culture).Name) / UI $((Get-UICulture).Name)"
            "PowerShell    : $($PSVersionTable.PSVersion)"
            ".NET release  : $net"
            "Racunar       : $($cs.Manufacturer) $($cs.Model)"
            "RAM           : $(Format-Size $cs.TotalPhysicalMemory)"
            "Skaliranje    : $scale   radna povrsina: $([math]::Round($wa.Width)) x $([math]::Round($wa.Height)) DIP"
            "Senzori       : $([string]$sync.SensorNote)  (LibreHardwareMonitor u Alati: $lhm)"
            "Zadatak u toku: $(if ($script:Job) { $script:Job.Title } else { 'nema' })"
        )
        Set-Content -LiteralPath (Join-Path $tmp 'info.txt') -Value $info -Encoding UTF8
        $kons = ($Lines | ForEach-Object { '[{0}] {1}' -f $_.T, $_.M }) -join "`r`n"
        Set-Content -LiteralPath (Join-Path $tmp 'konzola.txt') -Value (Protect-Text $kons) -Encoding UTF8
        if (Test-Path -LiteralPath $sync.LogFile) {
            $lg = [System.IO.File]::ReadAllText($sync.LogFile)
            Set-Content -LiteralPath (Join-Path $tmp 'servis_log.txt') -Value (Protect-Text $lg) -Encoding UTF8
            $errLines = @($lg -split "`r?`n" | Where-Object { $_ -match '^\[\d\d:\d\d:\d\d\] (ERR|WARN)' })
            if ($errLines.Count) { Set-Content -LiteralPath (Join-Path $tmp 'greske.txt') -Value (Protect-Text ($errLines -join "`r`n")) -Encoding UTF8 }
        }
        $zip = Join-Path $dir ('BugReport_v{0}_{1}_{2}.zip' -f $Verzija, $env:COMPUTERNAME, $stamp)
        Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zip -Force
        Add-UiLog ('Prijava greske napravljena: ' + $zip) 'ok'
        Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $zip)
        if ($PodrskaEmail) {
            $subj = [uri]::EscapeDataString("Kestrel Servis Toolkit v$Verzija - prijava greske")
            $body = [uri]::EscapeDataString("Zdravo,`n`nU prilogu je prijava greske (ZIP fajl koji se upravo otvorio u folderu - samo ga prevuci u email).`n`nOpis:`n$desc`n")
            try { Start-Process ('mailto:{0}?subject={1}&body={2}' -f $PodrskaEmail, $subj, $body) } catch {}
            Show-Info ("Prijava je spremna.`n`nOtvoren je email za $PodrskaEmail - prevuci ZIP iz foldera u email i posalji.") 'Prijava greske'
        } else {
            Show-Info "Prijava je spremna - ZIP je oznacen u folderu koji se otvorio.`nPosalji ga autoru alata (email, Viber, WhatsApp...)." 'Prijava greske'
        }
    } catch {
        Add-UiLog ('Prijava greske nije napravljena: ' + $_.Exception.Message) 'err'
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Select-Folder {
    param([string]$Desc, [string]$Start)
    $f = New-Object System.Windows.Forms.FolderBrowserDialog
    $f.Description = $Desc
    if ($Start -and (Test-Path $Start)) { $f.SelectedPath = $Start }
    if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $f.SelectedPath }
    return $null
}

function Open-Tools {
    $dir = Join-Path $Root 'Alati'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $exes = @(Get-ChildItem -Path $dir -Filter *.exe -Recurse -Depth 2 -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notmatch '(?i)unins|setup|updater' } | Sort-Object BaseName)
    if ($exes.Count -eq 0) {
        Show-Info "Folder Alati je prazan.`n`nUbaci portable alate (CrystalDiskInfo, HWiNFO, Autoruns, SDIO...), svaki u svoj podfolder, i pojavice se ovdje." 'Alati'
        Start-Process explorer.exe -ArgumentList "`"$dir`""
        return
    }
    $i = Show-Choice 'Alati sa USB-a' 'Izaberi alat:' @($exes | ForEach-Object { '{0}     ({1})' -f $_.BaseName, $_.Directory.Name })
    if ($i -ge 0) {
        Start-Process -FilePath $exes[$i].FullName -WorkingDirectory $exes[$i].DirectoryName
        Add-UiLog ('Pokrenut alat: {0}' -f $exes[$i].Name) 'info'
    }
}

$SysApps = @(
    @('Upravljac uredjajima (Device Manager)', 'devmgmt.msc'),
    @('Upravljanje diskovima', 'diskmgmt.msc'),
    @('Event Viewer', 'eventvwr.msc'),
    @('Servisi', 'services.msc'),
    @('Upravljanje racunarom', 'compmgmt.msc'),
    @('Informacije o sistemu (msinfo32)', 'msinfo32.exe'),
    @('Programi i funkcije', 'appwiz.cpl'),
    @('Mrezne konekcije', 'ncpa.cpl'),
    @('Svojstva sistema', 'sysdm.cpl'),
    @('Opcije napajanja', 'powercfg.cpl'),
    @('Task Manager', 'taskmgr.exe'),
    @('Resource Monitor', 'resmon.exe'),
    @('Registry Editor', 'regedit.exe'),
    @('Disk Cleanup', 'cleanmgr.exe'),
    @('Command Prompt (admin)', 'cmd.exe')
)
function Open-SysApps {
    $i = Show-Choice 'Windows alati' 'Izaberi alat:' @($SysApps | ForEach-Object { $_[0] })
    if ($i -lt 0) { return }
    $cmd = $SysApps[$i][1]
    try {
        if ($cmd -like '*.cpl') { Start-Process -FilePath 'control.exe' -ArgumentList $cmd }
        else { Start-Process -FilePath $cmd }
        Add-UiLog ('Otvoren: {0}' -f $SysApps[$i][0]) 'info'
    } catch { Add-UiLog ('Ne mogu otvoriti {0}: {1}' -f $cmd, $_.Exception.Message) 'err' }
}

# ---------------------------------------------------------------------
#  Akcije dugmadi
# ---------------------------------------------------------------------
function Invoke-Action {
    param([string]$Id)
    try {
        switch ($Id) {
            'sensors'   { Show-SensorWindow; return }
            'workorder' { Show-WorkOrder; return }
            'tools'     { Open-Tools; return }
            'sysapps'   { Open-SysApps; return }
            'bugreport' { New-BugReport; return }
        }
        if ($script:Job) { Show-Info 'Zadatak je vec u toku. Sacekaj da zavrsi ili klikni Prekini.'; return }
        Invoke-ActionCore $Id
    } catch {
        Add-UiLog ('Greska: ' + $_.Exception.GetBaseException().Message) 'err'
    }
}

function Invoke-ActionCore {
    param([string]$Id)
    switch ($Id) {
        'domain'  { Invoke-DomainMenu }
        'update'  { Start-Task 'Provjera azuriranja' 'Task-CheckUpdate -Silent $false' }
        'package' { Start-Task 'Paket za testere' 'Task-SharePackage' }
        'startup' { Start-Task 'Programi pri pokretanju' 'Task-Startup' }
        'debloat' { Start-Task 'Trazim bloatware' 'Task-DebloatScan' }
        'quick'   { Start-Task 'Brzi pregled sistema' 'Task-Quick' }
        'report'  { Start-Task 'Izvjestaj za klijenta' 'Task-Report' }
        'disk'    { Start-Task 'Zdravlje diskova' 'Task-Disk' }
        'crash'   { Start-Task 'Plavi ekrani i greske' 'Task-Crash' }
        'battery' { Start-Task 'Baterija' 'Task-Battery' }
        'security' {
            $r = [System.Windows.MessageBox]::Show($window, "Pokrenuti i Windows Defender azuriranje + brzo skeniranje?`n`nDa = provjera + skeniranje`nNe = samo provjera", 'Sigurnosna provjera', 'YesNoCancel', 'Question')
            if ("$r" -eq 'Cancel') { return }
            Start-Task 'Sigurnosna provjera' 'Task-Security -Scan $P.Scan' @{ Scan = ("$r" -eq 'Yes') }
        }
        'repair' {
            if (Ask "DISM + SFC popravka sistemskih fajlova.`nTrajanje 10-40 min, potreban je internet.`n`nPokrenuti?") { Start-Task 'Popravka sistema (DISM + SFC)' 'Task-Repair' }
        }
        'chkdsk' {
            $vols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Fixed' } | Sort-Object DriveLetter)
            if ($vols.Count -eq 0) { Show-Info 'Nisu pronadjene particije.'; return }
            $opts = @($vols | ForEach-Object { '{0}:   {1}   ({2}, {3} slobodno)' -f $_.DriveLetter, $_.FileSystemLabel, $_.FileSystem, (Format-Size $_.SizeRemaining) })
            $i = Show-Choice 'Provjera diska' 'Izaberi particiju:' $opts
            if ($i -lt 0) { return }
            $m = Show-Choice 'Provjera diska' 'Nacin rada:' @('Samo provjera (online, bez restarta)', 'Provjera + popravka ako ima gresaka (sistemska particija pri restartu)')
            if ($m -lt 0) { return }
            Start-Task 'Provjera diska (CHKDSK)' 'Task-Chkdsk -Drive $P.Drive -Fix $P.Fix' @{ Drive = [string]$vols[$i].DriveLetter; Fix = ($m -eq 1) }
        }
        'wureset' {
            if (Ask "Zaustavlja Windows Update servise i resetuje cache (SoftwareDistribution, catroot2).`n`nNastaviti?") { Start-Task 'Reset Windows Update' 'Task-WUReset' }
        }
        'network' {
            $m = Show-Choice 'Mreza' 'Sta zelis uraditi?' @('Dijagnostika (adapteri, ping, DNS, HTTPS)', 'Brza popravka (flush DNS + nova IP adresa)', 'Potpuni reset mreze (Winsock + TCP/IP) - trazi restart', 'Detalji Wi-Fi konekcije')
            if ($m -lt 0) { return }
            if ($m -eq 2 -and -not (Ask "Potpuni reset vraca mrezna podesavanja na pocetna.`nStaticke IP adrese i VPN adapteri ce mozda trebati ponovo podesiti.`n`nNastaviti?")) { return }
            Start-Task 'Mreza' 'Task-Network -Mode $P.Mode' @{ Mode = @('diag', 'quick', 'full', 'wifi')[$m] }
        }
        'cleanup' {
            $sel = Show-Checklist 'Ciscenje sistema' 'Sta obrisati? Kos za smece i licni fajlovi se ne diraju.' @(
                @{ K = 'usertemp'; T = 'Temp fajlovi svih korisnika';                  C = $true },
                @{ K = 'wintemp';  T = 'Windows Temp';                                 C = $true },
                @{ K = 'wucache';  T = 'Windows Update cache';                         C = $true },
                @{ K = 'wer';      T = 'Izvjestaji o greskama (WER)';                  C = $true },
                @{ K = 'do';       T = 'Delivery Optimization cache';                  C = $true },
                @{ K = 'winsxs';   T = 'WinSxS ciscenje komponenti (DISM, 5-15 min)'; C = $false }
            )
            if (-not $sel) { return }
            Start-Task 'Ciscenje sistema' 'Task-Cleanup -Items $P.Items' @{ Items = $sel }
        }
        'drvbackup' { Start-Task 'Backup drajvera' 'Task-DriverBackup' }
        'drvrestore' {
            $dirs = @(Get-ChildItem -Path (Join-Path $Root 'Drajveri') -Directory -ErrorAction SilentlyContinue)
            $opts = @($dirs | ForEach-Object { $_.Name }) + @('Izaberi drugi folder...')
            $i = Show-Choice 'Vracanje drajvera' ("Ovaj racunar: {0}`n`nIzaberi backup drajvera:" -f $script:ModelText) $opts
            if ($i -lt 0) { return }
            if ($i -lt $dirs.Count) { $path = $dirs[$i].FullName }
            else { $path = Select-Folder 'Folder sa drajverima (.inf fajlovi)' $Root; if (-not $path) { return } }
            if (Ask "Instalirati sve drajvere iz:`n$path ?") { Start-Task 'Vracanje drajvera' 'Task-DriverRestore -Path $P.Path' @{ Path = $path } }
        }
        'userbackup' {
            $profs = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
                       Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) } | Sort-Object LocalPath)
            if ($profs.Count -eq 0) { Show-Info 'Nisu pronadjeni korisnicki profili.'; return }
            $opts = @($profs | ForEach-Object {
                $lu = '-'
                if ($_.LastUseTime) { $lu = $_.LastUseTime.ToString('dd.MM.yyyy') }
                '{0}     (zadnje koristen {1})' -f $_.LocalPath, $lu
            })
            $i = Show-Choice 'Backup podataka' 'Izaberi korisnika:' $opts
            if ($i -lt 0) { return }
            $pp   = $profs[$i].LocalPath
            $user = Split-Path $pp -Leaf
            $leaf = '{0}_{1}_{2}' -f $env:COMPUTERNAME, $user, (Get-Date -Format 'yyyy-MM-dd')
            $def  = Join-Path $Root "Backup\$leaf"
            $d = Show-Choice 'Backup podataka' 'Gdje sacuvati backup?' @("Na USB:  $def", 'Izaberi drugu lokaciju...')
            if ($d -lt 0) { return }
            $dest = $def
            if ($d -eq 1) { $f = Select-Folder 'Odrediste za backup' $Root; if (-not $f) { return }; $dest = Join-Path $f $leaf }
            $od = $false
            if (Get-ChildItem -LiteralPath $pp -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue) {
                $od = Ask "Korisnik ima OneDrive folder.`nUkljuciti ga u backup?`n(fajlovi koji su samo u oblaku ce se preuzimati tokom kopiranja)"
            }
            Show-Info 'Zatvori browsere i Outlook na ovom racunaru prije backup-a (zakljucani fajlovi se ne mogu kopirati).' 'Backup podataka'
            Start-Task "Backup podataka ($user)" 'Task-UserBackup -ProfilePath $P.Prof -Dest $P.Dest -OneDrive $P.OD' @{ Prof = $pp; Dest = $dest; OD = $od }
        }
        'wifi' {
            if (Ask "Izvoz sacuvanih Wi-Fi lozinki i Windows kljuca u folder izvjestaja.`nFajl sadrzi lozinke - predaj ga klijentu i obrisi sa USB-a.`n`nNastaviti?") { Start-Task 'Wi-Fi lozinke i licenca' 'Task-Wifi' }
        }
        'bitlocker' {
            $m = Show-Choice 'BitLocker' 'Sta zelis uraditi?' @('Prikazi status i sacuvaj recovery kljuceve', 'Pauziraj BitLocker do sljedeceg restarta (BIOS update / zamjena hardvera)')
            if ($m -lt 0) { return }
            Start-Task 'BitLocker' 'Task-BitLocker -Suspend $P.S' @{ S = ($m -eq 1) }
        }
        'restore' {
            if (Ask "Kreirati tacku vracanja sistema?`n(System Restore ce se ukljuciti na sistemskom disku ako je iskljucen)") { Start-Task 'Tacka vracanja' 'Task-RestorePoint' }
        }
        'wgupdate' {
            if (Ask 'Azurirati sve programe preko winget-a? Moze potrajati.') { Start-Task 'Azuriranje programa' 'Task-WingetUpgrade' }
        }
        'wgstd' {
            $items = @($StandardniProgrami | ForEach-Object { @{ K = $_; T = $_; C = $true } })
            $sel = Show-Checklist 'Standardni paket' 'Izaberi programe za instalaciju (lista se mijenja na vrhu skripte):' $items
            if (-not $sel) { return }
            Start-Task 'Instalacija programa' 'Task-WingetInstall -Ids $P.Ids' @{ Ids = $sel }
        }
        'wgexport' { Start-Task 'Izvoz liste programa' 'Task-WingetExport' }
        'wgimport' {
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = 'winget lista (*.json)|*.json'
            $pd = Join-Path $Root 'Programi'
            if (Test-Path $pd) { $dlg.InitialDirectory = $pd }
            if ($dlg.ShowDialog($window)) { Start-Task 'Uvoz liste programa' 'Task-WingetImport -File $P.F' @{ F = $dlg.FileName } }
        }
        'programs' { Start-Task 'Instalirani programi' 'Task-Programs' }
        'tools'    { Open-Tools }
        'sysapps'  { Open-SysApps }
    }
}

function Invoke-Auto {
    if ($script:Job) { Show-Info 'Zadatak je vec u toku.'; return }
    $steps = Show-Checklist 'Automatski servis' "Izaberi korake. Trajanje 20-60 min, racunar se ne restartuje sam.`nNapomena i ime klijenta se upisuju u izvjestaj." @(
        @{ K = 'restore'; T = '1. Tacka vracanja sistema';              C = $true },
        @{ K = 'cleanup'; T = '2. Ciscenje privremenih fajlova';        C = $true },
        @{ K = 'repair';  T = '3. Popravka sistema (DISM + SFC)';       C = $true },
        @{ K = 'winget';  T = '4. Azuriranje svih programa (winget)';   C = $false },
        @{ K = 'report';  T = '5. Izvjestaj za klijenta (HTML)';        C = $true }
    )
    if (-not $steps) { return }
    Start-Task 'Automatski servis' 'Task-Auto -Steps $P.Steps' @{ Steps = $steps }
}

# ---------------------------------------------------------------------
#  Dogadjaji
# ---------------------------------------------------------------------
$AutoBtn.Add_Click({ Invoke-Auto })
$RefreshBtn.Add_Click({ Start-Dashboard })
$ClearBtn.Add_Click({ $Lines.Clear() })
$FolderBtn.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$ReportDir`"" })
$CopyBtn.Add_Click({
    $txt = ($Lines | ForEach-Object { '[{0}] {1}' -f $_.T, $_.M }) -join "`r`n"
    if ($txt) { [System.Windows.Clipboard]::SetText($txt); $StatusText.Text = 'Konzola kopirana u clipboard.' }
})
$StopBtn.Add_Click({
    if ($script:Job) {
        Add-UiLog 'Prekidam zadatak... (komanda koja je vec pokrenuta, npr. SFC, moze se jos zavrsavati u pozadini)' 'warn'
        try { [void]$script:Job.PS.BeginStop($null, $null) } catch {}
    }
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(120)
$timer.Add_Tick({ Update-UI })

$window.Add_Loaded({
    try { [void][KT.Win]::ShowWindow([KT.Win]::GetConsoleWindow(), 0) } catch {}
    # Naslovna traka (minimize / zatvori) uvijek mora biti na ekranu
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        if ($window.ActualHeight -gt $wa.Height) { $window.Height = $wa.Height }
        if ($window.Top -lt $wa.Top -or ($window.Top + $window.ActualHeight) -gt $wa.Bottom) { $window.Top = $wa.Top + [math]::Max(0, ($wa.Height - $window.ActualHeight) / 2) }
        if ($window.Left -lt $wa.Left -or ($window.Left + $window.ActualWidth) -gt $wa.Right) { $window.Left = $wa.Left + [math]::Max(0, ($wa.Width - $window.ActualWidth) / 2) }
    } catch {}
    $timer.Start()
    Add-UiLog ('{0} Servis Toolkit v{1} pokrenut na {2}' -f $Firma, $Verzija, $env:COMPUTERNAME) 'head'
    Add-UiLog ('Izvjestaji: {0}' -f $ReportDir) 'dim'
    Initialize-Session
    Start-Dashboard
    # Ako je LibreHardwareMonitor ubacen u Alati, koristi ga odmah (i za traku uzivo)
    try {
        $alati = Join-Path $Root 'Alati'
        if (Get-ChildItem -Path $alati -Recurse -Include 'LibreHardwareMonitorLib.dll', 'LibreHardwareMonitor*.sln' -ErrorAction SilentlyContinue | Select-Object -First 1) { $sync.WantLhm = $true }
    } catch {}
    try { $script:SensorJob = New-Runner 'Start-SensorLoop' } catch {}
    if ($UpdateUrl) { try { $script:UpdJob = New-Runner 'Task-CheckUpdate -Silent $true' } catch {} }
})
$SensorBtn.Add_Click({ Invoke-Action 'sensors' })

$window.Add_Closing({
    param($sender, $e)
    if ($script:Job) {
        if (-not (Ask 'Zadatak je jos u toku. Zatvoriti program?')) { $e.Cancel = $true; return }
        try { [void]$script:Job.PS.BeginStop($null, $null) } catch {}
    }
    Save-Session
    $sync.StopStress  = $true
    $sync.StopSensors = $true
    if ($script:SensorJob) { try { [void]$script:SensorJob.Async.AsyncWaitHandle.WaitOne(3000) } catch {} }
    $timer.Stop()
})

[void]$window.ShowDialog()

# Ako je folder izvjestaja ostao prazan (samo log), ne brisi ga - log je koristan.
