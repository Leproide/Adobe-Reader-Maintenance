# Adobe-Reader-Maintenance.ps1
# Copyright (C) 2026 Leproide
# Author: https://github.com/Leproide
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: GPL-3.0-or-later

<#
.SYNOPSIS
    Datto RMM component - Manutenzione completa Adobe Acrobat Reader (PC e server RDS).
.DESCRIPTION
    0. Se TerminaAcrobat=true: chiude forzatamente Acrobat/Reader in tutte le sessioni (all'avvio e prima
       della reinstallazione). Il lavoro non salvato degli utenti va perso.
    1. Profili utente: svuota ConnectorIcons (bug Adobe: miniature mai eliminate) e le cache WebView2/AcroCef
       (queste ultime solo se l'utente non ha Acrobat ancora aperto).
    2. C:\ProgramData\Adobe\ARM: elimina cartelle Reader_*/Acrobat_* di versioni inferiori a quella installata
       (tutte solo se nessun Acrobat/Reader è presente, né registrato né su disco) e sottocartelle di ARM\S
       più vecchie di 30 giorni.
    3. MSI/MSP orfani di Adobe in C:\Windows\Installer: eliminati solo se non referenziati da alcun prodotto
       E identificati come Adobe Acrobat/Reader (Summary Information). Esclusi file modificati nelle ultime 24 ore.
    4. Cache MSI di Reader (patch referenziate): se oltre SogliaReinstallGB (o con ForceReinstall) -> disinstalla
       e reinstalla Reader (base MUI + aggiornamento scaricati da ardownload2.adobe.com, firma verificata PRIMA
       della disinstallazione). Solo Reader (x86 '7AD7' o x64 unificato con SCAPackageLevel=1), un solo prodotto,
       nessun Acrobat aperto, nessuna installazione MSI in corso, spazio libero minimo.
       Versione aggiornamento: VersioneReader se valorizzata, altrimenti rilevata da armmf.adobe.com
       (current_version.txt, percorso win e mac) con fallback su VersioneRiserva.
       Verifica firma: firma Authenticode valida, certificato di firma intestato ad Adobe e almeno un certificato
       della catena (intermedio/radice) con impronta presente nell'elenco autorizzato (FirmaMspThumb / FirmaBase*).
    Prodotti rilevati dalla registrazione di Windows Installer (Installer\UserData), non dalle voci Uninstall
    che possono essere danneggiate (nome/versione Uninstall usati solo come integrazione).
    URL pacchetti base e impronte iniziali ripresi dal component Datto "Adobe Acrobat/Reader installer" (uso interno Datto RMM).
.NOTES
    Author: https://github.com/Leproide
    License: GPL-3.0-or-later (vedi LICENSE)
    Modalità d'uso: standalone (PowerShell come amministratore), attività pianificata (SYSTEM) oppure
    component Datto RMM. Vedi README.md / README-ITALIAN.md.
    Configurazione: blocco CONFIGURAZIONE in cima (standalone / attività pianificata). Le variabili
    d'ambiente con lo stesso nome (es. variabili del component Datto) hanno la precedenza sui valori del blocco.
    Variabili component Datto:
      SogliaReinstallGB (String, 5) | Reinstalla (Boolean, true) | ForceReinstall (Boolean, false)
      VersioneReader (String, vuoto = automatico) | PulisciProfili (Boolean, true) | PulisciARM (Boolean, true)
      PulisciOrfani (Boolean, true) | UdfNumero (String, vuoto = nessuna scrittura UDF)
      FirmaMspThumb (String, impronte autorizzate separate da virgola) | TerminaAcrobat (Boolean, true)
      Facoltative (solo se cambiano i certificati degli installer base): FirmaBaseX86Thumb | FirmaBaseX64Thumb
    Exit code: 0 = OK / nulla da fare | 2 = reinstallazione necessaria ma non eseguita o anomalia da verificare | 1 = errore
    ATTENZIONE: cancellazioni definitive, chiusura forzata di Acrobat e reinstallazione automatica. Schedulare fuori orario.
    ForceReinstall: solo per test o interventi mirati, mai su job distribuiti.
#>

# ==================================================================================
# =============================== CONFIGURAZIONE ===================================
# Valori usati nei test manuali. Se il component Datto passa una variabile con lo
# stesso nome, il valore Datto sostituisce quello indicato qui.
# ==================================================================================

$SogliaReinstallGB = 5              # GB di cache MSI di Reader oltre cui reinstallare
$Reinstalla        = $true          # $false = solo segnalazione quando la cache supera la soglia
$ForceReinstall    = $false         # $true = reinstalla SEMPRE, a prescindere dalla soglia (solo test)
$TerminaAcrobat    = $true          # $true = chiude forzatamente Acrobat/Reader in tutte le sessioni (lavoro non salvato perso)
$VersioneReader    = ''             # '' = rilevamento automatico; es. '2600322110' per forzare una versione
$VersioneRiserva   = '2600322110'   # usata se il rilevamento automatico non trova versioni valide
$PulisciProfili    = $true          # ConnectorIcons e cache Acrobat nei profili utente
$PulisciARM        = $true          # C:\ProgramData\Adobe\ARM
$PulisciOrfani     = $true          # MSI/MSP orfani di Adobe in C:\Windows\Installer
$UdfNumero         = ''             # '' = non scrivere UDF; es. '10' per Custom10
$SpazioMinimoGB    = 3              # spazio libero minimo sul disco di sistema per reinstallare

# Impronte certificati autorizzati (intermedio o radice della catena), separate da virgola.
# Se Adobe cambia certificato: AGGIUNGERE la nuova impronta mostrata nello stdout, senza togliere le precedenti.
$FirmaMspThumb     = '7B0F360B775F76C94A12CA48445AA2D2A875701C'   # aggiornamenti MSP (DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1)
$FirmaBaseX86Thumb = 'F8D2C10380EDA2774655E5619DB7D02F7D9E850A'   # installer base x86 2015 (Symantec Class 3 EV Code Signing CA)
$FirmaBaseX64Thumb = '60EE3FC53D4BDFD1697AE5BEAE1CAB1C0F3AD4E3'   # installer base x64 2021 (DigiCert EV Code Signing CA)

# ==================================================================================

$ErrorActionPreference = 'Continue'
$script:exitCode = 0
$script:totLiberato = 0L

# Processi Acrobat/Reader (principali e di servizio) da considerare e, se richiesto, terminare
$script:acroProcs = @('Acrobat.exe','AcroRd32.exe','AcroCEF.exe','RdrCEF.exe','AcrobatInfo.exe','AcroBroker.exe',
                      'AcroTextExtractor.exe','AcroLayoutRecognizer.exe','AcroRd32Info.exe','AdobeCollabSync.exe',
                      'RdrServicesUpdater.exe')

# ================================ Funzioni generali ================================

function Out-Log([string]$Msg) { Write-Host $Msg }   # Write-Host: non inquina i valori di ritorno delle funzioni

function Set-Exit([int]$Code) {
    # 1 ha priorità su 2, 2 su 0
    if ($Code -eq 1) { $script:exitCode = 1 }
    elseif ($Code -eq 2 -and $script:exitCode -eq 0) { $script:exitCode = 2 }
}

function Get-BoolVar([string]$Name, [bool]$Default) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return ($v.Trim().ToLower() -eq 'true')
}

