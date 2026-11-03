# Policy-enforcing egress proxy for pi-sandbox.
#
# The proxy is the only container joined to a public network. Sandbox
# containers reach it on the internal pi-egress network. Keep this image small:
# it only needs the Python standard library.
ARG BASE_IMAGE=python:3.12-slim
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

COPY egress_proxy.py /usr/local/bin/pi-egress-proxy
RUN chmod 0755 /usr/local/bin/pi-egress-proxy

USER 1000:1000
EXPOSE 3128
HEALTHCHECK --interval=10s --timeout=3s --start-period=2s --retries=3 \
    CMD ["python3", "-c", "import socket; s=socket.create_connection(('127.0.0.1',3128),2); s.close()"]

ENTRYPOINT ["python3", "/usr/local/bin/pi-egress-proxy"]
