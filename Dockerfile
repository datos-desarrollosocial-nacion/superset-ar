#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

######################################################################
# PY stage that simply does a pip install on our requirements
######################################################################
ARG PY_VER=3.8.12
FROM python:${PY_VER} AS superset-py

RUN mkdir /app \
  && apt-get update -y \
  && apt-get install -y --no-install-recommends \
  build-essential \
  default-libmysqlclient-dev \
  libpq-dev \
  libsasl2-dev \
  libecpg-dev \
  && rm -rf /var/lib/apt/lists/*

# First, we just wanna install requirements, which will allow us to utilize the cache
# in order to only build if and only if requirements change
COPY ./superset/requirements/*.txt  /app/requirements/
COPY superset/setup.py superset/MANIFEST.in superset/README.md /app/
COPY superset/superset-frontend/package.json /app/superset-frontend/
RUN cd /app \
  && mkdir -p superset/static \
  && touch superset/static/version_info.json \
  && pip install --no-cache -r requirements/local.txt \
  && pip install --no-cache psycopg2-binary


######################################################################
# Node stage to deal with static asset construction
######################################################################
FROM node:16 AS superset-node

ARG NPM_VER=7
RUN npm install -g npm@${NPM_VER}

ARG NPM_BUILD_CMD="build"
ENV BUILD_CMD=${NPM_BUILD_CMD}

# NPM ci first, as to NOT invalidate previous steps except for when package.json changes
RUN mkdir -p /app/superset-frontend
  
COPY ./superset/docker/frontend-mem-nag.sh /
COPY ./superset/superset-frontend /app/superset-frontend
COPY ./mapa-arg/countries.ts /app/superset-frontend/plugins/legacy-plugin-chart-country-map/src/countries.ts
COPY ./mapa-arg/argentina.geojson /app/superset-frontend/plugins/legacy-plugin-chart-country-map/src/countries/argentina.geojson


# custom images
COPY ./images/ /app/superset-frontend/src/assets/images/
COPY ./locales/D3Formatting.ts /app/superset-frontend/packages/superset-ui-chart-controls/src/utils/
COPY ./locales/controls.jsx /app/superset-frontend/src/explore/
COPY ./locales/setupFormatters.ts /app/superset-frontend/src/setup/ 

RUN /frontend-mem-nag.sh \
  && cd /app/superset-frontend \
  && npm ci

COPY ./locales/defaultLocale.js /app/superset-frontend/node_modules/d3-time-format/src/defaultLocale.js

# This seems to be the most expensive step
RUN cd /app/superset-frontend \
  && npm run ${BUILD_CMD} \
  && rm -rf node_modules

######################################################################
# Final lean image...
######################################################################
ARG PY_VER=3.8.12
FROM python:${PY_VER} AS lean

ENV LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
  FLASK_ENV=production \
  FLASK_APP="superset.app:create_app()" \
  PYTHONPATH="/app/pythonpath" \
  SUPERSET_HOME="/app/superset_home" \
  SUPERSET_PORT=8088

RUN mkdir -p ${PYTHONPATH} \
  && useradd --user-group -d ${SUPERSET_HOME} -m --no-log-init --shell /bin/bash superset \
  && apt-get update -y \
  && apt-get install -y --no-install-recommends \
  build-essential \
  default-libmysqlclient-dev \
  libsasl2-modules-gssapi-mit \
  libpq-dev \
  libecpg-dev \
  && rm -rf /var/lib/apt/lists/*

COPY --from=superset-py /usr/local/lib/python3.8/site-packages/ /usr/local/lib/python3.8/site-packages/
# Copying site-packages doesn't move the CLIs, so let's copy them one by one
COPY --from=superset-py /usr/local/bin/gunicorn /usr/local/bin/celery /usr/local/bin/flask /usr/bin/
COPY --from=superset-node /app/superset/static/assets /app/superset/static/assets
COPY --from=superset-node /app/superset-frontend /app/superset-frontend

## Lastly, let's install superset itself
COPY superset/superset /app/superset
COPY superset/setup.py superset/MANIFEST.in superset/README.md /app/
RUN cd /app \
  && chown -R superset:superset * \
  && pip install -e . \
  && flask fab babel-compile --target superset/translations

# basic template mod
COPY ./basic.html /app/superset/templates/superset/basic.html


COPY ./superset/docker/run-server.sh /usr/bin/

RUN chmod a+x /usr/bin/run-server.sh

WORKDIR /app

USER superset

HEALTHCHECK CMD curl -f "http://localhost:$SUPERSET_PORT/health"

EXPOSE ${SUPERSET_PORT}

CMD /usr/bin/run-server.sh

######################################################################
# Dev image...
######################################################################
FROM lean AS dev
ARG GECKODRIVER_VERSION=v0.28.0
ARG FIREFOX_VERSION=88.0

COPY ./superset/requirements/*.txt ./superset/docker/requirements-*.txt/ /app/requirements/

USER root

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libnss3 libdbus-glib-1-2 libgtk-3-0 libx11-xcb1

# Install GeckoDriver WebDriver
RUN wget https://github.com/mozilla/geckodriver/releases/download/${GECKODRIVER_VERSION}/geckodriver-${GECKODRIVER_VERSION}-linux64.tar.gz -O /tmp/geckodriver.tar.gz && \
  tar xvfz /tmp/geckodriver.tar.gz -C /tmp && \
  mv /tmp/geckodriver /usr/local/bin/geckodriver && \
  rm /tmp/geckodriver.tar.gz

# Install Firefox
RUN wget https://download-installer.cdn.mozilla.net/pub/firefox/releases/${FIREFOX_VERSION}/linux-x86_64/en-US/firefox-${FIREFOX_VERSION}.tar.bz2 -O /opt/firefox.tar.bz2 && \
  tar xvf /opt/firefox.tar.bz2 -C /opt && \
  ln -s /opt/firefox/firefox /usr/local/bin/firefox

# Cache everything for dev purposes...
RUN cd /app \
  && pip install --no-cache -r requirements/docker.txt \
  && pip install --no-cache -r requirements/requirements-local.txt || true
USER superset

######################################################################
# CI image...
######################################################################
FROM lean AS ci

COPY --chown=superset ./superset/docker/docker-bootstrap.sh /app/docker/
COPY --chown=superset ./superset/docker/docker-init.sh /app/docker/
COPY --chown=superset ./superset/docker/docker-ci.sh /app/docker/

RUN chmod a+x /app/docker/*.sh

CMD /app/docker/docker-ci.sh