function Get-NumVar([string]$Name, [double]$Default) {
    $v = [Environment]::GetEnvironmentVariable($Name); $n = 0.0
    if ($v -and [double]::TryParse(($v -replace ',', '.'), [Globalization.NumberStyles]::Float,
                                   [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $n }
    return $Default
}

function Get-StrVar([string]$Name, [string]$Default) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function ConvertTo-ThumbList([string]$Text) {
    # "AA BB.., CC.." -> array di impronte normalizzate (maiuscolo, senza spazi)
    return @($Text -split '[,;]' | ForEach-Object { ($_ -replace '\s', '').ToUpper() } | Where-Object { $_ -match '^[0-9A-F]{40}$' })
}

function Get-RegValue([string]$Path, [string]$Name) {
    $k = $script:hklm.OpenSubKey($Path)
    if (-not $k) { return $null }
    $v = $k.GetValue($Name); $k.Close(); return $v
}

function Invoke-ReverseString([string]$s) { return -join ($s.ToCharArray()[($s.Length - 1)..0]) }

function ConvertTo-SquishedGuid([string]$Guid) {
    # {GUID} -> formato "squished" di Windows Installer
    $g = $Guid.Trim('{}').Replace('-', '')
    $o = (Invoke-ReverseString $g.Substring(0, 8)) + (Invoke-ReverseString $g.Substring(8, 4)) + (Invoke-ReverseString $g.Substring(12, 4))
    for ($i = 16; $i -lt 32; $i += 2) { $o += $g.Substring($i + 1, 1) + $g.Substring($i, 1) }
    return $o.ToUpper()
}

function ConvertFrom-SquishedGuid([string]$Sq) {
    # Formato "squished" -> {GUID} (operazione inversa)
    $a = Invoke-ReverseString $Sq.Substring(0, 8)
    $b = Invoke-ReverseString $Sq.Substring(8, 4)
    $c = Invoke-ReverseString $Sq.Substring(12, 4)
    $d = ''
    for ($i = 16; $i -lt 32; $i += 2) { $d += $Sq.Substring($i + 1, 1) + $Sq.Substring($i, 1) }
    return ('{{{0}-{1}-{2}-{3}-{4}}}' -f $a, $b, $c, $d.Substring(0, 4), $d.Substring(4)).ToUpper()
}

function Get-SystemTool([string]$Exe) {
    # Da processo 32 bit su OS 64 bit, sysnative punta al System32 reale
    $native = Join-Path "$env:WINDIR\sysnative" $Exe
    if (Test-Path $native) { return $native }
    return (Join-Path "$env:WINDIR\System32" $Exe)
}

function Test-MsiBusy {
    # Mutex globale di Windows Installer: presente durante un'installazione in corso
    $m = $null
    $busy = [System.Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [ref]$m)
    if ($m) { $m.Dispose() }
    return $busy
}

function Get-AcrobatBusySids {
    # SID degli utenti che hanno ancora processi Acrobat/Reader attivi
    $sids = @{}
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in $script:acroProcs } | ForEach-Object {
        $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue
        if ($o.Sid) { $sids[$o.Sid] = $true }
    }
    return $sids
}

function Stop-AcrobatProcesses([string]$Fase) {
    # Chiude forzatamente Acrobat/Reader in tutte le sessioni e registra quali utenti erano coinvolti
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in $script:acroProcs })
    if ($procs.Count -eq 0) { return }
    $utenti = @{}
    foreach ($p in $procs) {
        $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction SilentlyContinue
        if ($o.User) { $utenti["$($o.Domain)\$($o.User)"] = $true }
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    $resto = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in $script:acroProcs }).Count
    Out-Log ("[{0}] Chiusi forzatamente {1} processi Acrobat/Reader (utenti: {2}){3}" -f $Fase, $procs.Count,
             $(if ($utenti.Count) { $utenti.Keys -join ', ' } else { 'n/d' }),
             $(if ($resto) { " - ancora attivi: $resto" } else { '' }))
}

function Test-AdobeExePresent {
    # Eseguibili Acrobat/Reader su disco (indipendente dalla registrazione MSI)
    $pf   = [Environment]::GetEnvironmentVariable('ProgramW6432'); if (-not $pf) { $pf = $env:ProgramFiles }
    $pf86 = ${env:ProgramFiles(x86)}; if (-not $pf86) { $pf86 = $env:ProgramFiles }
    $paths = @(
        "$pf\Adobe\Acrobat DC\Acrobat\Acrobat.exe",
        "$pf86\Adobe\Acrobat DC\Acrobat\Acrobat.exe",
        "$pf86\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe",
        "$pf\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe"
    )
    foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Test-IsReparse([string]$Path) {
    $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return ($i -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint))
}

