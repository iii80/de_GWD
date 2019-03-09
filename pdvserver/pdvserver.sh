#!/bin/bash
clear
function blue()   { echo -e "\033[34m\033[01m $1 \033[0m"; }
function yellow() { echo -e "\033[33m\033[01m $1 \033[0m"; }
function green()  { echo -e "\033[32m\033[01m $1 \033[0m"; }
function red()    { echo -e "\033[31m\033[01m $1 \033[0m"; }



performance_mod(){
sed -i '/GRUB_CMDLINE_LINUX_DEFAULT=/c\GRUB_CMDLINE_LINUX_DEFAULT="quiet splash zswap.enabled=1 zswap.compressor=lz4"'  /etc/default/grub
update-grub
echo "net.ipv4.tcp_fastopen = 3" >> /etc/sysctl.conf
echo "net.ipv4.tcp_syn_retries = 2" >> /etc/sysctl.conf
echo "net.ipv4.tcp_max_syn_backlog = 16384" >> /etc/sysctl.conf
echo "net.ipv4.tcp_synack_retries = 2" >> /etc/sysctl.conf
echo "net.ipv4.tcp_timestamps = 0" >> /etc/sysctl.conf
echo "net.ipv4.tcp_fin_timeout = 10" >> /etc/sysctl.conf

echo "net.ipv4.tcp_keepalive_time = 600" >> /etc/sysctl.conf
echo "net.ipv4.tcp_keepalive_intvl = 60" >> /etc/sysctl.conf
echo "net.ipv4.tcp_keepalive_probes = 20" >> /etc/sysctl.conf

echo "fs.file-max = 99000" >> /etc/sysctl.conf
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbrplus" >> /etc/sysctl.conf
sysctl -p
}



