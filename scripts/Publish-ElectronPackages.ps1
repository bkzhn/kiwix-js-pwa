﻿# Publish Kiwix Electron packages to a GitHub draft release and/or to Kiwix download server
[CmdletBinding()]
param (
    [string]$test = "", # Allows user to test a single package
    [switch]$dryrun = $false,
    [switch]$githubonly = $false,
    [switch]$portableonly = $false, # If true, will only publish the portable package to GitHub, does not affect download.kiwix.org publishing
    [string]$tag = "",
    [string]$overridetarget = "" # Set this to "nightly" to force publication to the nightly folder on download.kiwix.org
)
if ($tag) {
    # If user overrode the INPUT_VERSION, use it
    $INPUT_VERSION = $tag
}
if ($overridetarget) {
    # If user overrode the INPUT_TARGET, use it
    $INPUT_TARGET = $overridetarget
}
$target = "/data/download/release/kiwix-js-electron"
$win_target = "/data/download/release/kiwix-js-windows" # In future, consider changing to kiwix-js-pwa
$keyfile = "$PSScriptRoot\ssh_key"
$keyfile = $keyfile -ireplace '[\\/]', '/'

if ($INPUT_TARGET -eq "nightly") {
    "`nUser manually requested a nightly build..."
    $CRON_LAUNCHED = "1"
}

if ($CRON_LAUNCHED) {
    "`nThis script was launched by the Github Cron prccess"
    $current_date = $(Get-Date -Format "yyyy-MM-dd")
    $target = "/data/download/nightly/$current_date"
}

