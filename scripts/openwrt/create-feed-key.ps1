$ErrorActionPreference = 'Stop'

$opensslCommand = Get-Command openssl -ErrorAction Stop
$openssl = $opensslCommand.Source
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$keyDirectory = Join-Path $env:USERPROFILE '.z2k-signing'
$privateKey = Join-Path $keyDirectory 'z2k-feed.key'
$publicKey = Join-Path $repoRoot 'package/openwrt/keys/z2k-feed.pem'
$workDirectory = Join-Path $env:TEMP ("z2k-feed-key-" + [guid]::NewGuid().ToString('N'))

New-Item -ItemType Directory -Path $keyDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $publicKey) -Force | Out-Null
New-Item -ItemType Directory -Path $workDirectory | Out-Null

try {
    if (-not (Test-Path -LiteralPath $privateKey)) {
        & $openssl ecparam -name prime256v1 -genkey -noout -out $privateKey
        if ($LASTEXITCODE -ne 0) { throw 'OpenSSL could not generate the P-256 private key.' }
    }
    if ((Get-Item -LiteralPath $privateKey).PSIsContainer) {
        throw "Private key path is not a file: $privateKey"
    }
    $account = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    & icacls $privateKey /inheritance:r /grant:r ('{0}:(F)' -f $account) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict private key ACL to the current Windows account.' }

    $candidatePublic = Join-Path $workDirectory 'z2k-feed.pem'
    $candidateDer = Join-Path $workDirectory 'candidate.der'
    & $openssl pkey -in $privateKey -pubout -out $candidatePublic
    if ($LASTEXITCODE -ne 0) { throw 'Existing private key is invalid or unreadable.' }
    & $openssl pkey -pubin -in $candidatePublic -outform DER -out $candidateDer
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSL could not encode the generated public key.' }

    $curveInfo = (& $openssl pkey -pubin -in $candidatePublic -text -noout 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $curveInfo -notmatch 'prime256v1|P-256') {
        throw 'Feed key must use the P-256 (prime256v1) curve.'
    }

    if (Test-Path -LiteralPath $publicKey) {
        $existingDer = Join-Path $workDirectory 'existing.der'
        & $openssl pkey -pubin -in $publicKey -outform DER -out $existingDer
        if ($LASTEXITCODE -ne 0) { throw 'Existing public key is invalid.' }
        $candidateHash = (Get-FileHash -LiteralPath $candidateDer -Algorithm SHA256).Hash
        $existingHash = (Get-FileHash -LiteralPath $existingDer -Algorithm SHA256).Hash
        if ($candidateHash -ne $existingHash) {
            throw 'Public key already exists and does not match the offline private key; refusing key rotation.'
        }
    }
    else {
        Move-Item -LiteralPath $candidatePublic -Destination $publicKey
    }

    $publishedDer = Join-Path $workDirectory 'published.der'
    & $openssl pkey -pubin -in $publicKey -outform DER -out $publishedDer
    if ($LASTEXITCODE -ne 0) { throw 'Could not verify the public key written to the repository.' }
    $fingerprint = (Get-FileHash -LiteralPath $publishedDer -Algorithm SHA256).Hash.ToLowerInvariant()
    $keyFileFingerprint = (Get-FileHash -LiteralPath $publicKey -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output "public_key=$publicKey"
    Write-Output "private_key=$privateKey"
    Write-Output "spki_sha256=$fingerprint"
    Write-Output "key_file_sha256=$keyFileFingerprint"
    Write-Output 'Keep the private key offline and outside the repository. Commit only z2k-feed.pem.'
}
finally {
    Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
