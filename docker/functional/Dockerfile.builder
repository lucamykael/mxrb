ARG JAVA_VERSION=21
FROM eclipse-temurin:${JAVA_VERSION}-jdk

RUN apt-get update \
 && apt-get install -y --no-install-recommends libicu-dev \
 && rm -rf /var/lib/apt/lists/*

COPY mxrb-functional-build /usr/local/bin/mxrb-functional-build

ENTRYPOINT ["mxrb-functional-build"]
