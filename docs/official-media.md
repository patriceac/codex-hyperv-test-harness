# Official Windows media

The installer does not ship or pin a Windows ISO. `setup\Get-OfficialWindows11Iso.ps1` opens Microsoft's Windows 11 software-download page in signed Microsoft Edge headlessly, selects the current x64 multi-edition ISO and requested language, and extracts the temporary Microsoft download URL produced by the page.

Raw calls to Microsoft's connector are not used as the final resolver because its anti-abuse gate expects a real page session. No third-party mirror or third-party link service is involved.

Before accepting the download, the script requires HTTPS on an allowed Microsoft domain. After download it mounts the ISO, validates the Authenticode signature on `setup.exe`, locates `sources\install.wim` or `install.esd`, enumerates its editions, and requires exactly one `EditionId=Professional`. It records the SHA-256, length, resolved source, image index, image name, and signer next to the cached ISO.

On reuse, both the ISO contents and recorded SHA-256 are checked again. A changed Microsoft release naturally receives a new temporary URL and locally recorded hash; no source-code checksum update is required.
