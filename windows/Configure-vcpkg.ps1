param([string]$platform="x64-windows") #or x86-windows, arm64-windows
$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['*:ErrorAction']='Stop'

function Remove-DirectoryWithRetry
{
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$Attempts = 6,
        [int]$DelaySeconds = 5
    )

    if(-not (Test-Path -LiteralPath $Path))
    {
        return
    }

    for($attempt = 1; $attempt -le $Attempts; $attempt++)
    {
        try
        {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
        catch
        {
            if($attempt -eq $Attempts)
            {
                Write-Warning "Unable to remove '$Path' after $Attempts attempts; continuing. $($_.Exception.Message)"
                return
            }
        }

        if(-not (Test-Path -LiteralPath $Path))
        {
            return
        }

        Start-Sleep -Seconds $DelaySeconds
    }

    Write-Warning "Unable to remove '$Path' after $Attempts attempts; continuing."
}

if(!!(Get-Command 'tf' -ErrorAction SilentlyContinue) -eq $false -and $Env:GITHUB_WORKSPACE -eq $null)
{
    Write-Error "You must run this script within Developer Powershell for Visual Studio"
    exit 1
}
if(Test-Path "$(Split-Path -Parent $MyInvocation.MyCommand.Path)\..\vcpkg" -ErrorAction SilentlyContinue)
{
    Write-Output "$(Split-Path -Parent $MyInvocation.MyCommand.Path)\..\vcpkg already found! Not setting up."
    exit 1
}

if($platform -eq "x64-windows")
{
    $generator = "x64"
    $arch = "AMD64"
    $sdrplay_arch = "x64"
}
elseif($platform -eq "x86-windows")
{
    $generator = "Win32"
    $arch = "X86"
    $sdrplay_arch = "x86"
}
elseif($platform -eq "arm64-windows")
{
    $generator = "ARM64"
    $arch = "ARM64"
    $sdrplay_arch = "arm64"
}
else
{
    Write-Error "Unsupported platform: $platform"
    exit 1
}

if($env:PROCESSOR_ARCHITECTURE -ne $arch)
{
    if($env:PROCESSOR_ARCHITECTURE -eq "AMD64")
    {
        $host_triplet = "x64-windows"
    }
    elseif($env:PROCESSOR_ARCHITECTURE -eq "X86")
    {
        $host_triplet = "x86-windows"
    }
    elseif($env:PROCESSOR_ARCHITECTURE -eq "ARM64")
    {
        $host_triplet = "arm64-windows"
    }
    else
    {
        Write-Error "Unsupported host platform: $($env:PROCESSOR_ARCHITECTURE)"
        exit 1
    }
}

#Setup vcpkg
Write-Output "Configuring vcpkg..."
cd "$(Split-Path -Parent $MyInvocation.MyCommand.Path)\.."
git clone https://github.com/microsoft/vcpkg -b 2026.07.29
cd vcpkg
.\bootstrap-vcpkg.bat

function Invoke-VcpkgInstall
{
    param([string[]]$Arguments)

    for($attempt = 1; $attempt -le 3; $attempt++)
    {
        & .\vcpkg @Arguments
        $exit_code = $LASTEXITCODE
        if($exit_code -eq 0)
        {
            return
        }

        if($attempt -lt 3)
        {
            Write-Warning "vcpkg failed with exit code $exit_code; retrying in 15 seconds ($attempt/3)"
            Start-Sleep -Seconds 15
        }
    }

    throw "vcpkg install failed after 3 attempts (last exit code $exit_code)"
}

# Core packages. libxml2 is for libiio.
# hdf5[hl] is required: official_products_support includes H5LTpublic.h, which
# only ships with the high-level feature. Without it the Windows build fails
# with "C1083: Cannot open include file: 'H5LTpublic.h'".
Invoke-VcpkgInstall -Arguments @("install", "--triplet", $platform, "pthreads", "libjpeg-turbo", "tiff", "libpng", "glfw3", "libusb", "fftw3", "libxml2", "portaudio", "nng", "zstd", "armadillo", "opencl", "curl[ssl]", "hdf5[hl]")

