$script:Failures = 0

function Assert-Eq {
    param([string]$Name, $Actual, $Expected)
    if ($Actual -ceq $Expected) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        Write-Host "     expected: [$Expected]"
        Write-Host "     actual:   [$Actual]"
        $script:Failures++
    }
}

function Assert-True {
    param([string]$Name, $Cond)
    if ($Cond) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        $script:Failures++
    }
}
