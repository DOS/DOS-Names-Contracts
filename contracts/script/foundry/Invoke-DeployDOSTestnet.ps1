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
$expectedDeployer = "0x99999e454138f6be73e2be82c890bc5765749999"
$expectedOwner = "0x310bc061214ee89af5cfb28a6ebf96c5436fa3cd"
$minimumBalanceWei = [System.Numerics.BigInteger]::Parse("1000000000000000000")

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
if ([string]::IsNullOrWhiteSpace($env:PRIVATE_KEY)) {
    throw "PRIVATE_KEY is required"
}
if ([string]::IsNullOrWhiteSpace($env:OWNER)) {
    throw "OWNER is required"
}

$privateKey = $env:PRIVATE_KEY.Trim()
if ($privateKey -match "^[0-9a-fA-F]{64}$") {
    $privateKey = "0x$privateKey"
}
if ($privateKey -notmatch "^0x[0-9a-fA-F]{64}$") {
    throw "PRIVATE_KEY must be a 32-byte hexadecimal value"
}
$env:PRIVATE_KEY = $privateKey

$owner = $env:OWNER.Trim().ToLowerInvariant()
$beneficiary = if ([string]::IsNullOrWhiteSpace($env:BENEFICIARY)) {
    $env:OWNER
} else {
    $env:BENEFICIARY
}
$beneficiary = $beneficiary.Trim().ToLowerInvariant()
if ($owner -ne $expectedOwner) {
    throw "OWNER does not match the canonical DOS Names owner"
}
if ($beneficiary -ne $expectedOwner) {
    throw "BENEFICIARY does not match the canonical DOS Names beneficiary"
}
$env:BENEFICIARY = $beneficiary

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

$balanceOutput = & $cast balance $expectedDeployer --rpc-url $RpcUrl
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($balanceOutput)) {
    throw "Unable to read the canonical deployer balance"
}
$balance = [System.Numerics.BigInteger]::Parse($balanceOutput.Trim())
if ($balance -lt $minimumBalanceWei) {
    throw "Canonical deployer balance is below the 1 DOS deployment floor"
}

$contractsRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Push-Location $contractsRoot
try {
    & $forge script "script/foundry/DeployDOSTestnet.s.sol:DeployDOSTestnet" `
        --rpc-url $RpcUrl `
        --slow
    if ($LASTEXITCODE -ne 0) {
        throw "Foundry simulation failed"
    }

    if (-not $Broadcast) {
        Write-Output "DOS_TESTNET_ENSV2_SIMULATION_OK"
        return
    }

    & $forge script "script/foundry/DeployDOSTestnet.s.sol:DeployDOSTestnet" `
        --rpc-url $RpcUrl `
        --broadcast `
        --slow
    if ($LASTEXITCODE -ne 0) {
        throw "Foundry broadcast failed"
    }
    Write-Output "DOS_TESTNET_ENSV2_BROADCAST_OK"
}
finally {
    Pop-Location
}
