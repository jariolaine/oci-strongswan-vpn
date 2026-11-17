FROM ubuntu:26.04

# Run charon directly with swanctl/VICI; configure route-based VPN over XFRM
# interfaces managed by xfrm.sh. No legacy starter, VTI or systemd.
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       strongswan-charon strongswan-swanctl bird2 \
       iproute2 iptables procps mawk util-linux \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /run/bird /etc/bird /etc/swanctl /run/strongswan-xfrm

COPY ./docker/bird.conf.template /tmp/bird.conf.template
COPY ./docker/swanctl.conf.template /tmp/swanctl.conf.template
COPY ./docker/charon.conf /etc/strongswan.d/oci-vpn.conf
COPY ./docker/xfrm.sh /usr/local/bin/xfrm.sh
COPY ./docker/snat.sh /usr/local/bin/snat.sh
COPY ./docker/render-config.sh /usr/local/bin/render-config.sh
COPY ./docker/entrypoint.sh /entrypoint.sh

RUN chmod 700 /usr/local/bin/xfrm.sh /usr/local/bin/snat.sh \
              /usr/local/bin/render-config.sh /entrypoint.sh \
  && test -x /usr/lib/ipsec/charon \
  && command -v swanctl \
  && command -v bird \
  && test -f /usr/lib/ipsec/plugins/libstrongswan-vici.so

ENTRYPOINT ["/entrypoint.sh"]
