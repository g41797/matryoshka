@echo off
setlocal enabledelayedexpansion

set OPTS=none minimal size speed aggressive

echo Starting odin-mbox local CI (Windows)...

for %%o in (%OPTS%) do (
    echo.
    echo --- opt: %%o ---

    echo   build root lib...
    if "%%o"=="none" (
        odin build . -build-mode:lib -vet -strict-style -o:none -debug
    ) else (
        odin build . -build-mode:lib -vet -strict-style -o:%%o
    )
    if !errorlevel! neq 0 (
        echo [ERROR] root build failed for -o:%%o
        exit /b !errorlevel!
    )

    echo   build pool lib...
    if "%%o"=="none" (
        odin build ./pool/ -build-mode:lib -vet -strict-style -o:none -debug
    ) else (
        odin build ./pool/ -build-mode:lib -vet -strict-style -o:%%o
    )
    if !errorlevel! neq 0 (
        echo [ERROR] pool build failed for -o:%%o
        exit /b !errorlevel!
    )

    echo   build examples...
    if "%%o"=="none" (
        odin build ./examples/ -build-mode:lib -vet -strict-style -o:none -debug
    ) else (
        odin build ./examples/ -build-mode:lib -vet -strict-style -o:%%o
    )
    if !errorlevel! neq 0 (
        echo [ERROR] examples build failed for -o:%%o
        exit /b !errorlevel!
    )

    echo   test tests/...
    if "%%o"=="none" (
        odin test ./tests/ -vet -strict-style -disallow-do -o:none -debug
    ) else (
        odin test ./tests/ -vet -strict-style -disallow-do -o:%%o
    )
    if !errorlevel! neq 0 (
        echo [ERROR] tests failed for -o:%%o
        exit /b !errorlevel!
    )

    echo   build pool_tests/...
    if "%%o"=="none" (
        odin build ./pool_tests/ -build-mode:lib -vet -strict-style -o:none -debug
    ) else (
        odin build ./pool_tests/ -build-mode:lib -vet -strict-style -o:%%o
    )
    if !errorlevel! neq 0 (
        echo [ERROR] pool_tests build failed for -o:%%o
        exit /b !errorlevel!
    )

    echo   test pool_tests/...
    if "%%o"=="none" (
        odin test ./pool_tests/ -vet -strict-style -disallow-do -o:none -debug
    ) else (
        odin test ./pool_tests/ -vet -strict-style -disallow-do -o:%%o
    )
    if !errorlevel! neq 0 (
        echo [ERROR] pool_tests tests failed for -o:%%o
        exit /b !errorlevel!
    )

    echo   pass: %%o
)

echo.
echo --- doc smoke test ---
odin doc ./
if !errorlevel! neq 0 ( echo [ERROR] doc failed for root & exit /b !errorlevel! )
odin doc ./pool/
if !errorlevel! neq 0 ( echo [ERROR] doc failed for pool & exit /b !errorlevel! )
odin doc ./pool_tests/
if !errorlevel! neq 0 ( echo [ERROR] doc failed for pool_tests & exit /b !errorlevel! )
odin doc ./examples/
if !errorlevel! neq 0 ( echo [ERROR] doc failed for examples & exit /b !errorlevel! )
odin doc ./tests/
if !errorlevel! neq 0 ( echo [ERROR] doc failed for tests & exit /b !errorlevel! )
echo   docs OK

echo.
echo ALL CHECKS PASSED
