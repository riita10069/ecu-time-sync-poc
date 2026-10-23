FROM docker.io/library/debian:bookworm-slim
ARG NTPD_RS_VERSION=1.9.0
# ntpd-rs の deb は chrony と競合するので、バイナリだけ取り出して置く
RUN apt-get update \
 && apt-get install -y --no-install-recommends chrony python3 python3-cryptography ca-certificates iproute2 openssl curl \
 && arch=$(dpkg --print-architecture) \
 && curl -fsSL -o /tmp/ntpd-rs.deb "https://github.com/pendulum-project/ntpd-rs/releases/download/v${NTPD_RS_VERSION}/ntpd-rs_${NTPD_RS_VERSION}-1_${arch}.deb" \
 && dpkg -x /tmp/ntpd-rs.deb /tmp/ntpd-rs && cp /tmp/ntpd-rs/usr/bin/ntp-* /usr/local/bin/ && rm -rf /tmp/ntpd-rs \
 && rm -rf /var/lib/apt/lists/* /tmp/ntpd-rs.deb
WORKDIR /poc
COPY app /poc/app
COPY config /poc/config
COPY scripts /poc/scripts
