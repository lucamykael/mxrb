# The opt-in sidecar that runs a project's own Java actions for its Ruby
# application. The build context holds this folder's src/ and the project's
# javasource/ and userlib/; sources that use an API the sidecar does not offer
# are left out and listed in build-report.tsv.
FROM eclipse-temurin:21-jdk AS build
WORKDIR /build
COPY src/ sidecar/
RUN find sidecar -name '*.java' > sources.txt && javac -d api @sources.txt
COPY javasource/ javasource/
COPY userlib/ userlib/
COPY captions.tsv captions.tsv
RUN java -cp api mxrb.sidecar.Build javasource userlib classes build-report.tsv

FROM eclipse-temurin:21-jre
WORKDIR /sidecar
COPY --from=build /build/api api
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
CMD ["java", "-cp", "api:classes:userlib/*:userlib/vendorlib/*", "mxrb.sidecar.Server"]
