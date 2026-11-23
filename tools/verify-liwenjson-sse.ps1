param(
  [Parameter(Mandatory)] [string] $ExternalCheckout,
  [string] $FixtureDirectory = (Join-Path $PSScriptRoot '../_build/differentiation')
)
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8
$original = (Resolve-Path -LiteralPath $ExternalCheckout).Path
if (Test-Path -LiteralPath (Join-Path $original 'code/moon.mod')) { $original = Join-Path $original 'code' }
$fixtureRoot = (Resolve-Path -LiteralPath $FixtureDirectory).Path
$inputFile = Join-Path $fixtureRoot '04-provider.sse'
$inputHash = (Get-FileHash -LiteralPath $inputFile -Algorithm SHA256).Hash.ToLowerInvariant()
$module = Get-Content -LiteralPath (Join-Path $original 'moon.mod') -Raw -Encoding utf8
if ($module -notmatch 'version = "1\.5\.3"') { throw 'Expected the pinned LIWENJSON 1.5.3 source checkout' }
if ((git hash-object --no-filters -- (Join-Path $original 'llm/llm.mbt')) -ne 'c5043e422fb01a0ba1d0b591834f10ed565d8547') { throw 'Expected the pinned upstream ToolStream source' }
if ((git hash-object --no-filters -- (Join-Path $original 'llm/sse.mbt')) -ne '576f8f0399ca9079acae5472397976d7d3b241d2') { throw 'Expected the pinned upstream SseBuffer source' }
if ((git hash-object --no-filters -- (Join-Path $original 'llm/openai.mbt')) -ne 'f8ff3ab97ff0c244d00a99fb73ec50a43dad9c96') { throw 'Expected the pinned upstream OpenAI adapter source' }

$work = Join-Path ([IO.Path]::GetTempPath()) ('liwenjson-provider-audit-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
foreach ($directory in @('', 'llm')) {
  $source = Join-Path $original $directory
  $destination = Join-Path $work $directory
  [void][IO.Directory]::CreateDirectory($destination)
  Get-ChildItem -LiteralPath $source -File | Where-Object {
    $_.Name -in @('moon.mod','moon.pkg','README.md') -or
    ($_.Name.EndsWith('.mbt') -and $_.Name -notmatch '_(wb)?test\.mbt$')
  } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $destination }
}
$harness = Join-Path $work 'same_input_probe'
[void][IO.Directory]::CreateDirectory($harness)
$package = 'import { "moonbitlang/core/json", "zhanshishan/liwenjson" @lj, "zhanshishan/liwenjson/llm", }' + [Environment]::NewLine + 'options("is-main": true)'
[IO.File]::WriteAllText((Join-Path $harness 'moon.pkg'), $package, [Text.UTF8Encoding]::new($false))
$contents = Get-Content -LiteralPath $inputFile -Raw -Encoding utf8
$moduleCode = @"
///|
fn main {
  let fixture_hash = "$inputHash"
  let raw = $(ConvertTo-Json -InputObject $contents -Compress)
  let options = @lj.Options::for_agent()
  let parser = @llm.ToolStream::new(@llm.OpenAICompat, options={ ..options, collect_deltas: true })
  let buffer = @llm.SseBuffer::new()
  let events = buffer.push(raw)
  events.append(buffer.flush())
  let errors : Array[Json] = []
  for i, event in events {
    if event != "[DONE]" {
      try {
        ignore(parser.push_event(event))
      } catch {
        e => {
          errors.push({"event":i + 1,"code":e.code(),"message":e.to_string()})
          break
        }
      }
    }
  }
  let calls : Array[Json] = []
  let final = if errors.is_empty() { parser.finish() } else { parser.views() }
  for call in final {
    calls.push({"id": call.id, "name": call.name, "end": call.end.name(), "executable": call.is_executable()})
  }
  let report : Json = {
    "version": @lj.VERSION,
    "fixture_sha256": fixture_hash,
    "events": events.length(),
    "ignored_events": parser.ignored_events(),
    "errors": errors,
    "calls": calls,
  }
  println(report.stringify())
}
"@
[IO.File]::WriteAllText((Join-Path $harness 'main.mbt'), $moduleCode, [Text.UTF8Encoding]::new($false))
Push-Location -LiteralPath $work
try {
  & moon run same_input_probe --target js --frozen
  if ($LASTEXITCODE -ne 0) { throw ('MoonBit runtime returned ' + $LASTEXITCODE) }
} finally {
  Pop-Location
}