function Test-NoReparseInPath([string]$Base, [string]$Path) {
    # $true se nessun componente da $Base a $Path (inclusi) è un reparse point (junction/symlink).
    # Impedisce che un utente reindirizzi una cartella del proprio profilo verso percorsi di sistema
    # facendo cancellare file a SYSTEM.
    $b = $Base.TrimEnd('\')
    if (-not $Path.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (Test-IsReparse $b) { return $false }
    $cur = $b
    foreach ($seg in ($Path.Substring($b.Length) -split '\\' | Where-Object { $_ })) {
        $cur = Join-Path $cur $seg
        if (-not (Test-Path -LiteralPath $cur)) { return $true }   # niente da pulire più in basso
        if (Test-IsReparse $cur) { return $false }
    }
    return $true
}

function Clear-Folder {
    <# Svuota $Path senza attraversare reparse point. Con -Base verifica anche il percorso da Base a Path.
       Con -RemoveRoot elimina anche la cartella. #>
    param([string]$Path, [string]$Base, [switch]$RemoveRoot)
    $s = [pscustomobject]@{ Bytes = 0L; Cancellati = 0; InUso = 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $s }
    if ($Base -and -not (Test-NoReparseInPath $Base $Path)) {
        Out-Log "  Saltato (reparse point nel percorso): $Path"; return $s
    }
    if (Test-IsReparse $Path) { Out-Log "  Saltato (reparse point): $Path"; return $s }
    $dirs  = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        if (Test-IsReparse $cur) { continue }   # ricontrollo: la cartella potrebbe essere stata sostituita
        foreach ($i in Get-ChildItem -LiteralPath $cur -Force -ErrorAction SilentlyContinue) {
            if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($i.PSIsContainer) { $stack.Push($i.FullName); $dirs.Add($i.FullName); continue }
            try {
                $len = $i.Length
                Remove-Item -LiteralPath $i.FullName -Force -ErrorAction Stop
                $s.Bytes += $len; $s.Cancellati++
            } catch { $s.InUso++ }
        }
    }
    foreach ($d in ($dirs | Sort-Object { $_.Length } -Descending)) {
        if (-not (Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
        }
    }
    if ($RemoveRoot -and -not (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
    return $s
}

# ============================ Funzioni Windows Installer ============================

function Get-UninstallInfo([string]$Code) {
    # Nome/versione dalla voce Uninstall (solo integrazione: può essere incompleta o danneggiata)
    foreach ($up in 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                    'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        $k = $script:hklm.OpenSubKey("$up\$Code")
        if ($k) {
            $o = [pscustomobject]@{ Nome = [string]$k.GetValue('DisplayName'); Versione = [string]$k.GetValue('DisplayVersion') }
            $k.Close(); return $o
        }
    }
    return $null
}

function Get-AdobeProducts {
    # Prodotti Adobe Acrobat/Reader registrati in Windows Installer (Installer\UserData\<SID>\Products)
    $list = @(); $visti = @{}
    $ud = $script:hklm.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData')
    if (-not $ud) { return $list }
    foreach ($sid in $ud.GetSubKeyNames()) {
        $prods = $ud.OpenSubKey("$sid\Products")
        if (-not $prods) { continue }
        foreach ($sq in $prods.GetSubKeyNames()) {
            if ($sq.Length -ne 32 -or $visti.ContainsKey($sq)) { continue }
            $ip = $prods.OpenSubKey("$sq\InstallProperties")
            if (-not $ip) { continue }
            $code = ConvertFrom-SquishedGuid $sq
            $dn = [string]$ip.GetValue('DisplayName')
            $dv = [string]$ip.GetValue('DisplayVersion')
            $ip.Close()
            $ui = Get-UninstallInfo $code
            if (-not $dn -and $ui) { $dn = $ui.Nome }
            if (-not $dv -and $ui) { $dv = $ui.Versione }
            if ($dn -notmatch '^Adobe (Acrobat|Reader)' -or $dn -match 'installer|settings|fixes|font') { continue }
            $visti[$sq] = $true

            $ver = $null; [void][version]::TryParse($dv, [ref]$ver)
            $famiglia = 'Non riconosciuto'; $isReader = $false; $arch = $null
            if ($code -like '{AC76BA86-7AD7-*-7B44-AC0F074E4100}') {
                $famiglia = 'Reader x86'; $isReader = $true; $arch = 'x86'
            } elseif ($code -like '{AC76BA86-*-7760-BC15014EA700}') {
                # x64 unificato: Reader o Acrobat a seconda di SCAPackageLevel (1 = Reader)
                $arch = 'x64'
                $sca = Get-RegValue 'SOFTWARE\Adobe\Adobe Acrobat\DC\Installer' 'SCAPackageLevel'
                if ("$sca" -eq '1') { $famiglia = 'Reader x64'; $isReader = $true }
                else { $famiglia = "Acrobat x64 (SCAPackageLevel=$(if ($null -eq $sca) { 'assente' } else { $sca }))" }
            }
            $list += [pscustomobject]@{
                Nome = $dn; Versione = $ver; ProductCode = $code
                Famiglia = $famiglia; IsReader = $isReader; Arch = $arch; CacheGB = 0.0
                UninstallDanneggiata = (-not $ui -or -not $ui.Versione)
            }
        }
        $prods.Close()
    }
    return $list
}

function Get-InstallerRefs {
    # Refs: set dei LocalPackage referenziati | ProdFiles: squished product -> file (MSI + MSP)
    $refs = @{}; $prodFiles = @{}; $patchPath = @{}; $prodPatchCodes = @{}
    $ud = $script:hklm.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData')
    if (-not $ud) { return [pscustomobject]@{ Refs = $refs; ProdFiles = $prodFiles } }
    foreach ($sid in $ud.GetSubKeyNames()) {
        $patches = $ud.OpenSubKey("$sid\Patches")
        if ($patches) {
            foreach ($pc in $patches.GetSubKeyNames()) {
                $lp = $patches.OpenSubKey($pc).GetValue('LocalPackage')
                if ($lp) { $refs[$lp.ToLower()] = $true; $patchPath[$pc] = $lp }
            }
        }
        $products = $ud.OpenSubKey("$sid\Products")
        if ($products) {
            foreach ($prod in $products.GetSubKeyNames()) {
                if (-not $prodFiles.ContainsKey($prod)) { $prodFiles[$prod] = New-Object System.Collections.Generic.List[string] }
                $ip = $products.OpenSubKey("$prod\InstallProperties")
                if ($ip -and $ip.GetValue('LocalPackage')) {
                    $lp = $ip.GetValue('LocalPackage'); $refs[$lp.ToLower()] = $true; $prodFiles[$prod].Add($lp)
                }
                $pp = $products.OpenSubKey("$prod\Patches")
                if ($pp) { $prodPatchCodes[$prod] = $pp.GetSubKeyNames() }
            }
        }
    }
    foreach ($prod in $prodPatchCodes.Keys) {
        foreach ($pc in $prodPatchCodes[$prod]) { if ($patchPath.ContainsKey($pc)) { $prodFiles[$prod].Add($patchPath[$pc]) } }
    }
    return [pscustomobject]@{ Refs = $refs; ProdFiles = $prodFiles }
}

function Get-ProductCacheBytes([string]$ProductCode, $RefsInfo) {
    $sq = ConvertTo-SquishedGuid $ProductCode
    $bytes = 0L
    if ($RefsInfo.ProdFiles.ContainsKey($sq)) {
        foreach ($f in ($RefsInfo.ProdFiles[$sq] | Select-Object -Unique)) {
            if (Test-Path -LiteralPath $f) { $bytes += (Get-Item -LiteralPath $f -Force).Length }
        }
    }
    return $bytes
}

function Get-MsiSummaryText([string]$Path) {
    # Title (2), Subject (3), Author (4) del pacchetto MSI/MSP
    try {
        $si = $script:wi.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $script:wi, @($Path, 0))
        $t = foreach ($id in 2, 3, 4) { $si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @($id)) }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($si)
        return ($t -join ' | ')
    } catch { return '' }
}

# ============================ Rete, download e verifica firma ============================

function Get-DattoProxy {
    # Proxy configurato nell'agent Datto (stessa logica del component Datto)
    $cfg = if ([IntPtr]::Size -eq 4) { "$env:ProgramFiles\CentraStage\CagService.exe.config" }
           else { "${env:ProgramFiles(x86)}\CentraStage\CagService.exe.config" }
    try {
        [xml]$x = Get-Content $cfg -ErrorAction Stop
        $s = $x.configuration.applicationSettings.'CentraStage.Cag.Core.AppSettings'.setting
        $type = ($s | Where-Object { $_.Name -eq 'ProxyType' }).value
        $ip   = ($s | Where-Object { $_.Name -eq 'ProxyIp' }).value
        $port = ($s | Where-Object { $_.Name -eq 'ProxyPort' }).value
        if ([int]$type -gt 0 -and $ip -and $port) { return "$ip`:$port" }
    } catch {}
    return $null
}

function New-WebClientEx([bool]$ViaProxy) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
    if ($ViaProxy) { $wc.Proxy = New-Object System.Net.WebProxy($script:proxy, $true) }
    return $wc
}

function Get-WebString([string]$Url) {
    # Scarica un testo breve: prima via proxy (se configurato), poi diretto
    foreach ($viaProxy in $true, $false) {
        if ($viaProxy -and -not $script:proxy) { continue }
        try { return (New-WebClientEx $viaProxy).DownloadString($Url) } catch {}
    }
    return $null
}

function Invoke-Download([string]$Url, [string]$Dest) {
    # Scarica un file: prima via proxy (se configurato), poi diretto
    foreach ($viaProxy in $true, $false) {
        if ($viaProxy -and -not $script:proxy) { continue }
        try {
            Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
            (New-WebClientEx $viaProxy).DownloadFile($Url, $Dest)
            if (Test-Path -LiteralPath $Dest) { return $true }
        } catch {
            Out-Log ("  Download non riuscito{0}: {1}" -f $(if ($viaProxy) { ' via proxy' } else { '' }), $_.Exception.Message)
        }
    }
    return $false
}

function Get-ReaderVersionCandidates {
    # Versioni da provare (formato 10 cifre, es. 2600322110), in ordine di preferenza
    $c = New-Object System.Collections.Generic.List[string]
    if ($script:versioneForzata) {
        $c.Add($script:versioneForzata)
        return $c.ToArray()
    }
    foreach ($u in 'https://armmf.adobe.com/arm-manifests/win/AcrobatDC/reader/current_version.txt',
                   'https://armmf.adobe.com/arm-manifests/mac/AcrobatDC/reader/current_version.txt') {
        $t = Get-WebString $u
        if ($t -and $t.Trim() -match '^\d{2}\.\d{3}\.\d{5}$') {
            $v = $t.Trim().Replace('.', '')
            if (-not $c.Contains($v)) { $c.Add($v); Out-Log "  Versione rilevata da $u : $($t.Trim())" }
        }
    }
    if ($script:versioneRiserva -and -not $c.Contains($script:versioneRiserva)) { $c.Add($script:versioneRiserva) }
    return $c.ToArray()
}

function Get-MspUrls([string]$Arch, [string]$Ver) {
    # URL MSP di aggiornamento Reader da provare per architettura e versione
    if ($Arch -eq 'x86') {
        return @("https://ardownload2.adobe.com/pub/adobe/reader/win/AcrobatDC/$Ver/AcroRdrDCUpd${Ver}_MUI.msp")
    }
    return @("https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/$Ver/AcroRdrDCx64Upd${Ver}_MUI.msp",
             "https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/$Ver/AcroRdrDCx64Upd${Ver}.msp")
}

function Test-AdobeSignature([string]$File, [string[]]$Thumbprints, [string]$NomeVariabile) {
    # Restituisce $null se OK, altrimenti il motivo del rifiuto (con le impronte trovate, pronte da autorizzare)
    $sig = Get-AuthenticodeSignature -FilePath $File
    if ($sig.Status -ne 'Valid') { return "firma non valida ($($sig.Status))" }
    # Controllo sul campo Organizzazione (O=) e non su tutto il Subject
    if ($sig.SignerCertificate.Subject -notmatch '(^|,\s*)O="?Adobe[ ,"]') { return "certificato di firma non intestato ad Adobe ($($sig.SignerCertificate.Subject))" }

    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    [void]$chain.Build($sig.SignerCertificate)
    $catena = @($chain.ChainElements | ForEach-Object { $_.Certificate })
    $superiori = @($catena | Select-Object -Skip 1)   # escluso il certificato di firma: intermedi e radice
    foreach ($c in $superiori) { if ($Thumbprints -contains $c.Thumbprint.ToUpper()) { return $null } }

    # Nessuna impronta autorizzata: stampa la catena per poter aggiornare la variabile senza cercare altrove
    Out-Log "  Firma Adobe valida ma certificato intermedio non autorizzato. Catena trovata:"
    Out-Log "    Firma:      $($catena[0].Subject)"
    foreach ($c in $superiori) { Out-Log "    Superiore:  $($c.Subject)  ->  $($c.Thumbprint)" }
    if ($superiori.Count -gt 0) {
        Out-Log "  Per autorizzarla aggiungi a $NomeVariabile (separata da virgola): $($superiori[0].Thumbprint)"
    }
    return 'certificato intermedio non autorizzato'
}

function Show-LogTail([string]$Log) {
    if (Test-Path -LiteralPath $Log) {
        Out-Log "  Ultime righe di $Log :"
        Get-Content -LiteralPath $Log -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { Out-Log "    $_" }
    }
}

# ================================ Reinstallazione ================================

function Invoke-ReaderReinstall($P) {
    # Chiusura forzata (se abilitata), poi controlli preliminari: nessuna modifica al sistema se uno fallisce
    if ($script:terminaAcrobat) { Stop-AcrobatProcesses 'Reader' }
    if ((Get-AcrobatBusySids).Count -gt 0) { Out-Log '[Reader] Reinstallazione NON eseguita: Acrobat/Reader ancora in esecuzione.'; Set-Exit 2; return 'REINST rinviata: Acrobat aperto' }
    if (Test-MsiBusy)                      { Out-Log '[Reader] Reinstallazione NON eseguita: installazione MSI in corso.'; Set-Exit 2; return 'REINST rinviata: MSI in corso' }
    $free = (Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free
    if ($free -lt ($script:spazioMinimoGB * 1GB)) {
        Out-Log ("[Reader] Reinstallazione NON eseguita: spazio libero insufficiente ({0:N1} GB, servono {1} GB)." -f ($free / 1GB), $script:spazioMinimoGB)
        Set-Exit 2; return 'REINST rinviata: spazio insufficiente'
    }

    $src  = $script:basi[$P.Arch]
    # Cartella di lavoro con nome casuale e ACL ristretta (SYSTEM + Administrators): in C:\Windows\Temp
    # gli utenti possono creare cartelle, un nome fisso permetterebbe di pre-crearla e sostituire
    # l'installer dopo la verifica della firma (esecuzione come SYSTEM).
    $work = Join-Path $env:WINDIR ('Temp\AdobeReaderReinstall_' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sidStr in 'S-1-5-18', 'S-1-5-32-544') {
            $id = New-Object System.Security.Principal.SecurityIdentifier($sidStr)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl',
                'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        Set-Acl -LiteralPath $work -AclObject $acl -ErrorAction Stop
    } catch {
        Out-Log "[Reader] Impossibile preparare la cartella di lavoro: $($_.Exception.Message)"
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        Set-Exit 2; return 'REINST: cartella di lavoro non disponibile'
    }
    Out-Log "[Reader] Cartella di lavoro: $work"
    $base = Join-Path $work 'ReaderBase.exe'
    $msp  = Join-Path $work 'ReaderUpdate.msp'

    # --- Download e verifica PRIMA di disinstallare ---
    Out-Log "[Reader] Download installer base $($P.Arch) MUI..."
    if (-not (Invoke-Download $src.Base $base)) { Set-Exit 2; return 'REINST: download base fallito' }
    $err = Test-AdobeSignature $base $src.Thumbs $src.Variabile
    if ($err) { Out-Log "[Reader] Installer base rifiutato: $err"; Set-Exit 2; return 'REINST: firma base non autorizzata' }

    Out-Log '[Reader] Ricerca versione aggiornamento...'
    $verUsata = $null
    foreach ($v in (Get-ReaderVersionCandidates)) {
        if ($v -notmatch '^\d{10}$') { Out-Log "  Versione '$v' non valida, ignorata."; continue }
        foreach ($url in (Get-MspUrls $P.Arch $v)) {
            Out-Log "  Tentativo: $url"
            if (Invoke-Download $url $msp) { $verUsata = $v; break }
        }
        if ($verUsata) { break }
    }
    if (-not $verUsata) { Out-Log '[Reader] Nessun aggiornamento MSP disponibile: reinstallazione annullata.'; Set-Exit 2; return 'REINST: aggiornamento non trovato' }
    $err = Test-AdobeSignature $msp $script:mspThumbs 'FirmaMspThumb'
    if ($err) { Out-Log "[Reader] Aggiornamento rifiutato: $err"; Set-Exit 2; return 'REINST: firma aggiornamento non autorizzata (vedi stdout)' }
    Out-Log "[Reader] Pacchetti scaricati e firme verificate (aggiornamento $verUsata)."

    # Ultimo controllo: Acrobat potrebbe essere stato riaperto durante i download
    if ($script:terminaAcrobat) { Stop-AcrobatProcesses 'Reader' }
    if ((Get-AcrobatBusySids).Count -gt 0) { Out-Log '[Reader] Reinstallazione NON eseguita: Acrobat/Reader riaperto durante i download.'; Set-Exit 2; return 'REINST rinviata: Acrobat aperto' }

    # --- Da qui il sistema viene modificato ---
    $change = Get-SystemTool 'change.exe'
    $hasChange = Test-Path $change
    if ($hasChange) { & $change user /install | Out-Null }
    $riavvio = $false
    try {
        Out-Log "[Reader] Disinstallazione $($P.Nome) $($P.Versione) $($P.ProductCode)..."
        $logU = Join-Path $work 'uninstall.log'
        $u = Start-Process msiexec.exe -ArgumentList "/x $($P.ProductCode) /qn /norestart /L*v `"$logU`"" -Wait -PassThru
        if ($u.ExitCode -notin 0, 1605, 3010) {
            Out-Log "[Reader] Disinstallazione fallita (codice $($u.ExitCode)): Reader invariato."
            Show-LogTail $logU; Set-Exit 1
            return "REINST: disinstallazione fallita ($($u.ExitCode))"
        }
        if ($u.ExitCode -eq 3010) { $riavvio = $true }

        Out-Log '[Reader] Installazione base...'
        $logB = Join-Path $work 'install_base.log'
        $b = Start-Process $base -ArgumentList "/sAll /rs /msi EULA_ACCEPT=YES /L*v `"$logB`"" -Wait -PassThru
        if ($b.ExitCode -notin 0, 3010) {
            Out-Log "[Reader] ERRORE: Reader disinstallato ma installazione base fallita (codice $($b.ExitCode)). INTERVENTO MANUALE."
            Show-LogTail $logB; Set-Exit 1
            return "REINST ERRORE: base fallita ($($b.ExitCode)), Reader NON installato"
        }
        if ($b.ExitCode -eq 3010) { $riavvio = $true }

        Out-Log "[Reader] Applicazione aggiornamento $verUsata..."
        $logP = Join-Path $work 'install_update.log'
        $m = Start-Process msiexec.exe -ArgumentList "/p `"$msp`" /qn /norestart /L*v `"$logP`"" -Wait -PassThru
        if ($m.ExitCode -eq 3010) { $riavvio = $true }
        if ($m.ExitCode -notin 0, 3010) {
            Out-Log "[Reader] ATTENZIONE: aggiornamento non applicato (codice $($m.ExitCode)). Reader installato alla versione base."
            Show-LogTail $logP; Set-Exit 2
        }
    }
    finally {
        if ($hasChange) { & $change user /execute | Out-Null }
    }

    # --- Verifica finale ---
    $nuovo = @(Get-AdobeProducts | Where-Object { $_.IsReader })
    if ($nuovo.Count -eq 0) {
        Out-Log '[Reader] ERRORE: Reader non risulta installato dopo la reinstallazione. INTERVENTO MANUALE.'
        Set-Exit 1; return 'REINST ERRORE: Reader non rilevato'
    }
    $dopo = [math]::Round((Get-ProductCacheBytes $nuovo[0].ProductCode (Get-InstallerRefs)) / 1GB, 2)
    Out-Log ("[Reader] Reinstallazione OK: {0} {1} - cache MSI {2} GB -> {3} GB{4}" -f $nuovo[0].Nome, $nuovo[0].Versione, $P.CacheGB, $dopo,
             $(if ($riavvio) { ' - RIAVVIO RICHIESTO' } else { '' }))
    $script:totLiberato += [long][math]::Max(0, ($P.CacheGB - $dopo) * 1GB)
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    return ("REINST OK {0} {1}->{2}GB{3}" -f $nuovo[0].Versione, $P.CacheGB, $dopo, $(if ($riavvio) { ' riavvio' } else { '' }))
}

# ==================================== Esecuzione ====================================

try {
    # Valori del blocco CONFIGURAZIONE, sostituiti dalle variabili Datto se presenti
    $soglia                 = Get-NumVar  'SogliaReinstallGB' $SogliaReinstallGB
    $reinstalla             = Get-BoolVar 'Reinstalla'        $Reinstalla
    $forceReinstall         = Get-BoolVar 'ForceReinstall'    $ForceReinstall
    $script:terminaAcrobat  = Get-BoolVar 'TerminaAcrobat'    $TerminaAcrobat
    $pulisciProfili         = Get-BoolVar 'PulisciProfili'    $PulisciProfili
    $pulisciARM             = Get-BoolVar 'PulisciARM'        $PulisciARM
    $pulisciOrfani          = Get-BoolVar 'PulisciOrfani'     $PulisciOrfani
    $udfNumero              = Get-StrVar  'UdfNumero'         $UdfNumero
    $script:versioneForzata = Get-StrVar  'VersioneReader'    $VersioneReader
    $script:versioneRiserva = $VersioneRiserva
    $script:spazioMinimoGB  = $SpazioMinimoGB
    $script:mspThumbs       = ConvertTo-ThumbList (Get-StrVar 'FirmaMspThumb' $FirmaMspThumb)
    $baseX86Thumbs          = ConvertTo-ThumbList (Get-StrVar 'FirmaBaseX86Thumb' $FirmaBaseX86Thumb)
    $baseX64Thumbs          = ConvertTo-ThumbList (Get-StrVar 'FirmaBaseX64Thumb' $FirmaBaseX64Thumb)

    # Installer base Adobe (URL e impronte iniziali dal component Datto di installazione Reader)
    $script:basi = @{
        'x86' = @{
            Base      = 'https://ardownload2.adobe.com/pub/adobe/reader/win/AcrobatDC/1500720033/AcroRdrDC1500720033_MUI.exe'
            Thumbs    = $baseX86Thumbs
            Variabile = 'FirmaBaseX86Thumb'
        }
        'x64' = @{
            Base      = 'https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/2100720091/AcroRdrDCx642100720091_MUI.exe'
            Thumbs    = $baseX64Thumbs
            Variabile = 'FirmaBaseX64Thumb'
        }
    }

    $script:hklm  = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,
                                                               [Microsoft.Win32.RegistryView]::Registry64)
    $script:proxy = Get-DattoProxy
    $udf = New-Object System.Collections.Generic.List[string]

    Out-Log "=== Manutenzione Adobe Acrobat Reader - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm') ==="
    Out-Log ("Opzioni: Soglia={0} GB Reinstalla={1} ForceReinstall={2} TerminaAcrobat={3} Versione={4} Profili={5} ARM={6} Orfani={7} ImpronteMSP={8}" -f $soglia, $reinstalla, $forceReinstall, $script:terminaAcrobat,
             $(if ($script:versioneForzata) { $script:versioneForzata } else { 'automatica' }), $pulisciProfili, $pulisciARM, $pulisciOrfani, $script:mspThumbs.Count)
    if ($forceReinstall) { Out-Log '!!! ForceReinstall ATTIVO: Reader verra'' reinstallato indipendentemente dalla soglia !!!' }
    if ($script:mspThumbs.Count -eq 0) { Out-Log 'ATTENZIONE: FirmaMspThumb vuota o non valida: la reinstallazione verra'' rifiutata.' }

    # Chiusura forzata Acrobat/Reader in tutte le sessioni (se abilitata)
    if ($script:terminaAcrobat) { Stop-AcrobatProcesses 'Avvio' }

    # Rilevamento prodotti (registrazione Windows Installer) e controllo eseguibili su disco
    $prodotti = @(Get-AdobeProducts)
    $exeTrovato = Test-AdobeExePresent
    foreach ($p in ($prodotti | Where-Object { $_.UninstallDanneggiata })) {
        Out-Log "[Reader] NOTA: voce di disinstallazione di $($p.ProductCode) incompleta o assente (rilevato comunque tramite Windows Installer)."
    }
    $rilevamentoIncoerente = ($prodotti.Count -eq 0 -and $exeTrovato)
    if ($rilevamentoIncoerente) {
        Out-Log "[Reader] ATTENZIONE: trovato $exeTrovato ma nessun prodotto Acrobat/Reader registrato in Windows Installer."
        Set-Exit 2
    }

    # ---------------- 1. Profili utente ----------------
    if ($pulisciProfili) {
        $exclude = 'Public','Default','Default User','All Users'
        $connectorIcons = 'AppData\LocalLow\Adobe\Acrobat\DC\ConnectorIcons'
        $acrobatCache = @(
            'AppData\Local\Adobe\Acrobat\AVWebview2\DC\EBWebView\Default\Cache',
            'AppData\Local\Adobe\Acrobat\AVWebview2\DC\EBWebView\Default\Code Cache',
            'AppData\Local\Adobe\Acrobat\AVWebview2\DC\EBWebView\Default\GPUCache',
            'AppData\Local\Adobe\Acrobat\AVWebview2\DC\EBWebView\Default\Service Worker\CacheStorage',
            'AppData\Local\Adobe\Acrobat\AVWebview2\DC\EBWebView\Default\Service Worker\ScriptCache',
            'AppData\LocalLow\Adobe\AcroCef\DC\Acrobat\Cache\Cache',
            'AppData\LocalLow\Adobe\AcroCef\DC\Acrobat\Cache\Code Cache',
            'AppData\LocalLow\Adobe\AcroCef\DC\Acrobat\Cache\Service Worker\CacheStorage',
            'AppData\LocalLow\Adobe\AcroCef\DC\Acrobat\Cache\Service Worker\ScriptCache'
        )
        $profileSid = @{}
        Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special } |
            ForEach-Object { $profileSid[$_.LocalPath.ToLower()] = $_.SID }
        $busySids = Get-AcrobatBusySids

        $iconsBytes = 0L; $cacheBytes = 0L; $saltati = New-Object System.Collections.Generic.List[string]
        foreach ($pr in Get-ChildItem C:\Users -Directory -Force | Where-Object { $_.Name -notin $exclude }) {
            $sid = $profileSid[$pr.FullName.ToLower()]
            $iconsBytes += (Clear-Folder -Path (Join-Path $pr.FullName $connectorIcons) -Base $pr.FullName).Bytes
            if ($sid -and $busySids.ContainsKey($sid)) {
                $saltati.Add($pr.Name)
            } else {
                foreach ($rel in $acrobatCache) { $cacheBytes += (Clear-Folder -Path (Join-Path $pr.FullName $rel) -Base $pr.FullName).Bytes }
            }
        }
        Out-Log ("[Profili] ConnectorIcons {0:N2} GB - Cache Acrobat {1:N2} GB" -f ($iconsBytes / 1GB), ($cacheBytes / 1GB))
        if ($saltati.Count -gt 0) { Out-Log ("[Profili] Cache saltate (Acrobat ancora aperto): {0}" -f ($saltati -join ', ')) }
        $script:totLiberato += $iconsBytes + $cacheBytes
        $udf.Add(("Profili {0:N1}GB" -f (($iconsBytes + $cacheBytes) / 1GB)))
    }

    # ---------------- 2. C:\ProgramData\Adobe\ARM ----------------
    if ($pulisciARM) {
        $arm = Join-Path $env:ProgramData 'Adobe\ARM'
        if ($rilevamentoIncoerente) {
            Out-Log '[ARM] Saltato: Acrobat/Reader presente su disco ma non riconosciuto, versione di riferimento non determinabile.'
        }
        elseif (Test-Path -LiteralPath $arm) {
            $verRif = ($prodotti | Where-Object { $_.Versione } | Sort-Object Versione -Descending | Select-Object -First 1).Versione
            if ($prodotti.Count -gt 0 -and -not $verRif) {
                Out-Log '[ARM] Saltato: prodotto installato ma versione non leggibile.'
            } else {
                $armBytes = 0L; $armDir = 0
                foreach ($d in Get-ChildItem -LiteralPath $arm -Directory -Force -ErrorAction SilentlyContinue) {
                    if ($d.Name -match '^(Reader|Acrobat)_(\d+\.\d+\.\d+)') {
                        $v = $null
                        if ([version]::TryParse($Matches[2], [ref]$v) -and (-not $verRif -or $v -lt $verRif)) {
                            $armBytes += (Clear-Folder -Path $d.FullName -Base $env:ProgramData -RemoveRoot).Bytes; $armDir++
                        }
                    }
                }
                $armS = Join-Path $arm 'S'
                if (Test-Path -LiteralPath $armS) {
                    foreach ($d in Get-ChildItem -LiteralPath $armS -Directory -Force -ErrorAction SilentlyContinue |
                                   Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) }) {
                        $armBytes += (Clear-Folder -Path $d.FullName -Base $env:ProgramData -RemoveRoot).Bytes; $armDir++
                    }
                }
                Out-Log ("[ARM] Riferimento: {0} - rimosse {1} cartelle, {2:N2} GB" -f $(if ($verRif) { $verRif } else { 'nessun Acrobat/Reader presente (tutte)' }), $armDir, ($armBytes / 1GB))
                $script:totLiberato += $armBytes
                $udf.Add(("ARM {0:N1}GB" -f ($armBytes / 1GB)))
            }
        } else {
            Out-Log '[ARM] Cartella non presente.'
        }
    }

    # ---------------- 3. MSI/MSP orfani di Adobe ----------------
    if ($pulisciOrfani) {
        if (Test-MsiBusy) {
            Out-Log '[Orfani] Installazione MSI in corso: passaggio saltato.'
        } else {
            $refsInfo = Get-InstallerRefs
            $script:wi = New-Object -ComObject WindowsInstaller.Installer
            $limite = (Get-Date).AddHours(-24)
            $orfBytes = 0L; $orfCount = 0
            foreach ($f in Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'Installer') -File -Force -ErrorAction SilentlyContinue) {
                if ($f.Extension -notin '.msi', '.msp' -or $f.LastWriteTime -ge $limite) { continue }
                if ($refsInfo.Refs.ContainsKey($f.FullName.ToLower())) { continue }
                $info = Get-MsiSummaryText $f.FullName
                if ($info -match 'Adobe' -and $info -match 'Acrobat|Reader') {
                    try {
                        $len = $f.Length
                        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                        $orfBytes += $len; $orfCount++
                    } catch { Out-Log "[Orfani] Impossibile eliminare $($f.Name): $($_.Exception.Message)" }
                }
            }
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($script:wi)
            Out-Log ("[Orfani] Eliminati {0} pacchetti Adobe orfani, {1:N2} GB" -f $orfCount, ($orfBytes / 1GB))
            $script:totLiberato += $orfBytes
            $udf.Add(("Orfani {0:N1}GB" -f ($orfBytes / 1GB)))
        }
    }

    # ---------------- 4. Cache MSI di Reader / reinstallazione ----------------
    $refsInfo = Get-InstallerRefs
    foreach ($p in $prodotti) {
        $p.CacheGB = [math]::Round((Get-ProductCacheBytes $p.ProductCode $refsInfo) / 1GB, 2)
        Out-Log ("[Reader] {0} {1} [{2}] {3} - cache MSI {4} GB (soglia {5})" -f $p.Nome, $p.Versione, $p.Famiglia, $p.ProductCode, $p.CacheGB, $soglia)
    }

    if ($prodotti.Count -eq 0) {
        if ($rilevamentoIncoerente) {
            $udf.Add('Acrobat su disco ma non registrato: verificare')
        } else {
            Out-Log '[Reader] Nessun prodotto Adobe Acrobat/Reader installato.'
            $udf.Add('Reader assente')
        }
    }
    elseif ($prodotti.Count -gt 1) {
        Out-Log '[Reader] Piu'' prodotti Acrobat/Reader installati: reinstallazione automatica esclusa, verificare manualmente.'
        if ($forceReinstall -or @($prodotti | Where-Object { $_.CacheGB -ge $soglia }).Count -gt 0) { Set-Exit 2 }
        $udf.Add("Prodotti multipli, max cache $((($prodotti | Measure-Object CacheGB -Maximum).Maximum))GB")
    }
    else {
        $p = $prodotti[0]
        $udf.Add(("{0} {1} cache {2}GB" -f $p.Famiglia, $p.Versione, $p.CacheGB))
        if (-not $p.IsReader -and ($forceReinstall -or $p.CacheGB -ge $soglia)) {
            # Protezione mai disattivabile: Acrobat Standard/Pro o prodotto non riconosciuto
            Out-Log "[Reader] Il prodotto non e' Reader ($($p.Famiglia)): reinstallazione automatica esclusa, intervento manuale."
            Set-Exit 2; $udf.Add('REINST manuale (non Reader)')
        }
        elseif ($forceReinstall) {
            Out-Log '[Reader] ForceReinstall: reinstallazione indipendente dalla soglia.'
            $udf.Add((Invoke-ReaderReinstall $p))
        }
        elseif ($p.CacheGB -lt $soglia) {
            Out-Log '[Reader] Cache sotto soglia: nessuna reinstallazione.'
        }
        elseif (-not $reinstalla) {
            Out-Log '[Reader] Cache oltre soglia: reinstallazione consigliata (Reinstalla=false).'
            Set-Exit 2; $udf.Add('REINST consigliata')
        }
        else {
            $udf.Add((Invoke-ReaderReinstall $p))
        }
    }

    # ---------------- Riepilogo e UDF ----------------
    Out-Log ("=== Totale liberato (stima): {0:N2} GB - exit code {1} ===" -f ($script:totLiberato / 1GB), $script:exitCode)

    if ($udfNumero -match '^\d+$') {
        $testo = "$(Get-Date -Format 'yyyy-MM-dd') " + ($udf -join ' | ')
        if ($testo.Length -gt 255) { $testo = $testo.Substring(0, 255) }
        try {
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' -Name "Custom$udfNumero" -Value $testo -Type String -ErrorAction Stop
            Out-Log "UDF $udfNumero aggiornata: $testo"
        } catch { Out-Log "Impossibile scrivere la UDF $udfNumero : $($_.Exception.Message)" }
    }

    exit $script:exitCode
}
catch {
    Out-Log "ERRORE: $($_.Exception.Message)"
    exit 1
}