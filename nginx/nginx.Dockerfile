FROM nginx:1.31

RUN ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime \
    && dpkg-reconfigure -fnoninteractive tzdata

COPY cert /cert/
COPY diffie-hellman-params /diffie-hellman-params/