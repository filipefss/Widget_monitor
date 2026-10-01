param([string[]]$Urls)
$ErrorActionPreference = 'Stop'
foreach ($url in $Urls) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $status = '--'; $tone = 'Warning'; $detail = ''; $finalUrl = $url; $response = $null
    try {
        $uri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) { throw 'URL invalida. Use http:// ou https://.' }
        $request = [Net.HttpWebRequest]::Create($uri)
        $request.Method = 'GET'
        $request.UserAgent = 'MonitorDesktop/1.0'
        $request.Timeout = 7000
        $request.ReadWriteTimeout = 7000
        $request.AllowAutoRedirect = $true
        $request.MaximumAutomaticRedirections = 5
        $request.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::BypassCache)
        try { $response = $request.GetResponse() }
        catch [Net.WebException] {
            if ($null -ne $_.Exception.Response) { $response = $_.Exception.Response }
            else { throw }
        }
        $status = [string][int]$response.StatusCode
        $finalUrl = [string]$response.ResponseUri
        $detail = [string]$response.StatusDescription
        if ($status -eq '200') { $tone = 'Healthy' }
        elseif ($status -eq '404') { $tone = 'Critical' }
    } catch { $detail = $_.Exception.Message }
    finally { if ($null -ne $response) { $response.Close() }; $clock.Stop() }
    [pscustomobject]@{ Url = $url; Status = $status; Milliseconds = $clock.ElapsedMilliseconds; Checked = (Get-Date -Format 'dd/MM HH:mm:ss'); Tone = $tone; Detail = $detail; Final = $finalUrl }
}
