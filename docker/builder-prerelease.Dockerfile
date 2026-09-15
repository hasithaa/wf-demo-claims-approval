# The build toolchain for the observability mode, which needs an unreleased distribution.
#
# The workflow module's telemetry build targets a Ballerina distribution that is not released
# yet: there is no image on Docker Hub and no public download for it, only the zip in the
# ballerina-platform GitHub Packages registry, which needs credentials. So this image carries
# a JDK and unpacks that zip, instead of starting from the official Ballerina image the way
# docker/builder.Dockerfile does. Only ./build.sh --with-observability builds it.
FROM eclipse-temurin:21-jdk

ARG BAL_VERSION
ARG BAL_DIST_URL
ARG BAL_OBSERVE_URL

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip \
    && rm -rf /var/lib/apt/lists/*

# The credentials are a build secret, so they stay out of the image and its history.
#
# The tools zip is the distribution without its libraries: everything the integrations import
# resolves from Ballerina Central at build time, except `ballerinai/observe`, which is internal
# to the distribution and is what `observabilityIncluded = true` compiles against. It is
# unpacked into the distribution's own package repository, where the compiler looks for it.
RUN --mount=type=secret,id=ghcreds \
    set -a && . /run/secrets/ghcreds && set +a \
    && curl -fsSL --retry 3 -u "${packageUser}:${packagePAT}" -o /tmp/dist.zip "${BAL_DIST_URL}" \
    && unzip -q /tmp/dist.zip -d /opt \
    && rm /tmp/dist.zip \
    && ln -s "/opt/jballerina-tools-${BAL_VERSION}" /opt/ballerina \
    && curl -fsSL --retry 3 -L -u "${packageUser}:${packagePAT}" -o /tmp/observe.zip "${BAL_OBSERVE_URL}" \
    && unzip -q -o /tmp/observe.zip -d /opt/ballerina/repo \
    && rm /tmp/observe.zip

# bal reads JAVA_HOME from the environment, which the JDK image already sets.
ENV PATH="/opt/ballerina/bin:${PATH}"

WORKDIR /work
