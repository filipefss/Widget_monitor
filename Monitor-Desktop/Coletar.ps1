param($Previous)
$ErrorActionPreference = 'Stop'
$notes = New-Object 'Collections.Generic.List[string]'
$now = [DateTime]::UtcNow
$elapsed = 0.0
if ($Previous) { $elapsed = ($now - $Previous.Timestamp).TotalSeconds }
$cpu = $null; $ramUsed = $null; $ramTotal = $null; $uptime = '--'
try {
    $cpuRecord = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -OperationTimeoutSec 4
    if ($null -eq $cpuRecord -or $null -eq $cpuRecord.PercentProcessorTime) { throw 'Sem leitura de CPU' }
    $cpu = [double]$cpuRecord.PercentProcessorTime
} catch { $notes.Add('CPU: leitura indisponivel') }
try {
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 4
    $ramTotal = [double]$os.TotalVisibleMemorySize * 1024
    $ramUsed = $ramTotal - [double]$os.FreePhysicalMemory * 1024
    $up = (Get-Date) - $os.LastBootUpTime
    $uptime = '{0}d {1:00}h {2:00}m' -f $up.Days, $up.Hours, $up.Minutes
} catch { $notes.Add('RAM: leitura indisponivel') }
$processes = New-Object 'Collections.Generic.List[object]'
$processMap = @{}; $processNames = @{}
foreach ($proc in Get-Process) {
    try {
        $procId = [int]$proc.Id
        $name = $proc.ProcessName
        $path = 'Acesso restrito ou indisponivel'
        try { if ($proc.Path) { $path = $proc.Path } } catch { }
        $identity = $name
        try { $identity = $name + ':' + $proc.StartTime.ToUniversalTime().Ticks } catch { }
        $cpuSeconds = $null
        try { $cpuSeconds = $proc.TotalProcessorTime.TotalSeconds } catch { }
        $processMap[$procId] = @{ Identity = $identity; Seconds = $cpuSeconds }
        $processNames[$procId] = $name
        $usage = $null
        if ($elapsed -gt 0 -and $null -ne $cpuSeconds -and $Previous.Processes.ContainsKey($procId)) {
            $old = $Previous.Processes[$procId]
            if ($old.Identity -eq $identity -and $null -ne $old.Seconds) {
                $usage = [Math]::Round([Math]::Max(0, [Math]::Min(100, 100 * ($cpuSeconds - $old.Seconds) / $elapsed / [Environment]::ProcessorCount)), 1)
            }
        }
        $processes.Add([pscustomobject]@{ Name = $name; PID = $procId; CPU = $usage; RAM = [Math]::Round($proc.WorkingSet64 / 1048576, 1); Path = $path; Identity = $identity })
    } catch { }
}
$diskRates = @{}; $diskRead = $null; $diskWrite = $null
try {
    foreach ($row in Get-CimInstance Win32_PerfFormattedData_PerfDisk_LogicalDisk -OperationTimeoutSec 4) {
        $diskRates[$row.Name] = $row
        if ($row.Name -eq '_Total') { $diskRead = [double]$row.DiskReadBytesPersec; $diskWrite = [double]$row.DiskWriteBytesPersec }
    }
} catch { $notes.Add('Taxas de disco indisponiveis') }
$disks = New-Object 'Collections.Generic.List[object]'
foreach ($drive in [IO.DriveInfo]::GetDrives()) {
    if ($drive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable)) { continue }
    $letter = $drive.Name.TrimEnd('\')
    try {
        if (-not $drive.IsReady -or $drive.TotalSize -le 0) { continue }
        $free = [double]$drive.AvailableFreeSpace
        $total = [double]$drive.TotalSize
        $read = $null; $write = $null
        if ($diskRates.ContainsKey($letter)) { $read = [double]$diskRates[$letter].DiskReadBytesPersec; $write = [double]$diskRates[$letter].DiskWriteBytesPersec }
        $disks.Add([pscustomobject]@{ Name = $letter; Label = $drive.VolumeLabel; Free = $free; Total = $total; Used = 100 * (1 - $free / $total); Read = $read; Write = $write; Error = $false })
    } catch { $disks.Add([pscustomobject]@{ Name = $letter; Error = $true; Label = 'Indisponivel ou acesso negado' }) }
}
$network = New-Object 'Collections.Generic.List[object]'
$adapterMap = @{}; $received = $null; $sent = $null
try {
    $received = 0.0; $sent = 0.0; $hasRate = $false
    foreach ($adapter in Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up') {
        $stat = $adapter | Get-NetAdapterStatistics -ErrorAction Stop
        $key = [string]$adapter.InterfaceGuid
        $adapterMap[$key] = @{ Received = [double]$stat.ReceivedBytes; Sent = [double]$stat.SentBytes }
        $rx = $null; $tx = $null
        if ($elapsed -gt 0 -and $Previous.Adapters.ContainsKey($key)) {
            $old = $Previous.Adapters[$key]
            if ($stat.ReceivedBytes -ge $old.Received -and $stat.SentBytes -ge $old.Sent) {
                $rx = ([double]$stat.ReceivedBytes - $old.Received) / $elapsed
                $tx = ([double]$stat.SentBytes - $old.Sent) / $elapsed
                $received += $rx; $sent += $tx; $hasRate = $true
            }
        }
        $ips = @()
        try { $ips = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -ExpandProperty IPAddress) } catch { }
        $network.Add([pscustomobject]@{ Name = $adapter.Name; IP = ($ips -join ', '); Link = [string]$adapter.LinkSpeed; Download = $rx; Upload = $tx })
    }
    if (-not $hasRate -and $network.Count -gt 0) { $received = $null; $sent = $null }
} catch { $received = $null; $sent = $null; $notes.Add('Rede: acesso parcial ou indisponivel') }
$connections = New-Object 'Collections.Generic.List[object]'
try {
    foreach ($con in Get-NetTCPConnection -ErrorAction Stop) {
        $ownerId = [int]$con.OwningProcess
        $ownerName = 'Encerrado ou restrito'
        if ($processNames.ContainsKey($ownerId)) { $ownerName = $processNames[$ownerId] }
        $connections.Add([pscustomobject]@{ Name = $ownerName; PID = $ownerId; Protocol = 'TCP'; Local = ('[{0}]:{1}' -f $con.LocalAddress, $con.LocalPort); Remote = ('[{0}]:{1}' -f $con.RemoteAddress, $con.RemotePort); State = [string]$con.State })
    }
} catch { $notes.Add('Conexoes TCP: leitura parcial ou indisponivel') }
try {
    foreach ($con in Get-NetUDPEndpoint -ErrorAction Stop) {
        $ownerId = [int]$con.OwningProcess
        $ownerName = 'Encerrado ou restrito'
        if ($processNames.ContainsKey($ownerId)) { $ownerName = $processNames[$ownerId] }
        $connections.Add([pscustomobject]@{ Name = $ownerName; PID = $ownerId; Protocol = 'UDP'; Local = ('[{0}]:{1}' -f $con.LocalAddress, $con.LocalPort); Remote = '--'; State = 'Endpoint' })
    }
} catch { $notes.Add('Endpoints UDP: leitura parcial ou indisponivel') }
$services = @()
try {
    $services = @(Get-CimInstance Win32_Service -OperationTimeoutSec 4 | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Display = $_.DisplayName; PID = [int]$_.ProcessId; State = $_.State; Start = $_.StartMode; Path = $_.PathName } })
} catch { $notes.Add('Servicos indisponiveis') }
$gpuNames = '--'; $gpuUsage = $null; $gpuDedicated = $null; $gpuShared = $null
try { $gpuNames = ((Get-CimInstance Win32_VideoController -OperationTimeoutSec 4 | Select-Object -ExpandProperty Name) -join ' / ') } catch { }
try {
    $engines = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -OperationTimeoutSec 4)
    if ($engines.Count -gt 0) {
        $groups = @{}
        foreach ($engine in $engines) {
            $engineKey = $engine.Name -replace '^pid_\d+_', ''
            if (-not $groups.ContainsKey($engineKey)) { $groups[$engineKey] = 0.0 }
            $groups[$engineKey] += [double]$engine.UtilizationPercentage
        }
        $gpuUsage = [Math]::Min(100, ($groups.Values | Measure-Object -Maximum).Maximum)
    }
} catch { }
try {
    $gpuMemory = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -OperationTimeoutSec 4)
    if ($gpuMemory.Count -gt 0) {
        $gpuDedicated = [double]($gpuMemory | Measure-Object DedicatedUsage -Sum).Sum
        $gpuShared = [double]($gpuMemory | Measure-Object SharedUsage -Sum).Sum
    }
} catch { }
$sensors = New-Object 'Collections.Generic.List[object]'
foreach ($namespace in @('root\LibreHardwareMonitor', 'root\OpenHardwareMonitor')) {
    try {
        $hardwareNames = @{}
        foreach ($hardware in Get-CimInstance -Namespace $namespace -ClassName Hardware -OperationTimeoutSec 3) { $hardwareNames[$hardware.Identifier] = $hardware.Name }
        foreach ($sensor in Get-CimInstance -Namespace $namespace -ClassName Sensor -Filter "SensorType='Temperature'" -OperationTimeoutSec 3) {
            if ($null -eq $sensor.Value) { continue }
            $deviceName = [string]$sensor.Parent
            if ($hardwareNames.ContainsKey($sensor.Parent)) { $deviceName = $hardwareNames[$sensor.Parent] }
            $sensors.Add([pscustomobject]@{ Device = $deviceName; Name = $sensor.Name; Temperature = [Math]::Round([double]$sensor.Value, 1); Source = $namespace.Substring(5) })
        }
        if ($sensors.Count -gt 0) { break }
    } catch { }
}
if ($sensors.Count -eq 0) {
    try {
        foreach ($zone in Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -OperationTimeoutSec 3) {
            $temp = [double]$zone.CurrentTemperature / 10 - 273.15
            if ($temp -gt -20 -and $temp -lt 150) { $sensors.Add([pscustomobject]@{ Device = 'Zona ACPI (nao equivale a CPU)'; Name = $zone.InstanceName; Temperature = [Math]::Round($temp, 1); Source = 'Windows ACPI' }) }
        }
    } catch { }
}
[pscustomobject]@{
    Timestamp = $now; Finished = Get-Date; CPU = $cpu; RamUsed = $ramUsed; RamTotal = $ramTotal; Uptime = $uptime
    Processes = $processes.ToArray(); Disks = $disks.ToArray(); Network = $network.ToArray(); Download = $received; Upload = $sent
    DiskRead = $diskRead; DiskWrite = $diskWrite
    Connections = $connections.ToArray(); Services = $services; GPUName = $gpuNames; GPU = $gpuUsage; GPUDedicated = $gpuDedicated; GPUShared = $gpuShared
    Sensors = $sensors.ToArray(); Notes = ($notes -join ' | ')
    Next = @{ Timestamp = $now; Processes = $processMap; Adapters = $adapterMap }
}
