ARG PG_MAJOR=18
FROM postgres:${PG_MAJOR}

# Allow passwordless connections — safe for local test containers only.
ENV POSTGRES_HOST_AUTH_METHOD=trust

# Which database this image carries, and the role that owns it. Both come from
# the devops config for the app (scala.development.database), passed through by
# bin/db-image — nothing about a specific app is baked into this file.
ARG DB_NAME
ARG DB_ROLE=api
ENV DB_NAME=${DB_NAME}
ENV DB_ROLE=${DB_ROLE}

# The build context is assembled by bin/db-image: the generic recipe from
# devops/db-image plus the schema repo's artifacts, all at fixed names. That
# indirection exists because COPY cannot reach outside the context, and the
# recipe and the artifacts live in different repositories.
#
# journal-settings.sql is always present but is EMPTY for an app with no
# journal schema — optionality is a zero-byte file rather than a conditional,
# so there is one code path here and in the init script.
COPY schema.sql              /schema/schema.sql
COPY seed.sql                /schema/seed.sql
COPY sem-tracking.sql        /schema/sem-tracking.sql
COPY journal-settings.sql    /schema/journal-settings.sql
COPY transfer-ownership.sql  /schema/transfer-ownership.sql

# Init script runs once on first container start, before connections open.
COPY initdb/10-schema.sh /docker-entrypoint-initdb.d/10-schema.sh
RUN chmod +x /docker-entrypoint-initdb.d/10-schema.sh
