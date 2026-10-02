#!/bin/bash
# rsyslog escribe los intentos de SSH en /var/log/auth.log
rsyslogd
service ssh start
service nginx start
/var/ossec/bin/wazuh-control start
tail -f /var/ossec/logs/ossec.log
