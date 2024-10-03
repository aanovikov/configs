#!/bin/bash

### SETTING VARS ###
echo 'INFO: SETTING VARS...'

echo -n "Input username: [proxyuser]: "
read USER_NAME

# check username
if [ -z "$USER_NAME" ]; then
    USER_NAME="proxyuser"
fi

echo "Using username: $USER_NAME"

# Получаем ссылку на последний релиз
LATEST_RELEASE=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep "browser_download_url" | grep "linux-amd64.tar.gz" | cut -d '"' -f 4)

# Извлекаем имя архива и папки
NODE_ARCHIVE=$(basename $LATEST_RELEASE)
NODE_FOLDER=$(echo $NODE_ARCHIVE | sed 's/.tar.gz//')

USER_HOME="/home/$USER_NAME"
SSH_KEY="$USER_HOME/.ssh/id_rsa"
LOG_DIR="$USER_HOME/logs"
USER_GID=$(id -g $USER_NAME)
USER_UID=$(id -u $USER_NAME)

INTERNAL_IP=$(ip a | grep "192.168.1" | awk '{print $2}' | cut -d/ -f1)
MYSQL_SERVER_IP="91.107.207.227"
NGINX_MASTER_IP="49.13.122.119"

GUNICORN_WORKERS=10
RQ_WORKER_PROCS=6
RQ_SCHEDULER_PROCS=1

LIMITS="DefaultLimitDATA=infinity
DefaultLimitSTACK=infinity
DefaultLimitCORE=infinity
DefaultLimitRSS=infinity
DefaultLimitNOFILE=524288
DefaultLimitAS=infinity
DefaultLimitNPROC=50240
DefaultLimitMEMLOCK=infinity"

SYSTEM_CONF="/etc/systemd/system.conf"
USER_CONF="/etc/systemd/user.conf"
GRUB_CONFIG="/etc/default/grub"
SCRIPT_DIR="/home/proxyuser/configs"

echo -n "Input username for MySQL: "
read MYSQL_USER
echo "You set username: $MYSQL_USER"
echo -n "Input password for MySQL: "
read MYSQL_PASSWORD

### CHEKING SSH KEY ###
if [ ! -f "$SSH_KEY" ]; then
    echo "SSH-key was not found $SSH_KEY."
    echo "Create ssh-key and add it to your github account."
    exit 1
fi

### INSTALLING DEPENDENCIES ###
echo 'INFO: INSTALLING DEPENDENCIES...'

sudo apt update && sudo apt upgrade -y
sudo apt install autojump tmux ncdu jq build-essential tar curl resolvconf npm nodejs python3 python3-dev python3-pip python3-venv htop wireguard nginx supervisor gunicorn redis zsh ffmpeg libsdl2-2.0-0 wget gcc git pkg-config meson ninja-build libsdl2-dev libavcodec-dev libavdevice-dev libavformat-dev libavutil-dev libswresample-dev libusb-1.0-0 libusb-1.0-0-dev -y

### INSTALLING PYTHON DEPENDENCIES ###
echo 'INFO: INSTALLING PYTHON DEPENDENCIES...'

mkdir -p $USER_HOME/venv/

# 'Installing api environment...'
echo 'Installing api environment...'

python3 -m venv $USER_HOME/venv/api
source $USER_HOME/venv/api/bin/activate
pip3 install aniso8601 async-timeout blinker click crontab Flask Flask-RESTful freezegun greenlet gunicorn ipaddress itsdangerous Jinja2 MarkupSafe mysql-connector-python netifaces packaging pexpect protobuf ptyprocess python-dateutil python-dotenv pytz redis rq rq-scheduler setuptools six SQLAlchemy typing_extensions tzlocal Werkzeug
deactivate

# 'Installing checker environment...'
echo 'Installing checker environment...'

python3 -m venv $USER_HOME/venv/checker
source $USER_HOME/venv/checker/bin/activate
pip3 install mysql-connector-python python-dotenv redis requests
deactivate

