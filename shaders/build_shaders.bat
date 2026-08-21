@echo off
setlocal

for %%S in ("*.nosl") do (
    ..\no_gfx_api\build\gpu_compiler "%%S" -out:"./%%~nS.spv"
    echo %%S
)
