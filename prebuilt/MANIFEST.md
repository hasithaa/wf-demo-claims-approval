# Prebuilt binaries

Neither the ICP nor the Ballerina workflow module is released yet, so this demo carries
them prebuilt. Every artifact here is from the PR head named below — `build.sh` consumes
them; nothing needs to be built from these sources.

| Artifact | Source | Commit |
|---|---|---|
| `wso2-integration-control-plane-2.0.0-SNAPSHOT.zip` | `hasithaa/integration-control-plane`, local merge `icp-demo-obs` = main + `workflow-instance-graph` (PR wso2#851) + `icp-connection-hardening` (PR wso2#859) | `08420a449` — 2026-09-03 |
| `ballerina-workflow-java21-0.9.0.bala` | `hasithaa/fork-module-ballerina-workflow`, local merge `demo-bala-obs` = main + `humantask-taskinput` (PR ballerina-platform#105) + `observability-integration` (PR ballerina-platform#106) | `4e9a063` — 2026-09-03 |
| `wso2-icp.runtime.bridge-java21-0.3.0-SNAPSHOT.bala` | `hasithaa/icp-runtime-bridge` @ `management-reset` (PR wso2#44 and later, incl. the heartbeat-guard fix) | `0278ab5` — 2026-09-02 |

Every open PR the demo depends on rides in these builds: #105 (taskInput rename +
deprecation removal), #106 (observability — metrics and tracing), wso2#851 (the workflow
console UX), wso2#859 (connection hardening + the pool-leak fix), and the bridge's
heartbeat-guard release. The 2026-09-03 build also turns observability on: every
integration builds with `observabilityIncluded = true` and links `ballerinax/prometheus`,
Config.toml enables the metrics reporter, and the compose file gains a `prometheus`
service scraping all four integrations on :9797 (UI at `http://localhost:9095`).

## Rebuilding

Check out the branch named above and:

```sh
# ICP zip
CI=true ./gradlew assembleICP        # -> build/distribution/*.zip

# workflow module bala
cd ballerina && bal pack             # -> target/bala/*.bala

# bridge bala
./gradlew build -x test              # -> ballerina/build/bal_build_target/bala/*.bala
```