### INSTALLING scrcpy ###
echo 'INFO: INSTALLING SCRCPY...'
cd $USER_HOME
git clone https://github.com/Genymobile/scrcpy && cd scrcpy
./install_release.sh

### INSTALLING 3proxy ###
echo 'INFO: INSTALLING 3proxy...'

cd $USER_HOME
git clone https://github.com/z3apa3a/3proxy && cd 3proxy
ln -s Makefile.Linux Makefile
make && sudo make install
sudo touch /etc/3proxy/users.txt
sudo chown -R $USER_NAME:$USER_NAME /etc/3proxy
sudo chown -R $USER_NAME:$USER_NAME /var/log/3proxy
sudo chown -R $USER_NAME:$USER_NAME /usr/bin/3proxy

echo 'Creating 3proxy config...'

cd $USER_HOME/configs
sed -e "s|{{USER_HOME}}|$USER_HOME|g" \
    -e "s|{{LOG_DIR}}|$LOG_DIR|g" \
    -e "s|{{USER_GID}}|$USER_GID|g" \
    -e "s|{{USER_UID}}|$USER_UID|g" \
    -e "s|{{INTERNAL_IP}}|$INTERNAL_IP|g" \
    "3proxy.cfg.template" | sudo tee /etc/3proxy/3proxy.cfg

mkdir -p $LOG_DIR/3proxy
echo
echo 'Creating 3proxy service...'
sed "s|{{USER_NAME}}|$USER_NAME|g" "3proxy.service.template" | sudo tee "/etc/systemd/system/3proxy.service"
echo

### INSTALLING TMUX PLUGINS ###
echo 'INFO: INSTALLING TMUX PLUGINS...'

cd $USER_HOME
git clone https://github.com/tmux-plugins/tpm .tmux/plugins/tpm
cd $USER_HOME/configs
cp tmux.conf.template $USER_HOME/.tmux.conf

### INSTALLING MYSQL-TUNNEL SERVICE ###
echo 'INFO: INSTALLING MYSQL-TUNNEL SERVICE...'

sed -e "s|{{USER_NAME}}|$USER_NAME|g" \
    -e "s|{{MYSQL_SERVER_IP}}|$MYSQL_SERVER_IP|g" \
    -e "s|{{USER_HOME}}|$USER_HOME|g" \
    "mysql-tunnel.service.template" | sudo tee "/etc/systemd/system/mysql-tunnel.service"

### CLONING REPOS ###
echo 'INFO: CLONING REPOS...'

cd $USER_HOME
git clone git@github.com:aanovikov/api_proxy.git
git clone git@github.com:aanovikov/services.git

### CREATING DIRECTORIES AND FILES ###
echo 'INFO: CREATING DIRECTORIES AND FILES...'

mkdir -p $LOG_DIR/supervisor
touch $LOG_DIR/supervisor/API.log && touch $LOG_DIR/supervisor/rq_scheduler.log && touch $LOG_DIR/supervisor/rq_worker.log
mkdir -p $LOG_DIR/iface_checker
touch $LOG_DIR/iface_checker/iface_checker.log

### WRITING .env ###
echo 'INFO: WRITING .env...'

cd $USER_HOME/configs
sed -e "s|{{LOG_DIR}}|$LOG_DIR|g" \
    -e "s|{{MYSQL_USER}}|$MYSQL_USER|g" \
    -e "s|{{MYSQL_PASSWORD}}|$MYSQL_PASSWORD|g" \
    "env.template" | tee "$USER_HOME/api_proxy/.env"
echo

### WRITING SUPERVISOR CONFIGS ###
echo 'INFO: WRITING SUPERVISOR CONFIGS...'

sed -e "s|{{USER_HOME}}|$USER_HOME|g" \
    -e "s|{{GUNICORN_WORKERS}}|$GUNICORN_WORKERS|g" \
    -e "s|{{USER_NAME}}|$USER_NAME|g" \
    "supervisor_api.conf.template" | sudo tee "/etc/supervisor/conf.d/api.conf"

