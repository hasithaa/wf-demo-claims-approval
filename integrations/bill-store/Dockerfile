# The integration as a fat jar. `bal build` runs inside the builder image (build.sh) —
# it needs the local bala repository holding the prebuilt workflow module and bridge —
# and stages the jar into ./artifacts.
# JDK 25, not the 21 Ballerina ships with. Ballerina runs each strand on a virtual thread, and
# on JDK 21 a virtual thread that blocks while holding a monitor pins its carrier; with as many
# pins as cores the scheduler starves, the bridge's heartbeat tick never gets dispatched, and the
# runtime goes OFFLINE while the process looks alive. JDK 24 (JEP 491) made synchronized blocks
# release the carrier, so the same code cannot wedge here. The fat jar is plain Java and needs no
# change to run on the newer JRE.
FROM eclipse-temurin:25-jre

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY artifacts/bill-store.jar /app/app.jar
COPY Config.toml.tmpl /app/Config.toml.tmpl
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
