FROM debian:11 as build

RUN apt update -y && apt install -y build-essential \
        libcurl4-openssl-dev \
        liblzma-dev \
        libssl-dev \
        python-dev-is-python3 \
        python3-pip \
        curl \
    && rm -rf /var/lib/apt/lists/*

ARG MONGO_VERSION=6.0.13

RUN mkdir /src && \
    curl -o /tmp/mongo.tar.gz -L "https://github.com/mongodb/mongo/archive/refs/tags/r${MONGO_VERSION}.tar.gz" && \
    tar xaf /tmp/mongo.tar.gz --strip-components=1 -C /src && \
    rm /tmp/mongo.tar.gz

WORKDIR /src

COPY ./o2_patch.diff /o2_patch.diff
RUN patch -p1 < /o2_patch.diff

ARG NUM_JOBS=1

RUN export GIT_PYTHON_REFRESH=quiet && \
    python3 -m pip install --trusted-host pypi.org --trusted-host files.pythonhosted.org requirements_parser && \
    python3 -m pip install --trusted-host pypi.org --trusted-host files.pythonhosted.org -r etc/pip/compile-requirements.txt && \
    if [ "${NUM_JOBS}" -gt 0 ]; then export JOBS_ARG="-j ${NUM_JOBS}"; fi && \
    python3 buildscripts/scons.py install-devcore MONGO_VERSION="${MONGO_VERSION}" --release --disable-warnings-as-errors ${JOBS_ARG} && \
    mv build/install /install && \
    strip --strip-debug /install/bin/mongo && \
    strip --strip-debug /install/bin/mongod && \
    strip --strip-debug /install/bin/mongos && \
    rm -rf build

FROM debian:11

RUN apt update -y && \
    apt install -y libcurl4 && \
    apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /install/bin/mongo* /usr/local/bin/

# grab gosu for easy step-down from root (https://github.com/tianon/gosu/releases)
ENV GOSU_VERSION 1.16
# grab "js-yaml" for parsing mongod's YAML config files (https://github.com/nodeca/js-yaml/releases)
ENV JSYAML_VERSION 3.13.1

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		ca-certificates \
		gnupg \
		jq \
		numactl \
		procps \
	; \
	rm -rf /var/lib/apt/lists/*

RUN set -ex; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
        curl \
        openssl \
        ca-certificates \
	; \
	rm -rf /var/lib/apt/lists/*; \
	\
	dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
	curl -L -k -o /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
	curl -L -k -o /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
	gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
	gpgconf --kill all; \
	rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
	\
	curl -L -k -o /js-yaml.js "https://github.com/nodeca/js-yaml/raw/${JSYAML_VERSION}/dist/js-yaml.js"; \
# TODO some sort of download verification here
	\
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark > /dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	\
# smoke test
	chmod +x /usr/local/bin/gosu; \
	gosu --version; \
	gosu nobody true

RUN mkdir /docker-entrypoint-initdb.d
#RUN mkdir -p /data/db && \
#    chmod -R 750 /data && \
#    chown -R 999:999 /data

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN set -eux; \
	groupadd --gid 999 --system mongodb; \
	useradd --uid 999 --system --gid mongodb --home-dir /data/db mongodb; \
	mkdir -p /data/db /data/configdb; \
	chown -R mongodb:mongodb /data/db /data/configdb

#USER mongodb

VOLUME /data/db /data/configdb

# ensure that if running as custom user that "mongosh" has a valid "HOME"
# https://github.com/docker-library/mongo/issues/524
ENV HOME /data/db

COPY docker-entrypoint.sh /usr/local/bin/
RUN sed -i 's/\r$//' /usr/local/bin/docker-entrypoint.sh && \
    chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 27017
CMD ["mongod"]

#ENTRYPOINT [ "/usr/local/bin/mongod" ]
