# Security

## Reporting a vulnerability

Open an issue in this repository. If public details could put users at risk before a fix is available, state that in the issue without including exploit details so a private reporting channel can be arranged.

## Update trust

The installer and updater run with root privileges. The first bootstrap is fetched over HTTPS from this repository; that first request depends on TLS and repository integrity. The bootstrap contains pinned Ed25519 release-key fingerprints. It verifies the controlled `UPDATES.json` signature before trusting the artifact URL, expected size, and SHA-256. The digest is checked against the complete OpenWrt rootfs archive before installation.

Production signing uses a private key held in the protected GitHub production environment. The public key and trusted key identifiers are distributed with the project. A signature protects release metadata and artifact selection against a compromised repository publishing unsigned or self-signed metadata; it does not protect against compromise of the signing environment or private key.

The installed release replaces product-owned paths and keeps `/etc/z2k` operator data outside the release payload. See [release operations](docs/openwrt-release-operations.md) for ownership and recovery behavior.

## WebPanel exposure

The WebPanel listens on HTTP and defaults to the router's LAN address on port `8088`. It is intended for access from the local network. Do not expose it to the internet or forward its port from a WAN interface.

Panel password authentication is optional and disabled by default. When enabled, it adds a login boundary but does not make public exposure safe. Host and request-origin checks help prevent a web page from issuing unwanted requests through a user's browser; they do not protect against a device that can directly reach the panel on the LAN.

## Telemetry

Strategy telemetry is enabled by default and can be disabled with the `Z2K_STATS` setting in `/etc/z2k/config` or through the available settings interface. The first scheduled upload is delayed until the telemetry notice has been shown, with a three-day maximum delay. The uploader sends strategy pool, strategy slot, and rounded time-in-slot values to the configured endpoint. It omits the host column from the local strategy state and does not send a stable device identifier. The current default endpoint uses HTTP: the upload contents and the router's source IP are visible to the endpoint and network path in transit.

## Security boundaries

- The release signature and artifact digest protect release integrity; they do not hide network activity from an internet provider or prove that the application itself is benign.
- Availability probes may accept test certificates or responses where they only measure reachability. They must not be treated as proof of a destination's identity.
- Secrets embedded in public binaries or source must be treated as public. Device-generated identity material is a separate credential and should remain on the device.
- The project does not claim that a successful source or fixture check proves safe behavior on every router model or filesystem.


## Legal and deployment boundary

Security guarantees do not imply that every network configuration is permitted in every jurisdiction or network. Operators are responsible for reviewing applicable requirements and third-party terms before deployment. See [LEGAL.md](LEGAL.md) for the project's public use-policy and documentation boundary.
