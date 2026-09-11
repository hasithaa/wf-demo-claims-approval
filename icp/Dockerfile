# The released ICP distribution, unpacked and run in the foreground.
# build.sh downloads the zip and stages it into ./artifacts.
FROM eclipse-temurin:21-jre

ARG ICP_DIST=wso2-integration-control-plane-2.1.0-alpha3

RUN apt-get update \
    && apt-get install -y --no-install-recommends unzip curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
COPY artifacts/${ICP_DIST}.zip /tmp/icp.zip
RUN unzip -q /tmp/icp.zip -d /opt \
    && mv /opt/${ICP_DIST} /opt/icp \
    && rm /tmp/icp.zip \
    && chmod +x /opt/icp/bin/icp.sh

# Rendered at start-up from the environment, so one image serves every node.
COPY conf/deployment.toml.tmpl /opt/icp/conf/deployment.toml.tmpl
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 9445 9446
WORKDIR /opt/icp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