if ((Get-Content ./package.json) -match 'nwVersion') { # NWJS
    $Packages = $(ls dist/bld/NWJS/*.*)
} elseif ((Get-Content ./package.json) -match '"22\.3\.25"') { # Windows 7 version (Electron)
    $Packages = $(ls dist/bld/Electron/*Win7*.*)
} else {
    $Packages = $(ls dist/bld/Electron/*.*)
    $Packages += $(ls dist/bld/Electron/nsis-web/*.exe)
    $Packages += $(ls dist/bld/Electron/nsis-web/*.nsis.7z)
}
if ($test) {
    $Packages = @($test)
}

if (-not $CRON_LAUNCHED) {
    "`nChecking for a draft publishing target on GitHub..."
    if (-not $GITHUB_TOKEN) {
        $GITHUB_TOKEN = Get-Content -Raw "$PSScriptRoot/github_token"
    }
    $draft_release_params = @{
        Uri = "https://api.github.com/repos/kiwix/kiwix-js-pwa/releases"
        Method = 'GET'
        Headers = @{
            'Authorization' = "token $GITHUB_TOKEN"
            'Accept' = 'application/vnd.github.v3+json'
        }
        ContentType = "application/json"
    }
    $releases = Invoke-RestMethod @draft_release_params
    $release_found = $false
    $release = $null
    $base_input = $INPUT_VERSION -replace '^(v[0-9.]+).*', '$1'
    $releases | Where-Object { $release_found -eq $False } | % {
        $release = $_
        if (($release.draft -eq $true) -and ($release.tag_name -match $base_input)) {
            $release_found = $true
        }
    }
    if ($release_found) {
        if ($dryrun) {
            $release_json = $release | ConvertTo-Json
            "[DRYRUN:] Draft release found: `n$release_json"
        }
        $upload_uri = $release.upload_url -ireplace '\{[^{}]+}', '' 
        "`nUploading assets to: $upload_uri..."
        $filter = '\.(exe|zip|msix|appx|7z|yml)$'
        if ($portableonly) {
            $filter = '\.(zip)$'
        }
        ForEach($asset in $Packages) {
            if (-Not $asset) { Continue }
            if (-Not ($asset -match $filter)) { Continue }
            # Replace backslash with forward slash
            $asset_name = $asset -replace '^.*[\\/]([^\\/]+)$', '$1'
            # Replace spaces with hyphens
            $asset_name = $asset_name -replace '\s', '-';
            # Establish upload params
            $upload_params = @{
                Uri = $upload_uri + "?name=$asset_name"
                Method = 'POST'
                Headers = @{
                    'Authorization' = "token $GITHUB_TOKEN"
                    'Accept' = 'application/vnd.github.v3+json'
                }
                # Body = [System.IO.File]::ReadAllBytes($upload_file)
                InFile = $asset
                ContentType = 'application/octet-stream'
            }
            "`n*** Uploading $asset..."
            # Upload asset to the release server
            # $upload = [System.IO.File]::ReadAllBytes($upload_file) | Invoke-RestMethod @upload_params
            if (-Not $dryrun) {
                # Disable progress because it causes high CPU usage on large files, and slows down upload
                $ProgressPreference = 'SilentlyContinue'
                $upload = Invoke-RestMethod @upload_params
            }
            if ($dryrun -or $upload.name -eq ($asset_name -replace '\s', '.')) {
                if (-Not $dryrun) {
                    "Upload successfully posted as " + $upload.url
                    "Full details:"
                    echo $upload
                } else {
                    echo "DRYRUN with these upload parameters:`n" + @upload_params 
                }
            } else {
                "`nI'm sorry, this upload appears to have failed! Please upload manually or try again..."
                if ($upload) {
                    "`nThe server returned:"
                    echo $upload
                } else {
                    "The server did not respond."
                }
            }
        }
    } else {
        "No draft release matching the tag $INPUT_VERSION was found."
    }

}  

if (-not $githubonly) {
    "`nUploading packages to https://master.download.kiwix.org$target/ ...`n"
    if (-Not $dryrun) {
        echo "mkdir $target" | & "C:\Program Files\Git\usr\bin\sftp.exe" @('-P', '30022', '-o', 'StrictHostKeyChecking=no', '-i', "$keyfile", 'ci@master.download.kiwix.org')
        # echo "mkdir $win_target" | & "C:\Program Files\Git\usr\bin\sftp.exe" @('-P', '30022', '-o', 'StrictHostKeyChecking=no', '-i', "$keyfile", 'ci@master.download.kiwix.org')
    }
    $Packages | % {
        $file = $_
        if ($file -match '\.(exe|zip|msix|appx|7z)$') {
            $directory = $file -replace '^(.+[\\/])[^\\/]+$', '$1'
            $filename = $file -replace '^.+[\\/]([^\\/]+)$', '$1'
            # Convert all spaces and hyphens to underscore
            $filename = $filename -replace '[\s-]', '_'
            $filename = $filename -creplace '_N([_.])', '_NWJS$1'
            # Swap architecture and release number, and remove redundant -win
            $filename = $filename -replace '(windows(?:_XP)?)(.+)_win(_(?:ia32|x64)[^.]*)', '$1$3$2'
            # Convert filename to lowercase
            $filename = $filename.ToLower()
            # Convert back appname to hyphens
            $filename = $filename -replace 'kiwix_js_(electron|windows)', 'kiwix-js-$1'
            # Fix Windows Portable version so that it is clear it is portable for Windows
            $filename = $filename -replace 'electron(?!_(?:setup|win7|web))(.+\.exe)$', 'electron_win_portable$1'
            # Fix Windows Setup version so that it is clear it is a Windows executable
            $filename = $filename -replace 'electron_setup', 'electron_win_setup'
            # Fix Windows Web Setup version so that it is clear it is a Windows executable
            $filename = $filename -replace 'electron_web_setup', 'electron_win_web_setup'
            # Fix Windows appx version so that it is clear it is a Windows 64bit executable
            $filename = $filename -replace 'electron(.+\.appx)$', 'electron_x86-64$1'
            # Change underscore to hyphen in win type and remove redundant E
            $filename = ($filename -creplace '_xp([_.])', '-xp$1') -creplace '_e([_.])', '$1'
            # Move nwjs
            $filename = $filename -replace '-windows(.*)_nwjs', '-nwjs_win$1'
            # Change ia32 to i386
            $filename = $filename -replace 'ia32', 'i386'
            if ($CRON_LAUNCHED) {
                # Remove the version number
                $filename = $filename -replace '_[0-9.]+([-_.])', '$1'
                # Remove any REV ID
                $filename = $filename -replace '_[0-9a-f]{7}([_.])', '$1'
                # Add the date
                $filename = $filename -replace '(\.[^.]+)$', ('_' + $current_date + '$1')
            }
            # Put back together
            $renamed_file = "$directory$filename"
            if ($test -or $dryrun) {
                "`n$file was renamed to $renamed_file"
            } else {
                # Rename the file
                if ($file -ne $renamed_file) {
                    "`nRenaming $file to $renamed_file..."
                    mv $file $renamed_file
                }
                # Replace absolute path with relative, and normalize to forward slashes
                $renamed_file = $renamed_file -replace '^.*?([\\/]bld)', './dist$1' -replace '[\\/]', '/'
                "Copying $renamed_file to $target..."
                & "C:\Program Files\Git\usr\bin\scp.exe" @('-P', '30022', '-o', 'StrictHostKeyChecking=no', '-i', "$keyfile", "$renamed_file", "ci@master.download.kiwix.org:$target")
                # DEV: Note that the package is currently uploaded in Push-KiwixRelease, so we don't need to upload it here at this point in time
                # if (!$CRON_LAUNCHED -and $renamed_file -match '\.appx$') {
                #     "Also copying $renamed_file to $win_target..."
                #     $renamed_win_file = $renamed_file -replace 'electron_x86-64', 'windows'
                #     mv $renamed_file $renamed_win_file
                #     & "C:\Program Files\Git\usr\bin\scp.exe" @('-P', '30022', '-o', 'StrictHostKeyChecking=no', '-i', "$keyfile", "$renamed_win_file", "ci@master.download.kiwix.org:$win_target")
                # }
            }
        }
    }
}
""
