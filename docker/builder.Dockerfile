# The build toolchain, so the host needs nothing but Docker.
#
# The official Ballerina image carries the distribution and its Java runtime. build.sh runs this
# image with the repository mounted at /work: it builds each integration against the released
# packages from Ballerina Central and copies the fat jars out through the mount.
ARG BAL_RELEASE=2201.14.1
FROM ballerina/ballerina:${BAL_RELEASE}

USER root
WORKDIR /work
