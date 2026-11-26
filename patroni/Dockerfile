FROM postgres:16.3

# Patroni runs inside the same image as Postgres, in its own virtualenv.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv curl \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m venv /opt/patroni \
 && /opt/patroni/bin/pip install --no-cache-dir "patroni[etcd3]" psycopg2-binary

ENV PATH="/opt/patroni/bin:${PATH}"

# Patroni needs a data directory it owns, with 0700 permissions.
RUN mkdir -p /data/pg /archive /backups \
 && chown postgres:postgres /data/pg /archive /backups && chmod 700 /data/pg
USER postgres
ENTRYPOINT ["patroni", "/config/patroni.yml"]
