FROM debian:bookworm-slim AS builder

RUN apt update && apt install -y build-essential gcc wget


RUN wget https://github.com/troglobit/mcjoin/releases/download/v2.12/mcjoin-2.12.tar.gz
RUN tar -xzf mcjoin-2.12.tar.gz
WORKDIR /mcjoin-2.12
RUN ./configure
RUN make -j5
RUN make install-strip

# Build stage for GoTTY
FROM golang AS gotty-builder

# Install git for go install to fetch the repository
RUN apt install -y git

# Install GoTTY from source
RUN go install github.com/sorenisanerd/gotty@v1.5.0

# Final image
FROM debian:bookworm-slim

EXPOSE 22 80 443 1180 11443 8080

# Install some tools in the container and generate self-signed SSL certificates.
# Packages are listed in alphabetical order, for ease of readability and ease of maintenance.
RUN     apt-get update \
    &&  apt-get install -y apache2-utils bash bind9-dnsutils busybox curl \
    dnsmasq dropbear-bin ethtool freeradius git golang ifupdown iperf iperf3 \
    iproute2 iputils-ping jq lftp mtr net-tools netcat-openbsd \
    nginx nmap openntpd openssh-client openssl libnet-telnet-perl \
    postgresql-client procps rsync socat sudo tcpdump tcptraceroute \
    tshark wget gettext-base python3-scapy liboping-dev fping dsniff \
    &&  mkdir /certs /docker \
    &&  chmod 700 /certs \
    &&  openssl req \
    -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout /certs/server.key -out /certs/server.crt -subj '/CN=localhost'

RUN wget https://github.com/osrg/gobgp/releases/download/v3.25.0/gobgp_3.25.0_linux_amd64.tar.gz
RUN mkdir -p /usr/local/gobgp
RUN tar -C /usr/local/gobgp -xzf gobgp_3.25.0_linux_amd64.tar.gz
RUN cp /usr/local/gobgp/gobgp* /usr/bin/

COPY --from=builder /usr/local/bin/mcjoin /usr/local/bin/

RUN rm /etc/motd

###
# set a password to SSH into the docker container with
RUN useradd -m -d /home/user -s /bin/bash user

# Add user to sudo group and enable passwordless sudo
RUN apt-get install -y sudo && \
    usermod -aG sudo user && \
    echo "user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/user && \
    chmod 0440 /etc/sudoers.d/user

RUN echo 'user:multit00l' | chpasswd

# copy a basic but nicer than standard bashrc for the user
COPY .bashrc /home/user/.bashrc
RUN chown user:user /home/user/.bashrc
# Ensure .bashrc is sourced by creating a .bash_profile that sources .bashrc
RUN echo 'if [ -f ~/.bashrc ]; then . ~/.bashrc; fi' > /home/user/.bash_profile

# Change ownership of the home directory to the user
RUN chown -R user:user /home/user
###

COPY index.html /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/nginx.conf

# copy the bashrc file to the root user's home directory
COPY .bashrc /root/.bashrc
RUN echo 'if [ -f ~/.bashrc ]; then . ~/.bashrc; fi' > /root/.bash_profile

# Copy GoTTY binary from the build stage
COPY --from=gotty-builder /go/bin/gotty /usr/local/bin/
RUN chmod +x /usr/local/bin/gotty

# Create directories for GoTTY service
RUN mkdir -p /var/run/gotty /var/log/gotty

COPY gotty-service /usr/local/bin/gotty-service
RUN chmod +x /usr/local/bin/gotty-service

#RUN curl -LsSf https://astral.sh/uv/install.sh | sh
#RUN source /home/user/.local/bin/env
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
RUN git clone https://github.com/heitzli/arp-spoofing.git /home/user/arp-spoofing
#RUN cp /home/user/arp-spoofing/spoofer.py /home/user
#RUN rm -rf arp-spoofing
WORKDIR /home/user/arp-spoofing
RUN uv sync
WORKDIR /
COPY entrypoint.sh /docker/entrypoint.sh

# Set up dropbear SSH server
RUN mkdir -p /dropbear && \
    chmod 700 /dropbear && \
    dropbearkey -t rsa -f /dropbear/dropbear_rsa_host_key && \
    dropbearkey -t ecdsa -f /dropbear/dropbear_ecdsa_host_key && \
    dropbearkey -t ed25519 -f /dropbear/dropbear_ed25519_host_key

# Create nginx user for the web server
RUN adduser --system --no-create-home --shell /bin/false --group --disabled-login nginx

# Start nginx in foreground (pass CMD to docker entrypoint.sh):
CMD ["/usr/sbin/nginx", "-g", "daemon off;"]

# Run the startup script as ENTRYPOINT, which does few things and then starts nginx.
ENTRYPOINT ["/bin/sh", "/docker/entrypoint.sh"]
