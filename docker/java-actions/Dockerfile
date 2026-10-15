# The opt-in sidecar that runs a project's own Java actions for its Ruby
# application. The build context holds this folder's src/ and the project's
# javasource/ and userlib/; sources that use an API the sidecar does not offer
# are left out and listed in build-report.tsv.
FROM eclipse-temurin:21-jdk AS build
WORKDIR /build
# The third-party libraries the Mendix Runtime gives a project's Java code, such
# as Netty's HTTP cookie codec, at the Runtime's version and verified by checksum.
ADD --checksum=sha256:26775ca95820711403cf065fa2ec0134a0a04ff5417c688c0237aee68b55838d \
    https://repo1.maven.org/maven2/io/netty/netty-common/4.1.135.Final/netty-common-4.1.135.Final.jar runtime/
ADD --checksum=sha256:2a194f99fc93d07c4d442d04ac71bd2dc56d3188cd0e4270cdc2a953d1956bf9 \
    https://repo1.maven.org/maven2/io/netty/netty-buffer/4.1.135.Final/netty-buffer-4.1.135.Final.jar runtime/
ADD --checksum=sha256:77dd03865965b6c12b9e521bddec82f035caeb33156e09c158289c5094318481 \
    https://repo1.maven.org/maven2/io/netty/netty-resolver/4.1.135.Final/netty-resolver-4.1.135.Final.jar runtime/
ADD --checksum=sha256:6bde734d1ec073142eed31b1e68cd5d68fbf241e060b37f07a164e5ecb15631c \
    https://repo1.maven.org/maven2/io/netty/netty-transport/4.1.135.Final/netty-transport-4.1.135.Final.jar runtime/
ADD --checksum=sha256:245e74e04b6f4e8ef98853152412e3bf1499ce6fcf15329b798c8ce36c3537e2 \
    https://repo1.maven.org/maven2/io/netty/netty-handler/4.1.135.Final/netty-handler-4.1.135.Final.jar runtime/
ADD --checksum=sha256:7252171264dbb5bb8ed38e77f89643b31e3cabc96144ec27b6882435d718a61e \
    https://repo1.maven.org/maven2/io/netty/netty-codec/4.1.135.Final/netty-codec-4.1.135.Final.jar runtime/
ADD --checksum=sha256:4018529d3d6aecf4044b98c75d9a90c91839ddf49c7aa484c5ac81c90a15da02 \
    https://repo1.maven.org/maven2/io/netty/netty-codec-http/4.1.135.Final/netty-codec-http-4.1.135.Final.jar runtime/
COPY src/ sidecar/
RUN find sidecar -name '*.java' > sources.txt && javac -d api @sources.txt
COPY javasource/ javasource/
COPY userlib/ userlib/
COPY captions.tsv captions.tsv
RUN java -cp 'api:runtime/*' mxrb.sidecar.Build javasource userlib classes build-report.tsv

FROM eclipse-temurin:21-jre
WORKDIR /sidecar
COPY --from=build /build/api api
COPY --from=build /build/runtime runtime
COPY --from=build /build/classes classes
COPY --from=build /build/userlib userlib
COPY --from=build /build/build-report.tsv build-report.tsv
COPY --from=build /build/captions.tsv captions.tsv
RUN useradd --system --no-create-home sidecar
USER sidecar
ENV MXRB_JAVA_ACTIONS_PORT=7911 \
    MXRB_JAVA_ACTIONS_REPORT=/sidecar/build-report.tsv \
    MXRB_JAVA_ACTIONS_CAPTIONS=/sidecar/captions.tsv
EXPOSE 7911
CMD ["java", "-cp", "api:classes:userlib/*:userlib/vendorlib/*:runtime/*", "mxrb.sidecar.Server"]