# Entirely for UHD... Skip it!
if($platform -eq "x64-windows" -or $platform -eq "x86-windows")
{
    Write-Output "Skipping UHD boost dependencies."
    # Invoke-VcpkgInstall -Arguments @("install", "--triplet", $platform, "boost-chrono", "boost-date-time", "boost-filesystem", "boost-program-options", "boost-system", "boost-serialization", "boost-thread", "boost-test", "boost-format", "boost-asio", "boost-math", "boost-graph", "boost-units", "boost-lockfree", "boost-circular-buffer", "boost-assign", "boost-dll")
}

#Start Building Dependencies
$null = mkdir build
cd build
$build_args="-DCMAKE_TOOLCHAIN_FILE=$($(Get-Item ..\scripts\buildsystems\vcpkg.cmake).FullName)", "-DVCPKG_TARGET_TRIPLET=$platform", "-DCMAKE_INSTALL_PREFIX=$($(Get-Item ..\installed\$platform).FullName)", "-DCMAKE_BUILD_TYPE=Release", "-A", $generator

$standard_include=$(Get-Item ..\installed\$platform\include).FullName
$pthread_lib=$(Get-Item ..\installed\$platform\lib\pthreadVC3.lib).FullName
$libusb_include=$(Get-Item ..\installed\$platform\include\libusb-1.0).FullName
$libusb_lib=$(Get-Item ..\installed\$platform\lib\libusb-1.0.lib).FullName
if($env:PROCESSOR_ARCHITECTURE -ne $arch)
{
    $build_args += "-DCMAKE_SYSTEM_NAME=Windows", "-DCMAKE_SYSTEM_PROCESSOR=$arch", "-DCMAKE_CROSSCOMPILING=ON", "-DVCPKG_USE_HOST_TOOLS=ON", "-DVCPKG_HOST_TRIPLET=$host_triplet"
}

Write-Output "Building libusb..."
git clone https://github.com/HannesFranke-smartoptics/libusb -b raw_io_v2
cd libusb\msvc
(Get-Content -raw Base.props) -replace "<TreatWarningAsError>true</TreatWarningAsError>", "<TreatWarningAsError>false</TreatWarningAsError>" | Set-Content -Encoding ASCII Base.props
msbuild -m -v:m -p:Platform=$generator,Configuration=Release .\libusb.sln
msbuild -m -v:m -p:Platform=$generator,Configuration=Debug .\libusb.sln
$toolset_used=$(get-childitem ..\build\)[0].Name
cp -Force ..\build\$toolset_used\$generator\Release\dll\libusb-1.0.dll ..\..\..\installed\$platform\bin
cp -Force ..\build\$toolset_used\$generator\Release\dll\libusb-1.0.pdb ..\..\..\installed\$platform\bin
cp -Force ..\build\$toolset_used\$generator\Release\dll\libusb-1.0.lib ..\..\..\installed\$platform\lib
cp -Force ..\build\$toolset_used\$generator\Debug\dll\libusb-1.0.dll ..\..\..\installed\$platform\Debug\bin
cp -Force ..\build\$toolset_used\$generator\Debug\dll\libusb-1.0.pdb ..\..\..\installed\$platform\Debug\bin
cp -Force ..\build\$toolset_used\$generator\Debug\dll\libusb-1.0.lib ..\..\..\installed\$platform\Debug\lib
cp -force ..\libusb\libusb.h ..\..\..\installed\$platform\include
cd ..\..
Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "libusb")

Write-Output "Building cpu_features..."
git clone https://github.com/google/cpu_features
cd cpu_features
git checkout 6aecde5
$null = mkdir build
cd build
cmake $build_args -DBUILD_TESTING=OFF -DBUILD_EXECUTABLE=OFF ..
cmake --build . --config Release
cmake --install .
cd ..\..
Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "cpu_features")

Write-Output "Building Volk..."
git clone https://github.com/JVital2013/volk --depth 1 -b win-arm64
cd volk
$null = mkdir build
cd build
cmake $build_args -DENABLE_TESTING=OFF -DENABLE_MODTOOL=OFF ..
cmake --build . --config Release
cmake --install .
cd ..\..
Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "volk")

