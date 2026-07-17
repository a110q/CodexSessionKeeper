$script:SessionSecurityMaxLineBytes = 32MB
$script:SessionSecurityUuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:SessionSecurityUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

function New-SessionSecurityException {
    param([string]$Code, [string]$Message)
    $exception = New-Object System.IO.InvalidDataException($Message)
    $exception.Data['Code'] = $Code
    return $exception
}

function Throw-InvalidSessionJsonl {
    param([string]$Path, [int]$LineNumber, [string]$Reason)
    throw (New-SessionSecurityException -Code 'INVALID_SESSION_JSONL' -Message "$Path line $LineNumber is invalid: $Reason")
}

function Throw-UntrustedSessionFile {
    param([string]$Path, [string]$Reason)
    throw (New-SessionSecurityException -Code 'UNTRUSTED_SESSION_FILE' -Message "$Path is not a trusted session file: $Reason")
}

function Normalize-SessionIdentity {
    param($Value)
    if (-not ($Value -is [string])) { return $null }
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.IndexOf([char]0) -ge 0) { return $null }
    if ($Value -match $script:SessionSecurityUuidPattern) { return $Value.ToLowerInvariant() }
    return $Value
}

function Get-ExactJsonProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Name -ceq $Name) { return $property }
    }
    return $null
}

function Get-NormalizedSessionIdentities {
    param([string[]]$SessionIds)
    $result = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($value in $SessionIds) {
        $identity = Normalize-SessionIdentity $value
        if ($null -ne $identity -and $seen.Add($identity)) { $result.Add($identity) | Out-Null }
    }
    return @($result)
}

function Get-SessionJsonlKindFromName {
    param([string]$Name)
    if ($Name -ceq 'session_index.jsonl') { return 'sessionIndex' }
    if ($Name -ceq 'history.jsonl.bak') { return 'historyBackup' }
    if ($Name -ceq 'history.jsonl') { return 'history' }
    throw "Unsupported session JSONL file: $Name"
}

function Get-SessionJsonlIdentity {
    param($Object, [string]$Kind, [string]$Path, [int]$LineNumber)
    if ($Kind -eq 'sessionIndex') { $expectedKey = 'id' } else { $expectedKey = 'session_id' }
    $property = Get-ExactJsonProperty -Object $Object -Name $expectedKey
    $identity = if ($property) { Normalize-SessionIdentity $property.Value } else { $null }
    if ($null -eq $identity) {
        Throw-InvalidSessionJsonl -Path $Path -LineNumber $LineNumber -Reason "missing valid top-level $expectedKey"
    }

    foreach ($alternateKey in @('id', 'session_id')) {
        if ($alternateKey -ceq $expectedKey) { continue }
        $alternateProperty = Get-ExactJsonProperty -Object $Object -Name $alternateKey
        if (-not $alternateProperty) { continue }
        $alternate = Normalize-SessionIdentity $alternateProperty.Value
        if ($null -ne $alternate -and $alternate -cne $identity) {
            Throw-InvalidSessionJsonl -Path $Path -LineNumber $LineNumber -Reason 'conflicting top-level session identity'
        }
    }
    return $identity
}

function Read-StrictJsonlLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Throw-InvalidSessionJsonl -Path $Path -LineNumber 1 -Reason 'file is missing or is not a regular file'
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-InvalidSessionJsonl -Path $Path -LineNumber 1 -Reason 'reparse points are not allowed'
    }

    $records = New-Object 'System.Collections.Generic.List[object]'
    $stream = New-Object System.IO.FileStream($item.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $reader = New-Object System.IO.StreamReader($stream, $script:SessionSecurityUtf8, $false, 1048576, $false)
    $lineNumber = 0
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineNumber++
            if ($line.Length -eq 0) {
                Throw-InvalidSessionJsonl -Path $Path -LineNumber $lineNumber -Reason 'internal blank lines are not allowed'
            }
            if ($script:SessionSecurityUtf8.GetByteCount($line) -gt $script:SessionSecurityMaxLineBytes) {
                Throw-InvalidSessionJsonl -Path $Path -LineNumber $lineNumber -Reason 'line exceeds 32 MiB'
            }
            try {
                $object = $line | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Throw-InvalidSessionJsonl -Path $Path -LineNumber $lineNumber -Reason 'invalid UTF-8 JSON'
            }
            if ($null -eq $object -or $object -is [string] -or $object -is [System.Array] -or $object.GetType().IsPrimitive) {
                Throw-InvalidSessionJsonl -Path $Path -LineNumber $lineNumber -Reason 'top-level JSON value must be an object'
            }
            $records.Add([pscustomobject]@{ Raw = $line; Object = $object; LineNumber = $lineNumber }) | Out-Null
        }
    } catch [System.Text.DecoderFallbackException] {
        Throw-InvalidSessionJsonl -Path $Path -LineNumber ($lineNumber + 1) -Reason 'invalid UTF-8 JSON'
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
    return @($records)
}

