# Security policy

## Report a vulnerability

Please use GitHub's private vulnerability-reporting feature instead of opening a public issue for a suspected privilege-boundary, path-validation, credential, host-input, or VM-isolation flaw.

## Security boundary

The host broker runs as `SYSTEM` because Hyper-V lifecycle and VHD operations require host privilege. User submissions cross that boundary through ACL-protected JSON request directories. The broker validates artifact paths, action contracts, timeouts, reserved tokens, VHD attachment state, and read-only host-input mappings before invoking a guest worker.

The guest credential is generated locally during installation. It is never committed and must not be copied into an issue, log excerpt, or pull request. The Windows ISO, seed ISO, baseline export, VHDX cache, request state, screenshots, and evidence are also local-only.

Run `setup\Test-PublicRepository.ps1` before every public push. It rejects VM images, executables, generated broker state, private keys, literal user-profile paths, common secret formats, and unexpectedly large files.
