# The integration as a fat jar. `bal build` runs inside the builder image (build.sh) —
# it needs the local bala repository holding the prebuilt workflow module and bridge —
# and stages the jar into ./artifacts.
FROM eclipse-temurin:21-jre

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY artifacts/claims.jar /app/app.jar
COPY Config.toml.tmpl /app/Config.toml.tmpl
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
