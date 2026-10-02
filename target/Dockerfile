FROM ubuntu:24.04

# Debe coincidir con la versión del manager
ARG WAZUH_VERSION=4.14.8

RUN apt-get update && apt-get install -y \
    curl gnupg apt-transport-https lsb-release openssh-server sudo rsyslog \
    nginx openssl \
    && mkdir /var/run/sshd \
    && useradd -m -s /bin/bash demo && echo "demo:demo123" | chpasswd \
    && curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import \
    && chmod 644 /usr/share/keyrings/wazuh.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list \
    && apt-get update && WAZUH_MANAGER='wazuh.manager' apt-get install -y wazuh-agent=${WAZUH_VERSION}-1 \
    && apt-get clean

COPY auth-log-localfile.xml /tmp/auth-log-localfile.xml
RUN cat /tmp/auth-log-localfile.xml >> /var/ossec/etc/ossec.conf && rm /tmp/auth-log-localfile.xml
COPY nginx-log-localfile.xml /tmp/nginx-log-localfile.xml
RUN cat /tmp/nginx-log-localfile.xml >> /var/ossec/etc/ossec.conf && rm /tmp/nginx-log-localfile.xml

# Sitio de ejemplo con un /.env expuesto a propósito (credenciales falsas)
RUN mkdir -p /etc/nginx/ssl \
    && openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/target.key -out /etc/nginx/ssl/target.crt \
        -subj "/CN=target-endpoint"
COPY nginx-site.conf /etc/nginx/sites-available/default
COPY web/ /var/www/vuln-web/
COPY rsyslog-nginx.conf /etc/rsyslog.d/49-nginx.conf

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 443
ENTRYPOINT ["/entrypoint.sh"]
