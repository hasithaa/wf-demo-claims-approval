# Versions

This demo runs the WSO2 Integrator 1.0 RC1 line-up. Every piece is released, so nothing here is
built from a branch.

| Artifact | Where it comes from | Version |
|---|---|---|
| Ballerina distribution | `ballerina/ballerina` Docker image (or a local `bal` via `BAL=`) | `2201.14.1` |
| `ballerina/workflow` | Ballerina Central | `1.0.0` |
| `wso2/icp.runtime.bridge` | Ballerina Central | `2.0.0` |
| ICP distribution | [wso2/integration-control-plane v2.1.0](https://github.com/wso2/integration-control-plane/releases/tag/v2.1.0) release asset, checked against its `.sha256` | `2.1.0` |

`build.sh` downloads the ICP zip into this directory on first run (gitignored). To skip the
download, drop `wso2-integration-control-plane-2.1.0.zip` and its `.sha256` here first.

The integrations build with `remoteManagement = true`: without it the bridge reports no
artifacts and the console's workflow operations stay `PENDING`.
