#!/bin/bash
set -e

# ----- Variables -----
SEAFILE_VERSION="12.0.14"
SEAFILE_DOWNLOAD="https://s3.eu-central-1.amazonaws.com/download.seadrive.org/seafile-server_12.0.14_x86-64.tar.gz"
SEAFILE_DIR="/opt/seafile"
SEAFILE_USER="seafile"
DB_ROOT_PASS="my_db_root_password"
DB_USER="seafile"
DB_PASS="my_db_password"
DB1="ccnet_db"
DB2="seafile_db"
DB3="seahub_db"
DB_PORT="3306"
DB_HOST="localhost"
DB_CHARSET="utf8"
ADMIN_EMAIL="admin@example.com"
ADMIN_PASS="my_admin_password"
HOSTNAME="myhostname"
SERVER_IP="10.0.0.1"
FILESERVER_PORT="8082"
TIMEZONE="Etc/UTC"
JWT_KEY=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)

# ----- Dependencies -----
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv python3-dev python3-setuptools python3.12-venv  sqlite3 \
  libmysqlclient-dev default-libmysqlclient-dev ldap-utils libldap2-dev libsasl2-dev libssl-dev memcached \
  libmemcached-dev build-essential libffi-dev pwgen pkg-config
sudo systemctl enable --now memcached

# ----- Seafile User & Directory -----
sudo adduser --system --group $SEAFILE_USER
sudo mkdir -p $SEAFILE_DIR
sudo chown -R $SEAFILE_USER:$SEAFILE_USER $SEAFILE_DIR

# ----- Download & Extract Seafile -----
sudo -u $SEAFILE_USER wget -O $SEAFILE_DIR/seafile-server_${SEAFILE_VERSION}_x86-64.tar.gz $SEAFILE_DOWNLOAD
sudo -u $SEAFILE_USER tar xf $SEAFILE_DIR/seafile-server_${SEAFILE_VERSION}_x86-64.tar.gz -C $SEAFILE_DIR
# ----- MySQL Setup -----
echo "Updating package lists..."
sudo apt update

echo "Installing MySQL server..."
sudo apt install -y mysql-server

echo "Creating required directories and setting permissions..."
sudo mkdir -p /var/run/mysqld /var/log/mysql
sudo chown -R mysql:mysql /var/run/mysqld /var/log/mysql /var/lib/mysql
sudo chmod 700 /var/lib/mysql

echo "Configuring MySQL server with explicit settings..."
MYSQL_CONF_FILE="/etc/mysql/mysql.conf.d/mysqld.cnf"

sudo tee $MYSQL_CONF_FILE > /dev/null <<EOF
[mysqld]
user            = mysql
pid-file        = /var/run/mysqld/mysqld.pid
socket          = /var/run/mysqld/mysqld.sock
port            = 3306
datadir         = /var/lib/mysql
bind-address    = 127.0.0.1
log_error       = /var/log/mysql/error.log
EOF

echo "Resetting systemd failures and restarting MySQL service..."
sudo systemctl reset-failed mysql
sudo systemctl enable mysql
sudo systemctl start mysql

echo "Running MySQL secure installation to improve security..."
sudo mysql_secure_installation

echo "Checking MySQL service status..."
sudo systemctl status mysql --no-pager

echo "MySQL version installed:"
mysql --version

echo "MySQL installation and setup completed successfully!"

# Now create databases with the new password
sudo mysql -u root -p"${DB_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS ${DB1} CHARACTER SET = '$DB_CHARSET';
CREATE DATABASE IF NOT EXISTS ${DB2} CHARACTER SET = '$DB_CHARSET';
CREATE DATABASE IF NOT EXISTS ${DB3} CHARACTER SET = '$DB_CHARSET';
CREATE USER IF NOT EXISTS '${DB_USER}'@'$DB_HOST' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB1}.* TO '${DB_USER}'@'$DB_HOST';
GRANT ALL PRIVILEGES ON ${DB2}.* TO '${DB_USER}'@'$DB_HOST';
GRANT ALL PRIVILEGES ON ${DB3}.* TO '${DB_USER}'@'$DB_HOST';
FLUSH PRIVILEGES;
EOF

# Verify database setup
if ! mysql -u root -p"${DB_ROOT_PASS}" -e "SHOW DATABASES;" > /dev/null; then
    echo "Error: Database setup failed"
    exit 1
