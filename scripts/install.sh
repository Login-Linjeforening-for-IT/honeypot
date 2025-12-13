#!/bin/bash

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Use sudo." >&2
    exit 2
fi

INVOKING_USER="${SUDO_USER:-root}"
INVOKING_UID="$(id -u "$INVOKING_USER")"
INVOKING_GID="$(id -g "$INVOKING_USER")"

echo "🐝 Invoking user: $INVOKING_USER"

# ----- Upgrades VM to latest -----

apt update
DEBIAN_FRONTEND=noninteractive apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
DEBIAN_FRONTEND=noninteractive apt autoremove -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

# ----- Adds swap -----

SWAPFILE="/bee"

# Checks if swap is already active
if swapon --show=NAME | grep -qx "$SWAPFILE"; then
    echo "Swap $SWAPFILE is already active. Skipping."
fi

# Checks if swap file exists but is not active
if [[ -f "$SWAPFILE" ]]; then
    echo "Swap file $SWAPFILE exists but is not active."
    swapon "$SWAPFILE"
else
    echo "Creating swap file $SWAPFILE"

    fallocate -l 4G "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    swapon "$SWAPFILE"
fi

# Ensures fstab entry exists
if ! grep -qE "^\Q$SWAPFILE\E\s+none\s+swap" /etc/fstab; then
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
fi

# ----- Creates scripts folder -----

mkdir -p /home/$INVOKING_USER/scripts

cat << 'EOF' > /home/$INVOKING_USER/scripts/docker_clean.sh
#!/bin/bash
docker system prune -a --volumes -f
EOF

chmod +x /home/$INVOKING_USER/scripts/docker_clean.sh

# ----- Installs docker -----

apt update
DEBIAN_FRONTEND=noninteractive apt install -y ca-certificates curl gnupg lsb-release -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

mkdir -p /etc/apt/keyrings
[ -f /etc/apt/keyrings/docker.gpg ] || \
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
DEBIAN_FRONTEND=noninteractive apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

usermod -aG docker $INVOKING_USER
su - $INVOKING_USER -c "docker version && docker compose version"

# ----- Installs openresty -----

DEBIAN_FRONTEND=noninteractive apt install -y build-essential \
    libpcre3 libpcre3-dev zlib1g-dev \
    libssl-dev \
    perl \
    make \
    curl \
    unzip \
    wget \
    luarocks \
    git -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

wget https://openresty.org/download/openresty-1.27.1.1.tar.gz
tar zxvf openresty-1.27.1.1.tar.gz
rm openresty-1.27.1.1.tar.gz
cd openresty-1.27.1.1

./configure \
    --prefix=/usr/local/openresty \
    --with-http_ssl_module \
    --with-pcre-jit \
    --with-http_v2_module \
    --with-stream \
    --with-luajit

gmake
gmake install
echo 'export PATH=/usr/local/openresty/nginx/sbin:$PATH' >> /home/$INVOKING_USER/.bashrc
source /home/$INVOKING_USER/.bashrc
echo 'export PATH=/usr/local/openresty/bin:/usr/local/openresty/nginx/sbin:$PATH' >> /home/$INVOKING_USER/.bashrc
source /home/$INVOKING_USER/.bashrc
export PATH=/usr/local/openresty/bin:/usr/local/openresty/nginx/sbin:$PATH
openresty -v

# ----- Enables default site -----

sudo mkdir -p /usr/local/openresty/nginx/sites-enabled
sudo ln -sf /usr/local/openresty/nginx/sites-available/default /usr/local/openresty/nginx/sites-enabled/default

# ----- Adds error file -----
sudo mkdir -p /usr/local/openresty/nginx/conf/snippets

cat > /usr/local/openresty/nginx/conf/snippets/errors.conf << 'EOF'
error_page 400 401 403 404 405 406 408 409 410 418 429 451 500 501 502 503 504 /errors/$status.html;

location ^~ /errors/ {
    alias /usr/local/openresty/nginx/sites-available/fallback/;
    internal;
}
EOF

cat > /usr/local/openresty/nginx/conf/snippets/proxy-headers.conf << 'EOF'
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Host $host;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_cache_bypass $http_upgrade;
EOF

