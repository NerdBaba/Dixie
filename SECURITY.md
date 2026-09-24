# Security Policy

Dixie is an early-stage local-network media server. Security reports are welcome.

## Supported versions

There is not yet a stable release line. Security fixes target the current `main` branch.

## Deployment model

Dixie is intended for trusted local networks.

When the server is running:

- it accepts inbound HTTP connections on TCP port 8080;
- it uses SSDP multicast on UDP port 1900;
- it does not currently provide authentication;
- it does not currently provide TLS;
- App Sandbox is disabled to support multicast discovery and inbound LAN traffic.

Do not port-forward Dixie, place it directly on an untrusted network, or expose its HTTP server to the public internet.

Only add folders and URLs that you are comfortable making reachable to compatible clients on the same network.

## Reporting a vulnerability

Please do **not** open a public GitHub issue for a suspected vulnerability.

Use GitHub private vulnerability reporting if it is enabled for the repository. If it is not available, contact the repository owner privately through their GitHub profile and include:

- a concise description of the issue;
- affected code paths or components;
- reproduction steps or a proof of concept;
- the potential security impact;
- any suggested mitigation.

Avoid including private media, credentials, access tokens, or unrelated personal data in a report.