function Get-SessionFileFingerprint {
    param([string]$Path)
    $before = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($before.PSIsContainer -or (($before.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Throw-UntrustedSessionFile -Path $Path -Reason 'not a regular file'
    }
    $digest = (Get-FileHash -LiteralPath $before.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $after = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($before.Length -ne $after.Length -or
        $before.LastWriteTimeUtc.Ticks -ne $after.LastWriteTimeUtc.Ticks -or
        $before.CreationTimeUtc.Ticks -ne $after.CreationTimeUtc.Ticks) {
        Throw-InvalidSessionJsonl -Path $Path -LineNumber 1 -Reason 'file changed during validation'
    }
    return [pscustomobject]@{
        Path = $after.FullName
        Length = [int64]$after.Length
        LastWriteTicks = [int64]$after.LastWriteTimeUtc.Ticks
        CreationTicks = [int64]$after.CreationTimeUtc.Ticks
        Digest = $digest
    }
}

function Test-SessionFileFingerprint {
    param($Fingerprint)
    if ($null -eq $Fingerprint -or -not (Test-Path -LiteralPath $Fingerprint.Path -PathType Leaf)) { return $false }
    return (Test-SessionFileFingerprintAt -Fingerprint $Fingerprint -Path $Fingerprint.Path -RequireSamePath)
}

function Test-SessionFileFingerprintAt {
    param($Fingerprint, [string]$Path, [switch]$RequireSamePath)
    if ($null -eq $Fingerprint -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $current = Get-SessionFileFingerprint -Path $Path
        $samePath = (-not $RequireSamePath) -or ($current.Path -ceq $Fingerprint.Path)
        return $samePath -and
            $current.Length -eq $Fingerprint.Length -and
            $current.LastWriteTicks -eq $Fingerprint.LastWriteTicks -and
            $current.CreationTicks -eq $Fingerprint.CreationTicks -and
            $current.Digest -ceq $Fingerprint.Digest
    } catch { return $false }
}

function Read-SessionJsonlFile {
    param([string]$Path, [string]$Kind, [switch]$AllowMissing)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($AllowMissing) { return [pscustomobject]@{ Path = $Path; Records = @(); Fingerprint = $null } }
        Throw-InvalidSessionJsonl -Path $Path -LineNumber 1 -Reason 'file does not exist'
    }
    $records = @(Read-StrictJsonlLines -Path $Path)
    foreach ($record in $records) {
        $record | Add-Member -NotePropertyName SessionId -NotePropertyValue (Get-SessionJsonlIdentity -Object $record.Object -Kind $Kind -Path $Path -LineNumber $record.LineNumber)
    }
    return [pscustomobject]@{ Path = $Path; Records = $records; Fingerprint = (Get-SessionFileFingerprint -Path $Path) }
}

function Select-SessionJsonlRecords {
    param($Document, [string[]]$SessionIds)
    $selected = @(Get-NormalizedSessionIdentities -SessionIds $SessionIds)
    return @($Document.Records | Where-Object {
        $recordId = $_.SessionId
        @($selected | Where-Object { $_ -ceq $recordId }).Count -gt 0
    })
}

function Test-IsWindowsPlatform {
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Test-UnsafeWindowsPath {
    param([string]$Path)
    if (-not (Test-IsWindowsPlatform)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0) { return $true }
    if ($Path -match '^[\\/]{2}' -or $Path -match '^\\\\[?.]\\') { return $true }
    $withoutDrive = if ($Path -match '^[a-zA-Z]:') { $Path.Substring(2) } else { $Path }
    return $withoutDrive.Contains(':')
}

function Assert-NoReparsePointBetween {
    param([string]$Path, [string]$Root)
    $comparison = if (Test-IsWindowsPlatform) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $current = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $current) {
        if (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-UntrustedSessionFile -Path $Path -Reason "reparse point in path: $($current.FullName)"
        }
        if ($current.FullName.Equals($Root, $comparison)) { return }
        $current = $current.Parent
    }
    Throw-UntrustedSessionFile -Path $Path -Reason 'path escapes trusted root'
}

function Get-TrustedSessionRootPath {
    param([string]$Root)
    $item = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        Throw-UntrustedSessionFile -Path $Root -Reason 'trusted root is not a directory'
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-UntrustedSessionFile -Path $Root -Reason 'trusted root is a reparse point'
    }
    return $item.FullName.TrimEnd([char[]]@('\', '/'))
}

function Get-CanonicalPathWithin {
    param([string]$Path, [string]$Root)
    if (Test-UnsafeWindowsPath $Path) { Throw-UntrustedSessionFile -Path $Path -Reason 'UNC, device, or ADS paths are not allowed' }
    $rootPath = Get-TrustedSessionRootPath -Root $Root
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $comparison = if (Test-IsWindowsPlatform) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $prefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, $comparison)) {
        Throw-UntrustedSessionFile -Path $Path -Reason 'path escapes trusted root'
    }
    Assert-NoReparsePointBetween -Path $fullPath -Root $rootPath
    $canonical = (Resolve-Path -LiteralPath $fullPath -ErrorAction Stop).ProviderPath
    if (-not $canonical.StartsWith($prefix, $comparison)) {
        Throw-UntrustedSessionFile -Path $Path -Reason 'canonical path escapes trusted root'
    }
    return $canonical
}

function Get-TrustedRolloutCanonicalPath {
    param([string]$Path, [string]$CodexRoot)
    $canonicalRoot = Get-TrustedSessionRootPath -Root $CodexRoot
    $canonical = Get-CanonicalPathWithin -Path $Path -Root $CodexRoot
    $extension = [System.IO.Path]::GetExtension($canonical)
    if (-not $extension.Equals('.jsonl', [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-UntrustedSessionFile -Path $Path -Reason 'file extension is not .jsonl'
    }

    $allowed = $false
    foreach ($directoryName in @('sessions', 'archived_sessions')) {
        $base = [System.IO.Path]::Combine($canonicalRoot, $directoryName).TrimEnd([char[]]@('\', '/'))
        $comparison = if (Test-IsWindowsPlatform) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if ($canonical.StartsWith($base + [System.IO.Path]::DirectorySeparatorChar, $comparison)) { $allowed = $true; break }
    }
    if (-not $allowed) { Throw-UntrustedSessionFile -Path $Path -Reason 'file is outside sessions directories' }
    return $canonical
}

function Read-TrustedRolloutHeader {
    param([string]$Path, [string]$CodexRoot)
    $canonical = Get-TrustedRolloutCanonicalPath -Path $Path -CodexRoot $CodexRoot
    $stream = New-Object System.IO.FileStream($canonical, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $reader = New-Object System.IO.StreamReader($stream, $script:SessionSecurityUtf8, $false, 1048576, $false)
    try {
        $line = $reader.ReadLine()
    } catch [System.Text.DecoderFallbackException] {
        Throw-InvalidSessionJsonl -Path $canonical -LineNumber 1 -Reason 'invalid UTF-8 JSON'
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
    if ([string]::IsNullOrEmpty($line)) { Throw-UntrustedSessionFile -Path $Path -Reason 'file has no session_meta record' }
    if ($script:SessionSecurityUtf8.GetByteCount($line) -gt $script:SessionSecurityMaxLineBytes) {
        Throw-UntrustedSessionFile -Path $Path -Reason 'first line exceeds 32 MiB'
    }
    try { $first = $line | ConvertFrom-Json -ErrorAction Stop } catch {
        Throw-UntrustedSessionFile -Path $Path -Reason 'first record is not valid JSON'
    }

    $typeProperty = Get-ExactJsonProperty -Object $first -Name 'type'
    $payloadProperty = Get-ExactJsonProperty -Object $first -Name 'payload'
    if (-not $typeProperty -or $typeProperty.Value -cne 'session_meta' -or -not $payloadProperty) {
        Throw-UntrustedSessionFile -Path $Path -Reason 'first record is not session_meta'
    }
    $idProperty = Get-ExactJsonProperty -Object $payloadProperty.Value -Name 'id'
    $sessionId = if ($idProperty) { Normalize-SessionIdentity $idProperty.Value } else { $null }
    if ($null -eq $sessionId) { Throw-UntrustedSessionFile -Path $Path -Reason 'session_meta.payload.id is missing' }
    return [pscustomobject]@{ SessionId = $sessionId; Path = $canonical }
}

function Read-TrustedRolloutFile {
    param([string]$Path, [string]$CodexRoot, [string]$ExpectedSessionId)
    $header = Read-TrustedRolloutHeader -Path $Path -CodexRoot $CodexRoot
    $canonical = $header.Path
    $sessionId = $header.SessionId
    if ($ExpectedSessionId) {
        $expected = Normalize-SessionIdentity $ExpectedSessionId
        if ($sessionId -cne $expected) { Throw-UntrustedSessionFile -Path $Path -Reason 'session identity does not match' }
    }

    $before = Get-SessionFileFingerprint -Path $canonical
    $records = @(Read-StrictJsonlLines -Path $canonical)
    if ($records.Count -eq 0) { Throw-UntrustedSessionFile -Path $Path -Reason 'file has no session_meta record' }
    $firstObject = $records[0].Object
    $firstType = Get-ExactJsonProperty -Object $firstObject -Name 'type'
    $firstPayload = Get-ExactJsonProperty -Object $firstObject -Name 'payload'
    $firstId = if ($firstPayload) { Get-ExactJsonProperty -Object $firstPayload.Value -Name 'id' } else { $null }
    $verifiedSessionId = if ($firstId) { Normalize-SessionIdentity $firstId.Value } else { $null }
    if (-not $firstType -or $firstType.Value -cne 'session_meta' -or $verifiedSessionId -cne $sessionId) {
        Throw-UntrustedSessionFile -Path $Path -Reason 'session identity changed during validation'
    }
    $after = Get-SessionFileFingerprint -Path $canonical
    $unchanged = $before.Path -ceq $after.Path -and
        $before.Length -eq $after.Length -and
        $before.LastWriteTicks -eq $after.LastWriteTicks -and
        $before.CreationTicks -eq $after.CreationTicks -and
        $before.Digest -ceq $after.Digest
    if (-not $unchanged) {
        Throw-InvalidSessionJsonl -Path $canonical -LineNumber 1 -Reason 'file changed during validation'
    }

    $meta = [ordered]@{ cwd = ''; provider = 'unknown'; model = 'unknown'; source = 'jsonl'; title = '' }
    foreach ($record in @($records | Select-Object -First 120)) {
        $object = $record.Object
        if ($object.type -ceq 'session_meta' -and $object.payload) {
            if ($object.payload.cwd) { $meta.cwd = [string]$object.payload.cwd }
            if ($object.payload.model_provider) { $meta.provider = [string]$object.payload.model_provider }
            if ($object.payload.model) { $meta.model = [string]$object.payload.model }
            if ($object.payload.source) { $meta.source = [string]$object.payload.source }
        }
        if ($object.type -ceq 'event_msg' -and $object.payload -and $object.payload.type -ceq 'user_message' -and $object.payload.message) {
            $meta.title = [string]$object.payload.message
            break
        }
    }
    return [pscustomobject]@{
        SessionId = $sessionId
        Path = $canonical
        Fingerprint = $after
        Meta = [pscustomobject]$meta
    }
}

function Get-TrustedSessionFileIndex {
    param([string]$CodexRoot)
    Get-TrustedSessionRootPath -Root $CodexRoot | Out-Null
    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($directoryName in @('sessions', 'archived_sessions')) {
        $directory = [System.IO.Path]::Combine($CodexRoot, $directoryName)
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        foreach ($candidate in @(Get-ChildItem -LiteralPath $directory -Filter '*.jsonl' -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            try { $files.Add((Read-TrustedRolloutFile -Path $candidate.FullName -CodexRoot $CodexRoot)) | Out-Null } catch { }
        }
    }
    return @($files | Sort-Object Path)
}

function Resolve-TrustedSessionFiles {
    param([string[]]$SessionIds, [string]$CodexRoot)
    Get-TrustedSessionRootPath -Root $CodexRoot | Out-Null
    $selected = @(Get-NormalizedSessionIdentities -SessionIds $SessionIds)
    $files = New-Object 'System.Collections.Generic.List[object]'
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($sessionId in $selected) {
        $matches = @()
        foreach ($directoryName in @('sessions', 'archived_sessions')) {
            $directory = [System.IO.Path]::Combine($CodexRoot, $directoryName)
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
            foreach ($candidate in @(Get-ChildItem -LiteralPath $directory -Filter '*.jsonl' -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                try {
                    $header = Read-TrustedRolloutHeader -Path $candidate.FullName -CodexRoot $CodexRoot
                    if ($header.SessionId -ceq $sessionId) { $matches += $header }
                } catch { }
            }
        }
        if ($matches.Count -eq 0) { $missing.Add($sessionId) | Out-Null; continue }
        foreach ($match in $matches) { $files.Add((Read-TrustedRolloutFile -Path $match.Path -CodexRoot $CodexRoot -ExpectedSessionId $sessionId)) | Out-Null }
    }
    return [pscustomobject]@{ Files = @($files); MissingSessionIds = @($missing) }
}

function New-SessionJsonlPlan {
    param([object[]]$Operations)
    $dependencies = New-Object 'System.Collections.Generic.List[object]'
    $expectedMissing = New-Object 'System.Collections.Generic.List[string]'
    $outputs = New-Object 'System.Collections.Generic.List[object]'
    foreach ($operation in $Operations) {
        $source = Read-SessionJsonlFile -Path $operation.SourcePath -Kind $operation.Kind -AllowMissing:([bool]$operation.AllowMissingSource)
        if ($source.Fingerprint) { $dependencies.Add($source.Fingerprint) | Out-Null }
        if ($operation.DestinationPath -ceq $operation.SourcePath) {
            $destination = $source
        } else {
            $destination = Read-SessionJsonlFile -Path $operation.DestinationPath -Kind $operation.Kind -AllowMissing
            if ($destination.Fingerprint) { $dependencies.Add($destination.Fingerprint) | Out-Null }
            else { $expectedMissing.Add($operation.DestinationPath) | Out-Null }
        }
        $selected = @(Get-NormalizedSessionIdentities -SessionIds $operation.SessionIds)
        if ($operation.Mode -ceq 'delete') {
            $records = @($source.Records | Where-Object { $id = $_.SessionId; @($selected | Where-Object { $_ -ceq $id }).Count -eq 0 })
        } elseif ($operation.Mode -ceq 'filter') {
            $records = @(Select-SessionJsonlRecords -Document $source -SessionIds $selected)
        } elseif ($operation.Mode -ceq 'merge') {
            $records = New-Object 'System.Collections.Generic.List[object]'
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            foreach ($record in $destination.Records) {
                $records.Add($record) | Out-Null
                $key = if ($operation.Kind -ceq 'sessionIndex') { $record.SessionId } else { $record.Raw }
                $seen.Add($key) | Out-Null
            }
            foreach ($record in @(Select-SessionJsonlRecords -Document $source -SessionIds $selected)) {
                $key = if ($operation.Kind -ceq 'sessionIndex') { $record.SessionId } else { $record.Raw }
                if ($seen.Add($key)) { $records.Add($record) | Out-Null }
            }
            $records = @($records)
        } else { throw "Unsupported JSONL operation: $($operation.Mode)" }
        $data = if ($records.Count -gt 0) { (($records | ForEach-Object { $_.Raw }) -join "`n") + "`n" } else { '' }
        $outputs.Add([pscustomobject]@{ DestinationPath = $operation.DestinationPath; Data = $data }) | Out-Null
    }
    return [pscustomobject]@{ Dependencies = @($dependencies); ExpectedMissingPaths = @($expectedMissing); Outputs = @($outputs) }
}

function Assert-SessionPlanFresh {
    param([object[]]$Fingerprints, [string[]]$ExpectedMissingPaths, [string]$Phase)
    foreach ($fingerprint in $Fingerprints) {
        if (-not (Test-SessionFileFingerprint -Fingerprint $fingerprint)) {
            throw (New-SessionSecurityException -Code 'INVALID_SESSION_JSONL' -Message "Session file changed during $Phase: $($fingerprint.Path)")
        }
    }
    foreach ($path in $ExpectedMissingPaths) {
        if (Test-Path -LiteralPath $path) {
            throw (New-SessionSecurityException -Code 'INVALID_SESSION_JSONL' -Message "Session file appeared during $Phase: $path")
        }
    }
}

function New-SessionDeletionPlan {
    param([string[]]$SessionIds, [string]$CodexRoot)
    $trusted = Resolve-TrustedSessionFiles -SessionIds $SessionIds -CodexRoot $CodexRoot
    $operations = @()
    foreach ($name in @('history.jsonl', 'history.jsonl.bak', 'session_index.jsonl')) {
        $path = [System.IO.Path]::Combine($CodexRoot, $name)
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $operations += [pscustomobject]@{ Mode = 'delete'; Kind = (Get-SessionJsonlKindFromName $name); SourcePath = $path; DestinationPath = $path; SessionIds = $SessionIds }
    }
    return [pscustomobject]@{
        SessionIds = @($SessionIds)
        TrustedFiles = @($trusted.Files)
        MissingSessionIds = @($trusted.MissingSessionIds)
        JsonlPlan = (New-SessionJsonlPlan -Operations $operations)
    }
}

function New-SessionProtectionPlan {
    param([string[]]$SessionIds, [string]$CodexRoot)
    $trusted = Resolve-TrustedSessionFiles -SessionIds $SessionIds -CodexRoot $CodexRoot
    $operations = @()
    foreach ($name in @('history.jsonl', 'history.jsonl.bak', 'session_index.jsonl')) {
        $path = [System.IO.Path]::Combine($CodexRoot, $name)
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $operations += [pscustomobject]@{ Mode = 'filter'; Kind = (Get-SessionJsonlKindFromName $name); SourcePath = $path; DestinationPath = $path; SessionIds = $SessionIds }
    }
    return [pscustomobject]@{
        SessionIds = @(Get-NormalizedSessionIdentities -SessionIds $SessionIds)
        TrustedFiles = @($trusted.Files)
        MissingSessionIds = @($trusted.MissingSessionIds)
        JsonlPlan = (New-SessionJsonlPlan -Operations $operations)
    }
}

function Assert-SessionProtectionPlanFresh {
    param($Plan, [string]$Phase = 'protection snapshot')
    $fingerprints = @($Plan.TrustedFiles | ForEach-Object { $_.Fingerprint }) + @($Plan.JsonlPlan.Dependencies)
    Assert-SessionPlanFresh -Fingerprints $fingerprints -ExpectedMissingPaths @() -Phase $Phase
}

function Get-RelativeTrustedPath {
    param([string]$Root, [string]$Path)
    $canonicalRoot = Get-TrustedSessionRootPath -Root $Root
    $canonicalPath = Get-CanonicalPathWithin -Path $Path -Root $Root
    return $canonicalPath.Substring($canonicalRoot.Length).TrimStart([char[]]@('\', '/'))
}

function New-SessionRestorePlan {
    param([string[]]$SessionIds, [string]$SourceRoot, [string]$DestinationRoot, [switch]$Replace)
    $trusted = Resolve-TrustedSessionFiles -SessionIds $SessionIds -CodexRoot $SourceRoot
    if ($trusted.MissingSessionIds.Count -gt 0) {
        throw (New-SessionSecurityException -Code 'UNTRUSTED_SESSION_FILE' -Message "Snapshot is missing trusted rollout files: $($trusted.MissingSessionIds -join ', ')")
    }
    $rollouts = @()
    $expectedMissing = @()
    foreach ($file in $trusted.Files) {
        $relative = Get-RelativeTrustedPath -Root $SourceRoot -Path $file.Path
        $destination = [System.IO.Path]::Combine($DestinationRoot, $relative)
        $destinationFingerprint = $null
        if (Test-Path -LiteralPath $destination) {
            $destinationFingerprint = (Read-TrustedRolloutFile -Path $destination -CodexRoot $DestinationRoot -ExpectedSessionId $file.SessionId).Fingerprint
        } else { $expectedMissing += $destination }
        $rollouts += [pscustomobject]@{
            SessionId = $file.SessionId
            SourcePath = $file.Path
            SourceFingerprint = $file.Fingerprint
            DestinationPath = $destination
            DestinationFingerprint = $destinationFingerprint
        }
    }
    $operations = @()
    foreach ($name in @('history.jsonl', 'history.jsonl.bak', 'session_index.jsonl')) {
        $source = [System.IO.Path]::Combine($SourceRoot, $name)
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $operations += [pscustomobject]@{
            Mode = if ($Replace) { 'filter' } else { 'merge' }
            Kind = (Get-SessionJsonlKindFromName $name)
            SourcePath = $source
            DestinationPath = [System.IO.Path]::Combine($DestinationRoot, $name)
            SessionIds = $SessionIds
            AllowMissingSource = $false
        }
    }
    return [pscustomobject]@{
        SessionIds = @($SessionIds)
        Rollouts = $rollouts
        ExpectedMissingRollouts = $expectedMissing
        JsonlPlan = (New-SessionJsonlPlan -Operations $operations)
    }
}

function New-SessionTemporaryPath {
    param([string]$DestinationPath, [string]$Suffix)
    return [System.IO.Path]::Combine((Split-Path -Parent $DestinationPath), ('.' + (Split-Path -Leaf $DestinationPath) + '.' + $Suffix + '-' + [Guid]::NewGuid().ToString('N')))
}

function Write-SessionStagedText {
    param([string]$DestinationPath, [string]$Data, [switch]$MustRemainMissing)
    $directory = Split-Path -Parent $DestinationPath
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = New-SessionTemporaryPath -DestinationPath $DestinationPath -Suffix 'tmp'
    $bytes = $script:SessionSecurityUtf8.GetBytes($Data)
    $stream = New-Object System.IO.FileStream($temporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    return [pscustomobject]@{
        DestinationPath = $DestinationPath
        TemporaryPath = $temporary
        MustRemainMissing = [bool]$MustRemainMissing
    }
}

function Copy-SessionStagedFile {
    param([string]$SourcePath, [string]$DestinationPath, [string]$ExpectedDigest, [switch]$MustRemainMissing)
    $directory = Split-Path -Parent $DestinationPath
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = New-SessionTemporaryPath -DestinationPath $DestinationPath -Suffix 'tmp'
    $input = New-Object System.IO.FileStream($SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $output = New-Object System.IO.FileStream($temporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $input.CopyTo($output, 1048576); $output.Flush($true) } finally { $output.Dispose(); $input.Dispose() }
    $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $ExpectedDigest) { Remove-Item -LiteralPath $temporary -Force; throw (New-SessionSecurityException -Code 'INVALID_SESSION_JSONL' -Message "Staged rollout digest mismatch: $SourcePath") }
    return [pscustomobject]@{
        DestinationPath = $DestinationPath
        TemporaryPath = $temporary
        MustRemainMissing = [bool]$MustRemainMissing
    }
}

function Publish-SessionStagedFiles {
    param([object[]]$Staged)
    $published = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($entry in $Staged) {
            $backup = $null
            if ($entry.MustRemainMissing) {
                # File.Move is an atomic no-replace publication. A file created
                # after preflight makes this fail instead of being overwritten.
                [System.IO.File]::Move($entry.TemporaryPath, $entry.DestinationPath)
            } elseif (Test-Path -LiteralPath $entry.DestinationPath) {
                $backup = New-SessionTemporaryPath -DestinationPath $entry.DestinationPath -Suffix 'previous'
                [System.IO.File]::Replace($entry.TemporaryPath, $entry.DestinationPath, $backup, $true)
            } else {
                [System.IO.File]::Move($entry.TemporaryPath, $entry.DestinationPath)
            }
            $published.Add([pscustomobject]@{ DestinationPath = $entry.DestinationPath; BackupPath = $backup }) | Out-Null
        }
    } catch {
        for ($index = $published.Count - 1; $index -ge 0; $index--) {
            $entry = $published[$index]
            if ($entry.BackupPath -and (Test-Path -LiteralPath $entry.BackupPath)) {
                Remove-Item -LiteralPath $entry.DestinationPath -Force -ErrorAction SilentlyContinue
                [System.IO.File]::Move($entry.BackupPath, $entry.DestinationPath)
            } else { Remove-Item -LiteralPath $entry.DestinationPath -Force -ErrorAction SilentlyContinue }
        }
        throw
    } finally {
        foreach ($entry in $Staged) { Remove-Item -LiteralPath $entry.TemporaryPath -Force -ErrorAction SilentlyContinue }
    }
    foreach ($entry in $published) {
        if ($entry.BackupPath) { Remove-Item -LiteralPath $entry.BackupPath -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-SessionRestorePlan {
    param($Plan)
    $fingerprints = @($Plan.Rollouts | ForEach-Object { $_.SourceFingerprint; $_.DestinationFingerprint } | Where-Object { $null -ne $_ }) + @($Plan.JsonlPlan.Dependencies)
    $missing = @($Plan.ExpectedMissingRollouts) + @($Plan.JsonlPlan.ExpectedMissingPaths)
    Assert-SessionPlanFresh -Fingerprints $fingerprints -ExpectedMissingPaths $missing -Phase 'restore preflight'
    $staged = @()
    try {
        foreach ($rollout in $Plan.Rollouts) {
            $mustRemainMissing = @($missing | Where-Object { $_ -ceq $rollout.DestinationPath }).Count -gt 0
            $staged += Copy-SessionStagedFile `
                -SourcePath $rollout.SourcePath `
                -DestinationPath $rollout.DestinationPath `
                -ExpectedDigest $rollout.SourceFingerprint.Digest `
                -MustRemainMissing:$mustRemainMissing
        }
        foreach ($output in $Plan.JsonlPlan.Outputs) {
            $mustRemainMissing = @($missing | Where-Object { $_ -ceq $output.DestinationPath }).Count -gt 0
            $staged += Write-SessionStagedText `
                -DestinationPath $output.DestinationPath `
                -Data $output.Data `
                -MustRemainMissing:$mustRemainMissing
        }
        Assert-SessionPlanFresh -Fingerprints $fingerprints -ExpectedMissingPaths $missing -Phase 'restore commit'
        Publish-SessionStagedFiles -Staged $staged
    } catch {
        foreach ($entry in $staged) { Remove-Item -LiteralPath $entry.TemporaryPath -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Invoke-SessionDeletionPlan {
    param($Plan)
    $fingerprints = @($Plan.TrustedFiles | ForEach-Object { $_.Fingerprint }) + @($Plan.JsonlPlan.Dependencies)
    Assert-SessionPlanFresh -Fingerprints $fingerprints -ExpectedMissingPaths @() -Phase 'delete preflight'
    $staged = @()
    $quarantined = @()
    try {
        foreach ($output in $Plan.JsonlPlan.Outputs) { $staged += Write-SessionStagedText -DestinationPath $output.DestinationPath -Data $output.Data }
        Assert-SessionPlanFresh -Fingerprints $fingerprints -ExpectedMissingPaths @() -Phase 'delete commit'
        foreach ($file in $Plan.TrustedFiles) {
            $quarantine = New-SessionTemporaryPath -DestinationPath $file.Path -Suffix 'deleted'
            [System.IO.File]::Move($file.Path, $quarantine)
            $quarantined += [pscustomobject]@{ OriginalPath = $file.Path; QuarantinePath = $quarantine }
            if (-not (Test-SessionFileFingerprintAt -Fingerprint $file.Fingerprint -Path $quarantine)) {
                throw (New-SessionSecurityException -Code 'INVALID_SESSION_JSONL' -Message "Session file changed before deletion: $($file.Path)")
            }
        }
        Publish-SessionStagedFiles -Staged $staged
        foreach ($entry in $quarantined) { Remove-Item -LiteralPath $entry.QuarantinePath -Force -ErrorAction SilentlyContinue }
    } catch {
        for ($index = $quarantined.Count - 1; $index -ge 0; $index--) {
            $entry = $quarantined[$index]
            if (Test-Path -LiteralPath $entry.QuarantinePath) { [System.IO.File]::Move($entry.QuarantinePath, $entry.OriginalPath) }
        }
        foreach ($entry in $staged) { Remove-Item -LiteralPath $entry.TemporaryPath -Force -ErrorAction SilentlyContinue }
        throw
    }
    if ($Plan.MissingSessionIds.Count -gt 0) { return "Session file missing or not deleted; safe indexes only were cleaned: $($Plan.MissingSessionIds -join ', ')" }
    return ''
}
