# The build toolchain, so the host needs nothing but Docker.
#
# The official Ballerina image carries the distribution (2201.13.4) and a Java 21 runtime —
# the same pairing the prebuilt balas were produced with. build.sh runs this image with the
# repository mounted at /work: it pushes the prebuilt balas into the container-local
# Ballerina repository, builds each integration against them, and copies the fat jars out
# through the mount.
FROM ballerina/ballerina:2201.13.4

USER root
WORKDIR /work