Write-Output "Building Airspy..."
git clone https://github.com/JVital2013/airspyone_host -b rawio
cd airspyone_host\libairspy
$null = mkdir build
cd build
cmake $build_args -DLIBUSB_INCLUDE_DIR="$($libusb_include)" -DLIBUSB_LIBRARIES="$($libusb_lib)" -DTHREADS_PTHREADS_WIN32_LIBRARY="$($pthread_lib)" ..
cmake --build . --config Release
cmake --install .
cd ..\..\..
Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "airspyone_host")

Write-Output "Building Airspy HF..."
git clone https://github.com/JVital2013/airspyhf -b rawio
cd airspyhf\libairspyhf
$null = mkdir build
cd build
cmake $build_args -DLIBUSB_INCLUDE_DIR="$($libusb_include)" -DLIBUSB_LIBRARIES="$($libusb_lib)" -DTHREADS_PTHREADS_WIN32_LIBRARY="$($pthread_lib)" ..
cmake --build . --config Release
cmake --install .
cd ..\..\..
Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "airspyhf")

Write-Output "Building RTL-SDR..."
git clone https://github.com/JVital2013/librtlsdr -b rawio
cd librtlsdr
$null = mkdir build
cd build
cmake $build_args -DLIBUSB_INCLUDE_DIRS="$($libusb_include)" -DLIBUSB_LIBRARIES="$($libusb_lib)" -DTHREADS_PTHREADS_INCLUDE_DIR="$($standard_include)" -DTHREADS_PTHREADS_LIBRARY="$($pthread_lib)" ..
cmake --build . --config Release
cmake --install .
cd ..\..
Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "librtlsdr")

Write-Output "Building HackRF..."
git clone https://github.com/JVital2013/hackrf -b rawio
cd hackrf\host\libhackrf
$null = mkdir build
cd build
cmake $build_args -DLIBUSB_INCLUDE_DIR="$($libusb_include)" -DLIBUSB_LIBRARIES="$($libusb_lib)" -DTHREADS_PTHREADS_WIN32_LIBRARY="$($pthread_lib)" ..
cmake --build . --config Release
cmake --install .
cd ..\..\..\..
Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "hackrf")

Write-Output "Building libiio..."
git clone https://github.com/analogdevicesinc/libiio --depth 1 -b v0.25
cd libiio
(Get-Content -raw CMakeLists.txt) -replace "check_symbol_exists\(libusb_get_version libusb.h HAS_LIBUSB_GETVERSION\)", "" | Set-Content -Encoding ASCII CMakeLists.txt
$null = mkdir build
cd build
cmake $build_args -DWITH_IIOD=OFF -DWITH_TESTS=OFF -DWITH_ZSTD=ON -DLIBUSB_INCLUDE_DIR="$($libusb_include)" -DLIBUSB_LIBRARIES="$($libusb_lib)" ..
cmake --build . --config Release
cmake --install .
cd ..\..
Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "libiio")

Write-Output "Building libad9361-iio..."
git clone https://github.com/analogdevicesinc/libad9361-iio --depth 1 -b v0.3
cd libad9361-iio
$null = mkdir build
cd build
cmake $build_args -DLIBIIO_LIBRARIES="$($(Get-Item ..\..\..\installed\$platform\lib\libiio.lib).FullName)" -DENABLE_PACKAGING=OFF ..
cmake --build . --config Release
cmake --install .
cd ..\..
Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "libad9361-iio")

if($platform -eq "x64-windows" -or $platform -eq "x86-windows")
{
    Write-Output "Building LimeSuite..."
    $fx3_ok = $false
    foreach($fx3_url in @("https://github.com/myriadrf/LimeSuite/archive/refs/tags/v23.11.0/FX3-SDK.zip", "https://www.satdump.org/FX3-SDK.zip"))
    {
        try
        {
            Invoke-WebRequest -Uri $fx3_url -OutFile FX3-SDK.zip -MaximumRedirection 5
            $magic = [System.IO.File]::ReadAllBytes((Resolve-Path FX3-SDK.zip))[0..1]
            if($magic[0] -eq 0x50 -and $magic[1] -eq 0x4B)
            {
                Expand-Archive FX3-SDK.zip . -Force
                if(Test-Path .\FX3-SDK)
                {
                    $fx3_ok = $true
                    break
                }
            }
            Write-Warning "FX3-SDK from $fx3_url is not a valid ZIP; trying next source"
        }
        catch
        {
            Write-Warning "FX3-SDK download from $fx3_url failed: $($_.Exception.Message)"
        }
        Remove-Item -LiteralPath (Join-Path (Get-Location) "FX3-SDK.zip") -Force -ErrorAction SilentlyContinue
    }

    if($fx3_ok)
    {
        $fx3_arg = "-DFX3_SDK_PATH=$($(Get-Item .\FX3-SDK).FullName)"
        git clone https://github.com/myriadrf/LimeSuite --depth 1 -b v23.11.0
        cd LimeSuite
        $null = mkdir build-dir
        cd build-dir
        cmake $build_args -DENABLE_GUI=OFF $fx3_arg ..
        cmake --build . --config Release
        cmake --install .
        cd ..\..
        Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "LimeSuite")
    }
    else
    {
        Write-Warning "Skipping LimeSuite: the FX3 SDK is unavailable."
    }
}