install_nginx+tls+pihole+doh+v2ray(){
    green "=============================="
    green " 输入此VPS的域名(不加www开头)"
    green "=============================="
    read vpsdomain

    green "================="
    green " 此VPS有几个线程"
    green "================="
    read workprocess

    green "============"
    green " v2ray uuid"
    green "============"
    read uuidnum

    green "========================="
    green " v2ray path (格式：/xxxx)"
    green "========================="
    read v2path

apt-get install -y nginx socat

cat > /etc/nginx/nginx.conf << EOF
user  www-data www-data;
worker_processes $workprocess;

events {
    use epoll;
    worker_connections  8192;
    multi_accept on;
}

http {
  include mime.types;
  default_type application/octet-stream;

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;

  types_hash_max_size 2048;
  server_names_hash_bucket_size 128;
  large_client_header_buffers 4 32k;
  client_header_buffer_size 32k;
  client_header_timeout 12;
  client_max_body_size 50m;
  client_body_timeout 12;
  keepalive_timeout 60;
  send_timeout 10;

  gzip              on;
  gzip_comp_level   2;
  gzip_min_length   1k;
  gzip_buffers      4 16k;
  gzip_http_version 1.1;
  gzip_proxied      expired no-cache no-store private auth;
  gzip_types        text/plain application/javascript application/x-javascript text/javascript text/css application/xml application/xml+rss;
  gzip_vary         on;
  gzip_disable      "MSIE [1-6]\.";

  access_log off;
  error_log off;

  include /etc/nginx/conf.d/*.conf;
}
EOF

cat > /etc/nginx/conf.d/default.conf<< EOF
server {
    listen       80;
    server_name  $vpsdomain;
    root /var/www/html;
    index index.php index.html index.htm;
}
EOF

systemctl restart nginx

mkdir /var/www/ssl
curl https://get.acme.sh | sh
~/.acme.sh/acme.sh --issue -d $vpsdomain -w /var/www/html
~/.acme.sh/acme.sh --installcert -d $vpsdomain \
               --keypath       /var/www/ssl/$vpsdomain.key  \
               --fullchainpath /var/www/ssl/$vpsdomain.key.pem \
               --reloadcmd     "systemctl restart nginx"
openssl dhparam -out /var/www/ssl/dhparam.pem 2048
openssl x509 -outform der -in /var/www/ssl/$vpsdomain.key.pem -out /var/www/ssl/$vpsdomain.crt


cat > /var/www/ssl/update_ocsp_cache << EOF
#!/bin/bash
wget -O intermediate.pem https://letsencrypt.org/certs/lets-encrypt-x3-cross-signed.pem
wget -O root.pem https://ssl-tools.net/certificates/dac9024f54d8f6df94935fb1732638ca6ad77c13.pem
mv intermediate.pem /var/www/ssl
mv root.pem /var/www/ssl
cat /var/www/ssl/intermediate.pem > /var/www/ssl/bundle.pem
cat /var/www/ssl/root.pem >> /var/www/ssl/bundle.pem

openssl ocsp -no_nonce \
    -issuer  /var/www/ssl/intermediate.pem \
    -cert    /var/www/ssl/$vpsdomain.key.pem \
    -CAfile  /var/www/ssl/bundle.pem \
    -VAfile  /var/www/ssl/bundle.pem \
    -url     http://ocsp.int-x3.letsencrypt.org \
    -respout /var/www/ssl/ocsp.resp
EOF
chmod +x /var/www/ssl/update_ocsp_cache
/var/www/ssl/update_ocsp_cache

cat > /usr/local/updatepdv << EOF
#!/bin/bash
bash <(curl -L -s https://install.direct/go.sh)
EOF
chmod +x /usr/local/updatepdv

crontab -l > now.cron
echo '0 0 * * 7 /var/www/ssl/update_ocsp_cache' >> now.cron
echo '0 0 * * * /usr/local/updatepdv' >> now.cron
crontab now.cron

cat > /etc/nginx/conf.d/default.conf<< EOF
upstream dns-backend {
  server 127.0.0.1:8053;
}

server {
  listen 80;
  server_name $vpsdomain www.$vpsdomain;
  root /var/www/html;
  index index.html index.htm index.nginx-debian.html;

  access_log off;
}

server {
  listen 443 ssl http2;
  server_name $vpsdomain www.$vpsdomain;
  root /var/www/html;
  index index.html index.htm index.nginx-debian.html;

  ssl on;
  ssl_certificate /var/www/ssl/$vpsdomain.key.pem;
  ssl_certificate_key /var/www/ssl/$vpsdomain.key;
  ssl_session_timeout 5m;
  ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
  ssl_prefer_server_ciphers on;
  ssl_ciphers "EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5";
  ssl_session_cache builtin:1000 shared:SSL:10m;
  ssl_dhparam /var/www/ssl/dhparam.pem;
  
  # OCSP Stapling ---
  ssl_stapling on;
  ssl_stapling_verify on;
  ssl_trusted_certificate /var/www/ssl/bundle.pem;
  ssl_stapling_file /var/www/ssl/ocsp.resp;
  resolver 8.8.8.8 valid=600s;
  resolver_timeout 5s;

location /dq {
  proxy_http_version 1.1;
  proxy_set_header Upgrade \$http_upgrade;
  proxy_set_header Connection "Upgrade";
  proxy_set_header Host "$vpsdomain";
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  sendfile                on;
  tcp_nopush              on;
  tcp_nodelay             on;
  keepalive_requests      25600;
  keepalive_timeout       300 300;
  proxy_buffering         off;
  proxy_buffer_size       8k;
  proxy_intercept_errors  on;
  proxy_pass http://dns-backend/dq;
}

location $v2path {
  proxy_http_version 1.1;
  proxy_set_header Upgrade "WebSocket";
  proxy_set_header Connection "Upgrade";
  proxy_set_header Host "$vpsdomain";
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  sendfile                on;
  tcp_nopush              on;
  tcp_nodelay             on;
  keepalive_requests      25600;
  keepalive_timeout       300 300;
  proxy_buffering         off;
  proxy_buffer_size       8k;
  proxy_intercept_errors  on;
  proxy_pass              http://127.0.0.1:11811;
}
  access_log off;
}
EOF
mkdir /etc/systemd/system/nginx.service.d
printf "[Service]\nExecStartPost=/bin/sleep 0.1\n" > /etc/systemd/system/nginx.service.d/override.conf
systemctl daemon-reload
systemctl restart nginx



bash <(curl -L -s https://install.direct/go.sh)
wget https://raw.githubusercontent.com/jacyl4/linux-router/master/pdvserver/v2wt-server.json
mv -f v2wt-server.json /etc/v2ray/config.json
sed -i '/"address":/c\"address": "'$vpsdomain'",'  /etc/v2ray/config.json
sed -i '/"serverName":/c\"serverName": "'$vpsdomain'",'  /etc/v2ray/config.json
sed -i '/"Host":/c\"Host": "'$vpsdomain'"'  /etc/v2ray/config.json
sed -i '/"id":/c\"id": "'$uuidnum'",'  /etc/v2ray/config.json
sed -i '/"path":/c\"path": "'$v2path'"'  /etc/v2ray/config.json
systemctl restart v2ray
systemctl enable v2ray



curl -sSL https://install.pi-hole.net | bash

apt-get install -y git make gcc
wget https://dl.google.com/go/go1.11.5.linux-amd64.tar.gz
tar -xvf go1.11.5.linux-amd64.tar.gz
mv go /usr/local
mkdir ~/gopath
cat >> ~/.profile << "EOF"
export GOROOT=/usr/local/go
export GOPATH=~/gopath
export PATH=$GOPATH/bin:$GOROOT/bin:$PATH
EOF
source ~/.profile
git clone https://github.com/m13253/dns-over-https.git
cd dns-over-https
make && make install
wget https://raw.githubusercontent.com/jacyl4/linux-router/master/pdvserver/doh-client.conf
wget https://raw.githubusercontent.com/jacyl4/linux-router/master/pdvserver/doh-server.conf
mv -f doh-client.conf /etc/dns-over-https/
mv -f doh-server.conf /etc/dns-over-https/
systemctl restart doh-client
systemctl enable doh-client
systemctl restart doh-server
systemctl enable doh-server

sed -i '/PIHOLE_DNS_1=/c\PIHOLE_DNS_1=127.0.0.1#5380'  /etc/pihole/setupVars.conf
sed -i '/server=/d'  /etc/dnsmasq.d/01-pihole.conf
echo "server=127.0.0.1#5380" >> /etc/dnsmasq.d/01-pihole.conf
pihole restartdns
systemctl restart pihole-FTL

ethernetnum="$(awk 'NR==39{print $2}' /etc/dhcpcd.conf)"
localaddr="$(awk -F '[=]' 'NR==40{print $2}' /etc/dhcpcd.conf | cut -d '/' -f1)"
gatewayaddr="$(awk -F '[=]' 'NR==41{print $2}' /etc/dhcpcd.conf | cut -d '/' -f1)"
sed -i "/static ip_address=/c\static ip_address=$localaddr/24" /etc/dhcpcd.conf
sed -i "/static routers=/c\static routers=$gatewayaddr" /etc/dhcpcd.conf
sed -i "/static domain_name_servers=/c\static domain_name_servers=127.0.0.1" /etc/dhcpcd.conf
sed -i '/nameserver/c\nameserver 127.0.0.1'  /etc/resolv.conf
cat > /etc/network/interfaces << EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto $ethernetnum
iface $ethernetnum inet static
  address $localaddr
  netmask 255.255.255.0
  gateway $gatewayaddr
  mtu 1488
EOF
sed -i '/nameserver/c\nameserver 127.0.0.1'  /etc/resolv.conf
}



start_menu(){
    green "========================================"
    green "              服务端                  "
    green "介绍：一条龙安装v2ray+ws+tls+doh+pihole "
    green "系统：Debian9                         "
    green "作者：jacyl4                          "
    green "网站：jacyl4.github.io                "
    green "========================================"
    echo
    green  "1. 优化性能与网络"
    green  "2. 安装nginx+tls+pihole+doh+v2ray"
    yellow "CTRL+C退出"
    echo
    read -p "请输入数字:" num
    case "$num" in
    1)
    performance_mod
    start_menu
    ;;
    2)
    install_nginx+tls+pihole+doh+v2ray
    start_menu
    ;;
    *)
    clear
    red "请输入正确数字"
    sleep 1s
    start_menu
    ;;
    esac
}

start_menu