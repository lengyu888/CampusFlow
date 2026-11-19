$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Send-VoiceEvent([string]$Phase, [string]$Text = '') {
  [Console]::WriteLine((@{ phase = $Phase; text = $Text } | ConvertTo-Json -Compress))
}

$engine = $null
$reader = $null
$sourceIds = @('campusflow-voice-phrase', 'campusflow-voice-complete')
try {
  Add-Type -AssemblyName System.Speech
  $recognizers = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()
  $preferred = $recognizers | Where-Object { $_.Culture.Name -eq 'zh-CN' } | Select-Object -First 1
  if ($null -eq $preferred) {
    $preferred = $recognizers | Where-Object { $_.Culture.Name -eq [Globalization.CultureInfo]::CurrentUICulture.Name } | Select-Object -First 1
  }
  if ($null -eq $preferred) {
    Send-VoiceEvent 'unavailable'
    return
  }

  $engine = [System.Speech.Recognition.SpeechRecognitionEngine]::new($preferred)
  $engine.LoadGrammar([System.Speech.Recognition.DictationGrammar]::new())
  try { $engine.SetInputToDefaultAudioDevice() }
  catch {
    Send-VoiceEvent 'microphone'
    return
  }

  $reader = [IO.StreamReader]::new([Console]::OpenStandardInput())
  $command = $reader.ReadLineAsync()
  Register-ObjectEvent -InputObject $engine -EventName SpeechRecognized -SourceIdentifier $sourceIds[0] | Out-Null
  Register-ObjectEvent -InputObject $engine -EventName RecognizeCompleted -SourceIdentifier $sourceIds[1] | Out-Null
  $engine.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Multiple)
  Send-VoiceEvent 'listening'
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $stopAt = $null
  $textLength = 0
  do {
    foreach ($event in @(Get-Event)) {
      Remove-Event -EventIdentifier $event.EventIdentifier
      if ($event.SourceIdentifier -eq $sourceIds[1]) {
        if ($event.SourceEventArgs.Error) { Send-VoiceEvent 'failed' }
        else { Send-VoiceEvent 'complete' }
        return
      }
      if ($event.SourceIdentifier -ne $sourceIds[0]) { continue }
      $phrase = $event.SourceEventArgs.Result.Text
      if ($phrase -and $textLength -lt 4000) {
        $phrase = $phrase.Substring(0, [Math]::Min($phrase.Length, 4000 - $textLength))
        $textLength += $phrase.Length
        Send-VoiceEvent 'phrase' $phrase
      }
    }
    if ($null -eq $stopAt -and ($command.IsCompleted -or $clock.Elapsed.TotalSeconds -ge 60 -or $textLength -ge 4000)) {
      $engine.RecognizeAsyncStop()
      $stopAt = $clock.Elapsed.TotalSeconds + 3
    }
    Start-Sleep -Milliseconds 100
  } while ($null -eq $stopAt -or $clock.Elapsed.TotalSeconds -lt $stopAt)
  Send-VoiceEvent 'complete'
} catch {
  if ($null -eq $engine) { Send-VoiceEvent 'unavailable' }
  else { Send-VoiceEvent 'failed' }
} finally {
  foreach ($sourceId in $sourceIds) { Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue }
  if ($null -ne $engine) { $engine.Dispose() }
  if ($null -ne $reader) { $reader.Dispose() }
}
