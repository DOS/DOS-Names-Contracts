[CmdletBinding()]
param(
    [string]$RpcUrl = "https://test.doschain.com",
    [switch]$Broadcast
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$expectedRpcUrl = "https://test.doschain.com"
$expectedChainId = 3939
$expectedGenesisHash = "0x36f98b2e8b3084d57efc46622a065c2a96ed51aca86ac229bce998be6b8abd2c"
$expectedOwner = "0x99999e454138f6be73e2be82c890bc5765749999"
$minimumBalanceWei = [System.Numerics.BigInteger]::Parse("1000000000000000000")
$requiredEnvironmentVariables = @(
    "PRIVATE_KEY",
    "DOS_DOMAIN_VOUCHER_SIGNER",
    "DOS_DOMAIN_REGISTRY",
    "DOS_DOMAIN_PRICE_ORACLE",
    "DOS_DOMAIN_LEGACY_REGISTRAR"
)

function Resolve-FoundryCommand {
    param([Parameter(Mandatory)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $bundled = Join-Path $env:USERPROFILE ".foundry\bin\$Name.exe"
    if (Test-Path -LiteralPath $bundled) {
        return $bundled
    }

    throw "$Name was not found in PATH or the Foundry installation directory"
}

if ($RpcUrl.TrimEnd("/") -ne $expectedRpcUrl) {
    throw "RPC URL must be $expectedRpcUrl"
}

foreach ($name in $requiredEnvironmentVariables) {
    $environmentItem = Get-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    if ($null -eq $environmentItem -or [string]::IsNullOrWhiteSpace($environmentItem.Value)) {
        throw "$name is required"
    }
}

$privateKey = $env:PRIVATE_KEY.Trim()
if ($privateKey -match "^[0-9a-fA-F]{64}$") {
    $privateKey = "0x$privateKey"
}
if ($privateKey -notmatch "^0x[0-9a-fA-F]{64}$") {
    throw "PRIVATE_KEY must be a 32-byte hexadecimal value"
}
$env:PRIVATE_KEY = $privateKey

$cast = Resolve-FoundryCommand -Name "cast"
$forge = Resolve-FoundryCommand -Name "forge"

$chainId = [int]((& $cast chain-id --rpc-url $RpcUrl).Trim())
if ($LASTEXITCODE -ne 0 -or $chainId -ne $expectedChainId) {
    throw "RPC chain ID does not match DOS Testnet"
}

$genesis = (& $cast block 0 --rpc-url $RpcUrl --json | ConvertFrom-Json).hash.ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $genesis -ne $expectedGenesisHash) {
    throw "RPC genesis hash does not match DOS Testnet"
}

$balanceOutput = & $cast balance $expectedOwner --rpc-url $RpcUrl
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($balanceOutput)) {
    throw "Unable to read the canonical owner balance"
}
$balance = [System.Numerics.BigInteger]::Parse($balanceOutput.Trim())
if ($balance -lt $minimumBalanceWei) {
    throw "Canonical owner balance is below the 1 DOS deployment floor"
}

$contractsRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Push-Location $contractsRoot
try {
    & $forge script "script/foundry/DeployDOSDomainPolicyTestnet.s.sol:DeployDOSDomainPolicyTestnet" `
        --rpc-url $RpcUrl `
        --slow
    if ($LASTEXITCODE -ne 0) {
        throw "Foundry simulation failed"
    }

    if (-not $Broadcast) {
        Write-Output "DOS_TESTNET_DOMAIN_POLICY_SIMULATION_OK"
        return
    }

    & $forge script "script/foundry/DeployDOSDomainPolicyTestnet.s.sol:DeployDOSDomainPolicyTestnet" `
        --rpc-url $RpcUrl `
        --broadcast `
        --slow
    if ($LASTEXITCODE -ne 0) {
        throw "Foundry broadcast failed"
    }
    Write-Output "DOS_TESTNET_DOMAIN_POLICY_BROADCAST_OK"
}
finally {
    Pop-Location
}