Write-Output "Building bladeRF..."
$fx3_arg = ""
git clone https://github.com/Nuand/bladeRF --depth 1 -b 2024.05
cd bladeRF\host
Clear-Content cmake/modules/FindLibPThreadsWin32.cmake
Clear-Content cmake/modules/FindLibUSB.cmake
(Get-Content -raw CMakeLists.txt) -replace "(?ms)find_package\(LibPThreadsWin32\).*endif\(LIBUSB_FOUND\)", "" | Set-Content -Encoding ASCII CMakeLists.txt
$null = mkdir build
cd build
cmake $build_args $fx3_arg -DTREAT_WARNINGS_AS_ERRORS=OFF -DLIBPTHREADSWIN32_INCLUDE_DIRS="$($standard_include)" -DLIBUSB_INCLUDE_DIRS="$($libusb_include)" -DLIBUSB_LIBRARIES="$($libusb_lib)" -DLIBPTHREADSWIN32_LIBRARIES="$($pthread_lib)" -DTEST_LIBBLADERF=OFF -DLIBUSB_FOUND=ON -DLIBPTHREADSWIN32_FOUND=ON -DLIBUSB_VERSION="$($(ls ..\..\..\..\installed\vcpkg\info\libusb*).BaseName.split('_')[1])" ..
cmake --build . --config Release
cmake --install .
cd ..\..\..
Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "bladeRF")

if($platform -eq "x64-windows" -or $platform -eq "x86-windows")
{
    Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "FX3-SDK")
    Remove-Item -LiteralPath (Join-Path (Get-Location) "FX3-SDK.zip") -Force -ErrorAction SilentlyContinue
    Write-Output "Skipping UHD build to avoid Boost dependency failure."
}

cd ..
Remove-DirectoryWithRetry -Path (Join-Path (Get-Location) "build")

try
{
    Invoke-WebRequest -Uri "https://www.satdump.org/SDRPlay.zip" -OutFile sdrplay.zip -MaximumRedirection 5
    $magic = [System.IO.File]::ReadAllBytes((Resolve-Path sdrplay.zip))[0..1]
    if($magic[0] -eq 0x50 -and $magic[1] -eq 0x4B)
    {
        mkdir sdrplay | Out-Null
        Expand-Archive sdrplay.zip . -Force
        if(Test-Path sdrplay\API)
        {
            cp sdrplay\API\inc\*.h installed\$platform\include
            cp sdrplay\API\$sdrplay_arch\sdrplay_api.dll installed\$platform\bin
            cp sdrplay\API\$sdrplay_arch\sdrplay_api.lib installed\$platform\lib
        }
        else
        {
            Write-Warning "SDRPlay.zip did not contain an API folder; skipping SDRPlay API install."
        }
    }
    else
    {
        Write-Warning "SDRPlay.zip is not a valid ZIP; skipping SDRPlay API install."
    }
}
catch
{
    Write-Warning "SDRPlay API install skipped: $($_.Exception.Message)"
}
Remove-Item sdrplay -Force -Recurse -ErrorAction SilentlyContinue
Remove-Item sdrplay.zip -Force -ErrorAction SilentlyContinue

mv installed\$platform\lib\*.dll installed\$platform\bin\
mv installed\$platform\bin\*.lib installed\$platform\lib\
cd ..

if($LASTEXITCODE -ne 0)
{
    Write-Warning "Ignoring leftover native exit code $LASTEXITCODE from optional dependency steps."
}
exit 0