sed -e "s|{{USER_HOME}}|$USER_HOME|g" \
    -e "s|{{RQ_WORKER_PROCS}}|$RQ_WORKER_PROCS|g" \
    -e "s|{{USER_NAME}}|$USER_NAME|g" \
    "supervisor_rq_worker.conf.template" | sudo tee "/etc/supervisor/conf.d/rq_worker.conf"

sed -e "s|{{USER_HOME}}|$USER_HOME|g" \
    -e "s|{{RQ_SCHEDULER_PROCS}}|$RQ_SCHEDULER_PROCS|g" \
    -e "s|{{USER_NAME}}|$USER_NAME|g" \
    "supervisor_rq_scheduler.conf.template" | sudo tee "/etc/supervisor/conf.d/rq_scheduler.conf"

sudo supervisorctl reread && sudo supervisorctl update

# ### WRITING WIREGUARD CONFIG ###
# echo 'INFO: WRITING WIREGUARD CONFIG...'
# touch /etc/wireguard/wg0.conf

### SETTING SYSTEM LIMITS ###
echo 'INFO: SETTING SYSTEM LIMITS...'

echo "$LIMITS" | sudo tee -a $SYSTEM_CONF > /dev/null
echo "$LIMITS" | sudo tee -a $USER_CONF > /dev/null

### DISABLE IPV6 IN GRUB###
echo 'INFO: DISABLE IPV6 IN GRUB###'

sudo cp $GRUB_CONFIG "${GRUB_CONFIG}.bak"
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash ipv6.disable=1"/' $GRUB_CONFIG
sudo sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="ipv6.disable=1"/' $GRUB_CONFIG

# Проверка, были ли строки добавлены, и добавление их, если они отсутствуют
if ! grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" $GRUB_CONFIG; then
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash ipv6.disable=1"' | sudo tee -a $GRUB_CONFIG
fi

if ! grep -q "^GRUB_CMDLINE_LINUX=" $GRUB_CONFIG; then
    echo 'GRUB_CMDLINE_LINUX="ipv6.disable=1"' | sudo tee -a $GRUB_CONFIG
fi

# Updating GRUB
sudo update-grub && sleep 2
echo "Проверить права /home/proxyuser/logs/ или выполнить sudo chown -R proxyuser:proxyuser logs"
cd ~

sudo usermod -aG proxyuser www-data

redis-cli hset admin-tGRZAMk4GruQtOxoFVgM role admin

### installing node exporter ###
echo 'INFO: installing node exporter...'
# Скачиваем последний релиз`
wget $LATEST_RELEASE
# Распаковываем архив
tar -xvf $NODE_ARCHIVE
# Переходим в папку
cd $NODE_FOLDER
# Перемещаем node_exporter в нужное место
sudo mv node_exporter /usr/local/bin
# Создаем пользователя без домашней директории и с запрещенным логином
sudo useradd --no-create-home --shell /bin/false node_exporter
# Назначаем права
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter
# Копируем шаблон файла node_exporter.service в systemd
sudo cp "$SCRIPT_DIR/node_exporter.service.template" /etc/systemd/system/node_exporter.service

# Удаляем архив и папку (по желанию)
cd ..
rm -rf $NODE_ARCHIVE $NODE_FOLDER

echo 'INFO: installing iface_status services'

sudo cp "$SCRIPT_DIR/iface_status.service.template" /etc/systemd/system/iface_status.service
sudo cp "$SCRIPT_DIR/iface_status.timer.template" /etc/systemd/system/iface_status.timer
sudo systemctl daemon-reload 
sudo systemctl enable mysql-tunnel.service && sudo systemctl start mysql-tunnel.service
sudo systemctl enable node_exporter && sudo systemctl start node_exporter
sudo systemctl enable iface_status.service && sudo systemctl start iface_status.service && sudo systemctl enable iface_status.timer && sudo systemctl start iface_status.timer

echo "Done"