# ----- Updates configuration -----

cat > /etc/systemd/system/openresty.service << 'EOF'
[Unit]
Description=OpenResty (Nginx + Lua) Web Server
After=network.target

[Service]
Type=forking
PIDFile=/run/nginx.pid

ExecStart=/usr/local/openresty/bin/openresty
ExecReload=/usr/local/openresty/bin/openresty -s reload
ExecStop=/usr/local/openresty/bin/openresty -s quit

Restart=on-failure
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/openresty/nginx/conf/nginx.conf << 'EOF'
user www-data;
worker_processes auto;
worker_cpu_affinity auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /usr/local/openresty/nginx/modules-enabled/*.conf;

events {
    worker_connections 8192;
    multi_accept on;
}

http {
    lua_package_path "/usr/local/share/lua/5.1/?.lua;;";
    lua_package_cpath "/usr/local/lib/lua/5.1/?.so;;";

    server_names_hash_max_size 2048;
    server_names_hash_bucket_size 128;

    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    server_tokens off;

    include /usr/local/openresty/nginx/conf/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    log_format main '$remote_addr - $remote_user [$time_local] '
        '"$request" $status $body_bytes_sent '
        '"$http_referer" "$http_user_agent" '
        '"$host" "$upstream_addr" "$upstream_status" "$upstream_response_time"';

    access_log /var/log/nginx/access.log main buffer=32k;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 7;
    gzip_buffers 16 8k;
    gzip_min_length 256;
    gzip_http_version 1.1;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    tcp_nodelay on;

    include /usr/local/openresty/nginx/conf.d/*.conf;
    include /usr/local/openresty/nginx/sites-enabled/*;
}
EOF

# ----- Adds lua extensions -----

luarocks install lua-resty-http
luarocks install lua-resty-openssl

# ----- Updates nginx logfile permissions -----

chown -R root:root /usr/local/openresty/nginx
sudo mkdir -p /var/log/nginx
sudo chown www-data:www-data /var/log/nginx
sudo chmod 755 /var/log/nginx

# ----- Starts openresty -----

systemctl daemon-reload
systemctl enable openresty
systemctl start openresty

# ----- Adds current user as nginx editor -----

getent group nginxedit >/dev/null || groupadd nginxedit
usermod -aG nginxedit $INVOKING_USER
chgrp -R nginxedit /usr/local/openresty/nginx
chmod -R g+w /usr/local/openresty/nginx
chmod g+s /usr/local/openresty/nginx

# ----- Adds nvm and node -----

export NVM_DIR="$HOME/.nvm"
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install node
nvm alias default node
node -v
npm -v

# ----- Removes excess motd files -----

rm -f /etc/update-motd.d/50-motd-news
rm -f /etc/update-motd.d/97-overlayroot
rm -f /etc/update-motd.d/98-fsck-at-reboot

# ----- Updates sysinfo file to be more concise -----

cat > /usr/share/landscape/landscape-sysinfo.wrapper << 'EOF'
#!/bin/sh
# don't try refresh this more than once per minute
# Due to cpu consumption and login delays (LP: #1893716)
CACHE="/var/lib/landscape/landscape-sysinfo.cache"
HAS_CACHE="FALSE"
CACHE_NEEDS_UPDATE="FALSE"

[ -r "$CACHE" ] && HAS_CACHE="TRUE"
[ -z "$(find "$CACHE" -newermt 'now-1 minutes' 2> /dev/null)" ] && CACHE_NEEDS_UPDATE="TRUE"

if [ "$HAS_CACHE" = "TRUE" ] && [ "$CACHE_NEEDS_UPDATE" = "FALSE" ]; then
    cat "$CACHE"
else
    SYSINFO=""

    # pam_motd does not carry the environment
    [ -f /etc/default/locale ] && . /etc/default/locale
    export LANG
    CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
    [ "$CORES" -eq "0" ] && CORES=1
    THRESHOLD="${CORES:-1}.0"

    if [ $(echo "`cut -f1 -d ' ' /proc/loadavg` < $THRESHOLD" | bc) -eq 1 ]; then
        SYSINFO=$(printf "\n System information as of %s\n\n%s\n" \
            "$(/bin/date)" \
            "$(/usr/bin/landscape-sysinfo)")
        echo "$SYSINFO" 2>/dev/null >"$CACHE" || true
        chmod 0644 "$CACHE" 2>/dev/null || true
    else
        SYSINFO=$(printf "\n System information disabled due to load higher than %s\n" "$THRESHOLD")

        if [ "$HAS_CACHE" = "TRUE" ]; then
            if ! grep -q "System information as of" $CACHE 2>/dev/null; then
                # do not replace a formerly good result due to load
                echo "$SYSINFO" 2>/dev/null >"$CACHE" || true
                chmod 0644 "$CACHE" 2>/dev/null || true
            else
                SYSINFO=$(cat "$CACHE")
            fi
        fi
    fi

    printf "%s\n" "$SYSINFO"
fi

exit 0
EOF

# ----- Adds cronjob to remove dangling Docker containers -----

( crontab -l 2>/dev/null; \
    echo "# removes dangling docker entities every day at 3am"; \
    echo "0 3 * * * /usr/bin/docker system prune -a --volumes -f >/dev/null 2>&1" \
) | crontab -

# ---- Adds alias -----

cat >> /home/$INVOKING_USER/.bashrc << 'EOF'
alias cert="cat /etc/cron.d/certbot"
alias config="sudo nano ~/.bashrc"
alias dockerrestart="restartdocker"
alias egrep="egrep --color=auto"
alias fgrep="fgrep --color=auto"
alias grep="grep --color=auto"
alias l="ls -CF"
alias la="ls -A"
alias ll="ls -alF"
alias ls="ls --color=auto"
alias lua="sudo nano /usr/local/openresty/nginx/lua/traffic_logger.lua"
alias nginxconf="sudo nano /usr/local/openresty/nginx/conf/nginx.conf"
alias nginxconfig="cd /usr/local/openresty/nginx/sites-available; git pull; sudo nano /usr/local/openresty/nginx/sites-available/default"
alias nginxreload="sudo /usr/local/openresty/nginx/sbin/nginx -s reload"
alias nginxstart="sudo /usr/local/openresty/bin/openresty"
alias nginxstop="sudo /usr/local/openresty/bin/openresty -s stop"
alias nginxtest="sudo /usr/local/openresty/nginx/sbin/nginx -t"
alias scouterbee="cd ~/scouterbee; git pull; pm2 restart scouterbe"
alias internal="cd ~/internal; git pull; pm2 restart internal"
alias rebuild="git pull; docker compose up --build"
alias redeploy="rebuild"
alias reload="source ~/.bashrc"
alias restartdocker="sudo systemctl restart docker"
alias viewcert="sudo certbot certificates"
EOF

source /home/$INVOKING_USER/.bashrc

# ----- Adds DNS services -----

cat > /etc/systemd/resolved.conf << 'EOF'
# 1. sudo nano /etc/systemd/resolved.conf
# 2. sudo systemctl restart systemd-resolved
# 3. resolvectl status

#  This file is part of systemd.
#
#  systemd is free software; you can redistribute it and/or modify it under the
#  terms of the GNU Lesser General Public License as published by the Free
#  Software Foundation; either version 2.1 of the License, or (at your option)
#  any later version.
#
# Entries in this file show the compile time defaults. Local configuration
# should be created by either modifying this file (or a copy of it placed in
# /etc/ if the original file is shipped in /usr/), or by creating "drop-ins" in
# the /etc/systemd/resolved.conf.d/ directory. The latter is generally
# recommended. Defaults can be restored by simply deleting the main
# configuration file and all drop-ins located in /etc/.
#
# Use 'systemd-analyze cat-config systemd/resolved.conf' to display the full config.
#
# See resolved.conf(5) for details.

[Resolve]
Cloudflare: 1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com
Google:     8.8.8.8#dns.google 8.8.4.4#dns.google 2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google
Quad9:      9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net
DNS=8.8.8.8 1.1.1.1 213.186.33.99 10.177.195.1
FallbackDNS=9.9.9.9 1.0.0.1
DNSSEC=no
DNSOverTLS=no
MulticastDNS=no
LLMNR=no
Cache=yes
DNSStubListener=yes
ReadEtcHosts=yes
ResolveUnicastSingleLabel=no
StaleRetentionSec=30
EOF

# ----- Adds DNS services -----

cat > /etc/docker/daemon.json << 'EOF'
{
    "dns": ["8.8.8.8", "1.1.1.1", "10.177.195.1", "213.186.33.99"],
    "registry-mirrors": ["https://mirror.gcr.io"],
    "storage-driver": "overlay2"
}
EOF

# ----- Reduces swap usage -----

cat > /etc/security/sysctl.conf << 'EOF'
vm.swappiness = 30

# Reload with `sudo sysctl --system`
EOF

sysctl --system

# ----- Clones services -----

cd /home/$INVOKING_USER
git clone https://github.com/Login-Linjeforening-for-IT/queenbee.git
git clone https://github.com/Login-Linjeforening-for-IT/beekeeper.git
git clone https://github.com/Login-Linjeforening-for-IT/gitbee.git
git clone https://github.com/Login-Linjeforening-for-IT/beeswarm.git
git clone https://github.com/Login-Linjeforening-for-IT/nucleus_notifications.git
git clone https://github.com/Login-Linjeforening-for-IT/app_api.git
git clone https://github.com/Login-Linjeforening-for-IT/scouterbee.git
git clone https://github.com/Login-Linjeforening-for-IT/workerbee.git
git clone https://github.com/Login-Linjeforening-for-IT/beehive.git
git clone https://github.com/Login-Linjeforening-for-IT/studentbee.git
git clone https://github.com/Login-Linjeforening-for-IT/tekkom_bot.git
git clone https://github.com/Login-Linjeforening-for-IT/beeformed.git
git clone https://github.com/Login-Linjeforening-for-IT/dizambee.git
git clone https://github.com/Login-Linjeforening-for-IT/internal.git
git clone https://github.com/Login-Linjeforening-for-IT/gatherbee.git

# ----- Changes directory to clone nginx config -----

cd /usr/local/openresty/nginx/
git clone https://github.com/Login-Linjeforening-for-IT/nginx.git
mv nginx sites-available

# ----- Installs pm2 -----

npm install -g pm2

# ----- Starts docker services -----

cd /home/$INVOKING_USER/app_api; git pull; docker compose up --build -d
cd /home/$INVOKING_USER/beeformed; git pull; docker compose up --build -d
cd /home/$INVOKING_USER/beehive; git pull; docker compose up --build -d
cd /home/$INVOKING_USER/beekeeper; git pull; docker compose up --build -d
cd /home/$INVOKING_USER/beeswarm; git pull; docker compose up --build -d
cd /home/$INVOKING_USER/dizambee; git pull; docker compose up --build -d
cd /home/$INVOKING_USER/gitbee; git pull; docker compose up --build -d
cd /home/$INVOKING_USER/nucleus_notifications; git pull; docker compose up --build -d
cd /home/$INVOKING_USER/queenbee; git pull; docker compose up --build -d
cd /home/$INVOKING_USER/studentbee; git pull; docker compose up --build -d
cd /home/$INVOKING_USER/tekkom_bot; git pull; docker compose up --build -d
cd /home/$INVOKING_USER/workerbee; git pull; docker compose up --build -d
cd /home/$INVOKING_USER/gatherbee; git pull; docker compose up --build -d

# ----- Starts pm2 services -----

cd /home/$INVOKING_USER/internal; pm2 start src/index.ts --name internal --interpreter node
cd /home/$INVOKING_USER/scouterbee; pm2 start src/index.ts --name scouterbee --interpreter node

# ----- Returns to home dir -----

cd /home/$INVOKING_USER

# ----- Confirms installation -----

echo "🐝 Running containers:"
docker ps

echo "🐝 Listening instances:"
echo "🐝 Port 443:"
lsof -i :443

echo "🐝 Port 80:"
lsof -i :80

echo "🐝 Installation complete."
