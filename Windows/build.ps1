$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
python -m pip install -r requirements-build.txt
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
python -m PyInstaller --noconfirm --clean --windowed --onedir --name 'Withings Health Bridge' --icon assets/AppIcon.ico --add-data 'assets;assets' --copy-metadata pycryptodome main.py
if ($LASTEXITCODE -ne 0) { throw 'Windows packaging failed.' }
Copy-Item README.md 'dist/Withings Health Bridge/README.txt'
Copy-Item THIRD-PARTY-NOTICES.md 'dist/Withings Health Bridge/THIRD-PARTY-NOTICES.txt'
Copy-Item ../LICENSE 'dist/Withings Health Bridge/LICENSE.txt'
python tools/copy-licenses.py 'dist/Withings Health Bridge'
if ($LASTEXITCODE -ne 0) { throw 'License collection failed.' }
$smokeResult = Join-Path $env:TEMP ('bridge-smoke-' + [guid]::NewGuid().ToString() + '.txt')
$application = Resolve-Path 'dist/Withings Health Bridge/Withings Health Bridge.exe'
$process = Start-Process -FilePath $application -ArgumentList @('--smoke-test', ('"' + $smokeResult + '"')) -Wait -PassThru
if ($process.ExitCode -ne 0 -or -not (Test-Path $smokeResult)) { throw 'Packaged Windows UI smoke test failed.' }
Get-Content $smokeResult
Remove-Item $smokeResult
Compress-Archive -Path 'dist/Withings Health Bridge' -DestinationPath 'dist/WithingsHealthBridge-Windows-0.1.0-x64.zip' -Force
Write-Host 'Built dist/WithingsHealthBridge-Windows-0.1.0-x64.zip'