fi

# ----- Seafile Setup -----
sudo -u $SEAFILE_USER bash -c "
export SERVER_NAME="$HOSTNAME"
export SERVER_IP="$SERVER_IP"
export FILESERVER_PORT="$FILESERVER_PORT"
cd $SEAFILE_DIR/seafile-server-${SEAFILE_VERSION}
./setup-seafile.sh auto
"
echo "Seafile setup completed."
#Seafile configuration files
cat <<EOF | sudo tee $SEAFILE_DIR/conf/seafile.conf
[fileserver]
port = $FILESERVER_PORT
max_upload_size = 100000
max_download_dir_size = 100000

[database]
type = mysql
host = $DB_HOST
port = $DB_PORT
user = $DB_USER
password = $DB_PASS
db_name = $DB2
connection_charset = $DB_CHARSET
unix_socket = /var/run/mysqld/mysqld.sock

[notification]
enabled = false
host = $DB_HOST
port = 8083
log_level = info
EOF

# ----- Environment File (.env) -----
cat <<EOT | sudo tee $SEAFILE_DIR/conf/.env
SEAFILE_SERVER_NAME=$HOSTNAME
SEAFILE_MYSQL_DB_HOST=$DB_HOST
SEAFILE_MYSQL_DB_PORT=3306
INIT_SEAFILE_MYSQL_ROOT_PASSWORD=$DB_ROOT_PASS
SEAFILE_MYSQL_DB_USER=$DB_USER
SEAFILE_MYSQL_DB_PASSWORD=$DB_PASS
SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=$DB2
SEAFILE_MYSQL_DB_CCNET_DB_NAME=$DB1
SEAFILE_MYSQL_DB_SEAHUB_DB_NAME=$DB3
TIME_ZONE=$TIMEZONE
LC_ALL=en_US.UTF-8
JWT_PRIVATE_KEY=$JWT_KEY
SEAFILE_SERVER_HOSTNAME=$HOSTNAME
SEAFILE_SERVER_PROTOCOL=https
INIT_SEAFILE_ADMIN_EMAIL=$ADMIN_EMAIL
INIT_SEAFILE_ADMIN_PASSWORD=$ADMIN_PASS
PYTHON=$SEAFILE_DIR/seafile-server-${SEAFILE_VERSION}/venv/bin/python3
PYTHONPATH=$SEAFILE_DIR/seafile-server-${SEAFILE_VERSION}/seahub/thirdpart:$SEAFILE_DIR/seafile-server-${SEAFILE_VERSION}/seafile/lib/python3/site-packages
EOT

# Set permissions for .env file
sudo chown $SEAFILE_USER:$SEAFILE_USER $SEAFILE_DIR/conf/.env
sudo chmod 664 $SEAFILE_DIR/conf/.env

#Update Seahub settings for memcached
cat <<EOF | sudo tee -a $SEAFILE_DIR/conf/seahub_settings.py
CACHES = {
    'default': {
        'BACKEND': 'django_pylibmc.memcached.PyLibMCCache',
        'LOCATION': '127.0.0.1:11211',
    },
}
EOF

# ----- Python Virtual Environment Setup -----
sudo -u $SEAFILE_USER bash -c "
cd $SEAFILE_DIR/seafile-server-${SEAFILE_VERSION}
python3 -m venv venv
source venv/bin/activate
pip3 install --upgrade pip
pip3 install sqlalchemy==2.0.* pylibmc gevent==24.2.* pymysql pillow==10.4.* captcha==0.6.* markupsafe==2.0.1 \
  jinja2 psd-tools django-pylibmc lxml 
pip3 install -r $SEAFILE_DIR/seafile-server-${SEAFILE_VERSION}/seahub/requirements.txt
deactivate
"
echo "Seafile setup complete!"
echo "Admin email: $ADMIN_EMAIL"
echo "Admin pass: $ADMIN_PASS"
echo "Edit variables in the script as needed before running in production."

# ----- Seafile and Seahub Start----- need to automate the admin user creation when starting seahub
sudo -u $SEAFILE_USER bash -c "
cd $SEAFILE_DIR/seafile-server-${SEAFILE_VERSION}
export $(cat /opt/seafile/conf/.env | xargs)
./seafile.sh start
./seahub.sh start
"
echo "Seafile and Seahub services started."
